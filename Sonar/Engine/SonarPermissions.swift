import AppKit
import ApplicationServices
import AutoPauseEngine
import Combine
import CoreGraphics
import Foundation

/// A macOS permission Auto-Pause cannot do its job without.
enum SonarPermission: String, CaseIterable, Identifiable {
    /// System audio capture for the Core Audio tap. Without it Sonar can only
    /// ask which apps hold the audio output, never how loud they are.
    case screenRecording
    /// Apple Events to `com.spotify.client`, so Sonar can pause and resume.
    case automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return "Screen & System Audio Recording"
        case .automation: return "Automation"
        }
    }

    /// What the grant buys, phrased as the thing the user wants, so the row
    /// can be built without knowing anything about Core Audio or Apple Events.
    var effect: String {
        switch self {
        case .screenRecording: return "measure how loud other apps are"
        case .automation: return "pause and resume Spotify"
        }
    }

    /// Verified to navigate on macOS 26/27. The newer
    /// `com.apple.settings.PrivacySecurity` host does not open.
    var settingsURL: URL? {
        let pane = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Automation"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

/// What the OS says about one permission right now.
enum SonarPermissionState: Equatable {
    /// The state has not been read — the first read is still running, or a read
    /// that never answered was given up on. Never a steady state: the pane
    /// re-reads on a timer, and this says so in words and offers the retry
    /// rather than sitting on a spinner with no way forward.
    case unknown
    /// Never refused, so the OS will still show its own prompt.
    case needsGrant
    /// Refused earlier, or blocked: the OS will not ask again, so only
    /// System Settings can change it.
    case blocked
    case granted
    /// Automation only: the target is not running, so there is nothing to ask
    /// it. Not a permission problem, and never shown as one.
    case targetNotRunning
    /// Not a TCC state: the grant is in place but the audio tap is carrying
    /// nothing, so the permission exists and the capability does not. Only the
    /// pane produces this, and only for display.
    case tapSilent

    /// True when tapping "Grant..." would actually do something.
    var canPrompt: Bool { self == .needsGrant }
}

/// Live state of the two permissions Auto-Pause needs.
///
/// Both probes can block, and the grant paths wait on a system dialog, so
/// everything is read and requested off the main thread and published back on
/// it. There is no actor annotation: the class is main-thread-affine by
/// convention (like `SonarEngineHost`), not by type system.
///
/// Nothing here may be left "in progress" because of a call that did not
/// return. `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)`
/// blocks on a system dialog that can be dismissed without an answer, and a
/// process can be killed while the dialog is up; a flag that records the
/// request and is only cleared by the request's own completion then outlives
/// everything it describes, and the pane shows "Checking…" for the rest of the
/// session with no button to press. So every wait goes through
/// `InFlightLedger`, which can only be left by an answer or by a deadline.
final class SonarPermissions: ObservableObject {
    static let shared = SonarPermissions()

    /// The app that owns the audio tap and the fades.
    private static let spotifyBundleID = "com.spotify.client"

    @Published private(set) var screenRecording: SonarPermissionState = .unknown
    @Published private(set) var automation: SonarPermissionState = .unknown

    /// Whether the engine is actually receiving audio from the tap right now.
    ///
    /// This is the authority on capture, not `CGPreflightScreenCaptureAccess()`.
    /// That call is documented for *screen* capture, and it answers "not
    /// granted" for an ad-hoc-signed build whose system-audio tap is
    /// demonstrably delivering audio - which is exactly what it does on a local
    /// dev build, and would also mislead anyone whose OS ties the two services
    /// together differently. Reporting "not granted" there would send a user
    /// with a working feature into System Settings to grant something they
    /// already have; and because a refused process is never re-prompted, there
    /// would be no way back. Buffers arriving is the only honest evidence that
    /// capture is permitted.
    @Published private(set) var isMeasuringLoudness = false

    /// Permissions with a grant in flight. The state itself is left alone:
    /// blanking it to "unknown" would make a blocking permission look
    /// switchable for as long as the system dialog is up.
    @Published private(set) var requesting: Set<SonarPermission> = []

    private let queue = DispatchQueue(label: "sonar.permissions", qos: .userInitiated)
    /// Grant requests get a queue of their own.
    ///
    /// They used to share the serial queue with the reads, which is what turned
    /// one unanswered dialog into two permanently unread rows: the request sat
    /// in the queue blocking on the system dialog, and every read queued behind
    /// it never started. A wedged request now costs exactly the one row that
    /// asked for it.
    private let requestQueue = DispatchQueue(label: "sonar.permissions.request", qos: .userInitiated)
    /// Outstanding reads, with the deadline after which a read is treated as
    /// lost and replaced rather than waited on. One entry per permission, not one
    /// for the pair: `CGPreflightScreenCaptureAccess` answers in microseconds
    /// while `AEDeterminePermissionToAutomateTarget` can block forever, and one
    /// serial read of both meant the fast, reliable answer was never published
    /// because the slow one had not come back.
    private var reads = InFlightLedger<SonarPermission>()
    /// Outstanding grant requests.
    private var requests = InFlightLedger<SonarPermission>()
    /// The deadline watchers for both.
    ///
    /// `DispatchWorkItem`s on the main queue, **not** `Timer`s. A `Timer` is
    /// scheduled onto the current thread's run loop, and a `Timer` created from
    /// a background thread — which is exactly when these are created, because
    /// that is where a probe discovers it needs a deadline — is added to no run
    /// loop at all and never fires. Measured, both forms:
    ///
    ///     Timer(timeInterval:)  -> never fired
    ///     Timer.scheduledTimer  -> never fired
    ///     main.asyncAfter       -> fired
    ///
    /// So a `Timer` here is a deadline that silently does not exist, and the row
    /// it was written to protect goes back to "Checking…" forever.
    private var probeTimers: [SonarPermission: DispatchWorkItem] = [:]
    private var requestTimers: [SonarPermission: DispatchWorkItem] = [:]
    /// Earliest time a timed-out read may be tried again. A read that has
    /// already been given up on is not retried just because the poll fired
    /// again — see `refresh()`.
    private var readCooldown: [SonarPermission: Date] = [:]
    private var lastLoggedScreen: SonarPermissionState?
    private var lastLoggedAutomation: SonarPermissionState?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    private init() {
        refresh()
    }

    deinit {
        stopLiveUpdates()
    }

    // MARK: - Reading state

    func state(for permission: SonarPermission) -> SonarPermissionState {
        switch permission {
        case .screenRecording:
            return isMeasuringLoudness ? .granted : screenRecording
        case .automation:
            return automation
        }
    }

    /// Called by the engine whenever the tap starts or stops receiving
    /// buffers.
    func noteTapIsCapturing(_ capturing: Bool) {
        guard capturing != isMeasuringLoudness else { return }
        isMeasuringLoudness = capturing
        SonarLog.write(
            "permissions: loudness measurement \(capturing ? "working" : "not working") "
                + "(preflight says \(screenRecording))"
        )
    }

    func isRequesting(_ permission: SonarPermission) -> Bool {
        requests.contains(permission)
    }

    /// True when the Automation row says `.blocked` because macOS stopped
    /// answering, not because it refused.
    ///
    /// Both arrive as `.blocked`, and the difference is the difference between
    /// "a switch is off" and "macOS cannot be asked, so no prompt can be
    /// raised". The second is worth its own words: it is the state on macOS 27
    /// with Spotify 1.3.1.234, where `AEDeterminePermissionToAutomateTarget`
    /// never returns at all. See `probeAutomation()`.
    var automationCheckIsWedged: Bool {
        automation == .blocked && (readCooldown[.automation] ?? .distantPast) > Date()
    }

    /// True when this permission is known to stand in the way. `unknown` is
    /// not blocking: it is the sub-second state before the first read, and
    /// treating it as a denial would report every healthy install as broken.
    func isBlocking(_ permission: SonarPermission) -> Bool {
        let state = state(for: permission)
        return state == .blocked || state == .needsGrant
    }

    /// True when nothing known stands between the user and a working
    /// Auto-Pause.
    ///
    /// "Spotify isn't running" deliberately does not block. It is not a
    /// permission problem (there is no grant to make), a Spotify-only feature
    /// has nothing to act on while Spotify is closed anyway, and the next poll
    /// settles it either way.
    var canEnable: Bool {
        !SonarPermission.allCases.contains(where: isBlocking)
    }

    // MARK: - Probing

    /// Re-read both permissions. Cheap, safe, and callable as often as the UI
    /// likes: a grant made in System Settings flips live and silently.
    ///
    /// Each permission is read on its own ledger entry and its own pass through
    /// the queue, because the two calls are nothing alike:
    /// `CGPreflightScreenCaptureAccess()` answers in microseconds, while
    /// `AEDeterminePermissionToAutomateTarget` has been observed blocking
    /// *forever* on this OS (see `probeAutomation`). Reading them as one
    /// serial job meant the reliable answer was never published, because the
    /// unreliable one had not come back — which is how the log ended up saying
    /// `preflight says unknown` for hours on a machine whose tap was working.
    func refresh() {
        let now = Date()
        // The poll is the safety net for the expiry timers: even with the pane
        // closed and every timer invalidated, the next poll gives up anything
        // out of time. Two mechanisms for one rule on purpose - a timer that is
        // always running and a sweep that cannot be starved.
        expireTimedOutRequests(at: now)
        for permission in reads.expire(at: now) {
            noteReadTimedOut(permission)
        }
        for permission in SonarPermission.allCases {
            guard !reads.contains(permission) else { continue }
            // A read that has already timed out is not retried on the next tick.
            // `AEDeterminePermissionToAutomateTarget` does not come back on
            // this OS, so retrying it once a second is how a permanent condition
            // turns into an unbounded pile of calls that never return — measured
            // at 14 started and 0 finished in 14 seconds. One attempt, one
            // verdict, one honest state; the user gets a button instead.
            guard let until = readCooldown[permission], until > now else {
                readCooldown[permission] = nil
                read(permission, at: now)
                continue
            }
        }
    }

    /// Start one read of one permission.
    ///
    /// The read carries its own deadline timer, so a read that never answers is
    /// still given up on when no preferences pane is open. Relying on the
    /// pane's 1 s poll for this was the gap that let the original symptom
    /// survive a correct-looking fix: the sweep that notices a wedged read only
    /// ran while the pane existed, so with the pane closed the row stayed
    /// "Checking…" forever — which is exactly what it was reported doing.
    private func read(_ permission: SonarPermission, at now: Date) {
        let carriedScreen = screenRecording
        let entry = reads.begin(permission, at: now, timeout: InFlightTimeout.probe)
        scheduleReadDeadline(permission, at: entry.deadline)
        queue.async { [weak self] in
            let result: SonarPermissionState
            switch permission {
            case .screenRecording: result = Self.probeScreenRecording(carrying: carriedScreen)
            case .automation: result = Self.probeAutomation()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Cleared before publishing, and unconditionally: this is the
                // only thing standing between a read that answered and the next
                // one, so a completion that skipped it would stop the app
                // re-reading permissions for the rest of the session.
                self.reads.finish(permission)
                self.probeTimers[permission]?.cancel()
                self.probeTimers[permission] = nil
                self.publish(result, for: permission)
                self.logChange()
            }
        }
    }

    /// Fire at the read's deadline whether or not anything is polling, and keep
    /// firing until the read has either answered or been given up on.
    ///
    /// Self-rescheduling rather than firing once, because a one-shot timer that
    /// runs a moment early leaves the read outstanding with nothing left to
    /// expire it: the poll that would have swept it does not run when the
    /// preferences pane is closed, so the row sits on "Checking…" forever again
    /// — the original symptom, one timer earlier. Same safety-net reasoning as
    /// `expireTimedOutRequests`: a timer that is always running, plus a sweep
    /// that cannot be starved.
    private func scheduleReadDeadline(_ permission: SonarPermission, at deadline: Date) {
        probeTimers[permission]?.cancel()
        var work: DispatchWorkItem?
        work = DispatchWorkItem { [weak self] in
            guard let self, let work, !work.isCancelled else { return }
            self.probeTimers[permission] = nil
            // Answered in the meantime: the completion already cleared it and
            // its own watcher, so there is nothing left to do.
            guard self.reads.contains(permission) else { return }
            let now = Date()
            if let entry = self.reads.entry(for: permission), !entry.isExpired(at: now) {
                self.scheduleReadDeadline(permission, at: entry.deadline)
                return
            }
            _ = self.reads.expire(at: now)
            self.noteReadTimedOut(permission)
        }
        probeTimers[permission] = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.25, deadline.timeIntervalSinceNow),
            execute: work!
        )
    }

    /// A read did not come back in time. Say why, and stop retrying it until
    /// something happens that could plausibly have fixed it.
    private func noteReadTimedOut(_ permission: SonarPermission) {
        let until = Date().addingTimeInterval(InFlightTimeout.wedgedReadRetry)
        readCooldown[permission] = until
        switch permission {
        case .automation:
            // Do not sit on "unknown" for a call that is never going to answer.
            // `targetNotRunning` would be a lie (Spotify is running — the call
            // got far enough to hang on it), and `needsGrant` would put a
            // "Grant…" button on the row that cannot work: the prompt is
            // something tccd has to raise, and tccd is what is not answering.
            // `.blocked` is the honest state — it is the one whose only action
            // is System Settings, which a person can always reach.
            publish(.blocked, for: .automation)
            SonarLog.write(
                "permissions: the Automation check did not answer within "
                    + "\(Int(InFlightTimeout.probe))s; treating it as unavailable and "
                    + "not retrying it on the poll"
            )
        case .screenRecording:
            SonarLog.write(
                "permissions: the screen-recording check did not answer within "
                    + "\(Int(InFlightTimeout.probe))s"
            )
        }
        logChange()
    }

    /// Log the pair only when it actually changed, so a per-second poll cannot
    /// fill the bounded log.
    private func logChange() {
        let screen = screenRecording
        let automation = self.automation
        guard screen != lastLoggedScreen || automation != lastLoggedAutomation else { return }
        lastLoggedScreen = screen
        lastLoggedAutomation = automation
        SonarLog.write("permissions: screenRecording=\(screen) automation=\(automation)")
    }

    /// Ask the OS for a permission. Only worth calling when
    /// `state.canPrompt` is true - after a refusal the OS will not ask again,
    /// and the caller has to send the user to System Settings instead.
    ///
    /// The row leaves "waiting" in all three possible endings: the request
    /// answers, the deadline passes (`scheduleRequestExpiry`), or the app comes
    /// back to the front and the dialog that was blocking is gone
    /// (`appDidBecomeActive`). There is no fourth.
    func request(_ permission: SonarPermission) {
        let now = Date()
        expireTimedOutRequests(at: now)
        guard !requests.contains(permission) else {
            SonarLog.write("permission \(permission.rawValue): request already in flight; ignoring")
            return
        }
        // A check that has already been given up on is not asked to prompt.
        // `askUserIfNeeded: true` goes through the same
        // `AEDeterminePermissionToAutomateTarget` that just failed to answer, so
        // pressing "Grant…" here would sit for a minute and then admit nothing
        // happened. System Settings is the only route that can still work, and
        // the row already says so.
        if let until = readCooldown[permission], until > now {
            SonarLog.write(
                "permission \(permission.rawValue): not asking for a prompt, because the "
                    + "check this would use has already stopped answering"
            )
            openSettings(for: permission)
            return
        }
        let entry = requests.begin(
            permission,
            at: now,
            timeout: InFlightTimeout.grantRequest
        )
        publishRequesting()
        scheduleRequestExpiry(permission, at: entry.deadline)
        SonarLog.write("permission \(permission.rawValue): requesting, waiting up to \(Int(InFlightTimeout.grantRequest))s")
        requestQueue.async { [weak self] in
            let result: SonarPermissionState
            switch permission {
            case .screenRecording: result = Self.requestScreenRecording()
            case .automation: result = Self.requestAutomation()
            }
            DispatchQueue.main.async { [weak self] in
                self?.finish(permission, with: result)
            }
        }
    }

    func openSettings(for permission: SonarPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Live updates

    /// Poll while the permission UI is on screen. `CGPreflightScreenCaptureAccess`
    /// flips when the user grants in System Settings but nothing posts a
    /// notification, and the usual path is Settings -> back to this window,
    /// so the `didBecomeActive` re-check is what makes it look instant.
    func startLiveUpdates() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appDidBecomeActive()
        }
    }

    func stopLiveUpdates() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        for permission in requestTimers.keys {
            requestTimers[permission]?.cancel()
        }
        requestTimers.removeAll()
        for permission in probeTimers.keys {
            probeTimers[permission]?.cancel()
        }
        probeTimers.removeAll()
    }

    // MARK: - Ending a wait

    /// The request answered, one way or another.
    ///
    /// Publishing is conditional on still being the wait the row is showing. A
    /// late answer — the dialog sat unanswered past the deadline, or the app was
    /// relaunched underneath it — describes the world at some moment nobody
    /// knows, and the 1 s poll has already read something fresher. The answer is
    /// still logged, because the log should not be tidier than what happened.
    private func finish(_ permission: SonarPermission, with result: SonarPermissionState) {
        let wasWaiting = requests.finish(permission)
        requestTimers[permission]?.cancel()
        requestTimers[permission] = nil
        publishRequesting()
        if wasWaiting {
            publish(result, for: permission)
            SonarLog.write("permission \(permission.rawValue) requested: \(result)")
        } else {
            SonarLog.write(
                "permission \(permission.rawValue) request returned \(result) after the "
                    + "row had already given up; the re-read stands"
            )
        }
    }

    /// The request is out of time. The system dialog is the OS's, not ours, so
    /// the honest thing is to stop claiming we are waiting for it, re-read the
    /// truth, and let the row offer its own action again. The worker may still
    /// be blocked inside the OS call; it cannot strand anything, because the
    /// only thing that depended on it has already been given up.
    private func expireTimedOutRequests(at now: Date) {
        for permission in requests.expire(at: now) {
            requestTimers[permission]?.cancel()
            requestTimers[permission] = nil
            SonarLog.write(
                "permission \(permission.rawValue): no answer after "
                    + "\(Int(InFlightTimeout.grantRequest))s; re-reading"
            )
        }
        publishRequesting()
    }

    private func scheduleRequestExpiry(_ permission: SonarPermission, at deadline: Date) {
        requestTimers[permission]?.cancel()
        var work: DispatchWorkItem?
        work = DispatchWorkItem { [weak self] in
            guard let self, let work, !work.isCancelled else { return }
            self.requestTimers[permission] = nil
            self.expireTimedOutRequests(at: Date())
            self.refresh()
        }
        requestTimers[permission] = work
        // Never `0`: a zero delay would give up on the request immediately
        // instead of at its deadline.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(1, deadline.timeIntervalSinceNow),
            execute: work!
        )
    }

    /// Coming back to the app means whatever was up is not up any more: the
    /// dialog was dismissed, answered, or the app was relaunched. So no request
    /// is still waiting, and the state is re-read from scratch.
    ///
    /// This is also the one moment a read that was given up on is worth trying
    /// again: the usual reason to be here at all is a trip to System Settings,
    /// and a grant made there is exactly what the next read needs to see. The
    /// cooldown is cleared rather than merely waited out, so the row recovers the
    /// moment the user comes back instead of after a fixed delay.
    private func appDidBecomeActive() {
        let waiting = requests.keys
        if !waiting.isEmpty {
            for permission in waiting {
                requestTimers[permission]?.cancel()
                requestTimers[permission] = nil
                requests.expire(permission)
            }
            publishRequesting()
            SonarLog.write(
                "permissions: gave up on \(waiting.map(\.rawValue).sorted().joined(separator: ", ")) "
                    + "request(s) on activation; re-reading"
            )
        }
        for permission in readCooldown.keys {
            readCooldown[permission] = nil
            reads.expire(permission)
        }
        refresh()
    }

    // MARK: - Publishing

    private func publishRequesting() {
        let keys = requests.keys
        guard keys != requesting else { return }
        requesting = keys
    }

    private func publish(_ state: SonarPermissionState, for permission: SonarPermission) {
        switch permission {
        case .screenRecording: screenRecording = state
        case .automation: automation = state
        }
    }

    // MARK: - Probes

    private static func probeScreenRecording(
        carrying previous: SonarPermissionState
    ) -> SonarPermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        // A previously refused process is never re-prompted, so once we have
        // learned that the OS will not ask again, only System Settings remains.
        return previous == .blocked ? .blocked : .needsGrant
    }

    /// Read the Automation grant.
    ///
    /// -600: Spotify is not running. Nothing to ask it, and no permission has
    /// been refused.
    ///
    /// This is the call that hangs, and it hangs even with `askUserIfNeeded:
    /// false`, which is documented never to prompt. Measured on macOS 27 with
    /// Spotify 1.3.1.234: `com.apple.finder` answers `-1744` in 0.06 s and
    /// `com.spotify.client` never returns — blocked on a dispatch semaphore with
    /// no thread left to service it, reproducibly. tccd says why, once, in its
    /// own log:
    ///
    ///     internal_TCCCreateDesignatedRequirementIdentityFromMessage: Refusing
    ///     TCCAccessRequestIndirect (kTCCServiceAppleEvents) accessing=
    ///     {com.spotify.client} : unable to compute designated requirement for:
    ///     file:///Applications/Spotify.app/Contents/MacOS/Spotify.
    ///
    /// Spotify's own signature verifies and satisfies its designated
    /// requirement, so this is the OS failing to compute one for that binary,
    /// not a damaged install. Two consequences the app has to live with: the
    /// Automation row can never be read on this machine, and the prompt can
    /// never be raised either — a real Apple Event send times out (`-1712`)
    /// with no dialog on screen. So a "Grant…" button is unreachable and
    /// useless here, and System Settings is the only route left. Callers get
    /// that verdict from `noteReadTimedOut`, not from a status code, because
    /// there is no status code: the call does not return.
    private static func probeAutomation() -> SonarPermissionState {
        let status = automationStatus(askUserIfNeeded: false)
        if status == noErr { return .granted }
        // -1744: never asked, so the OS will still prompt.
        if status == OSStatus(errAEEventWouldRequireUserConsent) { return .needsGrant }
        // -600: Spotify is not running. Nothing to ask it, and no permission
        // has been refused.
        if status == OSStatus(procNotFound) { return .targetNotRunning }
        // -1742 sandbox block, -1743 refused, anything else unknown: assume
        // the OS will not prompt again, because a "Grant..." button that
        // silently does nothing is worse than a dead end in System Settings.
        return .blocked
    }

    private static func requestScreenRecording() -> SonarPermissionState {
        // Apple documents the system-audio prompt as implicit: it appears the
        // first time you capture a tap. The engine has to be restarting the
        // tap for that side effect to happen, so the caller does that too.
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess() ? .granted : .blocked
    }

    /// Blocks on the system dialog while it is up, and does not come back until
    /// somebody answers it. Nothing above this line may treat "still going" as
    /// permanent: see `InFlightLedger` and `request(_:)`.
    private static func requestAutomation() -> SonarPermissionState {
        let status = automationStatus(askUserIfNeeded: true)
        if status == noErr { return .granted }
        if status == OSStatus(procNotFound) { return .targetNotRunning }
        // The prompt has now been used up, refused or not.
        return .blocked
    }

    private static func automationStatus(askUserIfNeeded: Bool) -> OSStatus {
        var target = AEDesc()
        let created: OSErr = AECreateDesc(
            typeApplicationBundleID,
            spotifyBundleID,
            spotifyBundleID.utf8.count,
            &target
        )
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(kCoreEventClass),
            AEEventID(kAEGetURL),
            askUserIfNeeded
        )
    }
}
