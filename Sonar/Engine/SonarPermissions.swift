import AppKit
import ApplicationServices
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
    /// Not read yet, or a request is in flight.
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
final class SonarPermissions: ObservableObject {
    static let shared = SonarPermissions()

    /// The app that owns the audio tap and the fades.
    private static let spotifyBundleID = "com.spotify.client"

    @Published private(set) var screenRecording: SonarPermissionState = .unknown
    @Published private(set) var automation: SonarPermissionState = .unknown

    /// Permissions with a grant in flight. The state itself is left alone:
    /// blanking it to "unknown" would make a blocking permission look
    /// switchable for as long as the system dialog is up.
    @Published private(set) var requesting: Set<SonarPermission> = []

    private let queue = DispatchQueue(label: "sonar.permissions", qos: .userInitiated)
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// One probe at a time: a poll timer plus a didBecomeActive re-check can
    /// otherwise stack up behind a prompt.
    private var isBusy = false

    private init() {
        refresh()
    }

    deinit {
        stopLiveUpdates()
    }

    // MARK: - Reading state

    func state(for permission: SonarPermission) -> SonarPermissionState {
        switch permission {
        case .screenRecording: return screenRecording
        case .automation: return automation
        }
    }

    func isRequesting(_ permission: SonarPermission) -> Bool {
        requesting.contains(permission)
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
    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        let carriedScreen = screenRecording
        queue.async { [weak self] in
            let screen = Self.probeScreenRecording(carrying: carriedScreen)
            let automation = Self.probeAutomation()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.apply(screen: screen, automation: automation)
            }
        }
    }

    /// Ask the OS for a permission. Only worth calling when
    /// `state.canPrompt` is true - after a refusal the OS will not ask again,
    /// and the caller has to send the user to System Settings instead.
    func request(_ permission: SonarPermission) {
        requesting.insert(permission)
        queue.async { [weak self] in
            let result: SonarPermissionState
            switch permission {
            case .screenRecording: result = Self.requestScreenRecording()
            case .automation: result = Self.requestAutomation()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.requesting.remove(permission)
                self.publish(result, for: permission)
                SonarLog.write("permission \(permission.rawValue) requested: \(result)")
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
            self?.refresh()
        }
    }

    func stopLiveUpdates() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: - Publishing

    private func apply(screen: SonarPermissionState, automation: SonarPermissionState) {
        let changed = screen != self.screenRecording || automation != self.automation
        publish(screen, for: .screenRecording)
        publish(automation, for: .automation)
        if changed {
            SonarLog.write(
                "permissions: screenRecording=\(screen) automation=\(automation)"
            )
        }
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
