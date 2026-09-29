import Foundation

/// How Spotify is ducked when another app produces audio.
public enum DuckMode: String, Sendable, CaseIterable {
    /// Fade volume out, pause; on quiet, resume + fade back in.
    case fadeAndPause
    /// Pause/resume immediately without fading.
    case instant
    /// Set volume to zero and restore, never pausing.
    case muteOnly
}

/// Why ownership was released without resuming.
public enum RelinquishReason: String, Sendable, Equatable {
    case notOwned
    case playerGone
    case pidChanged
    case manuallyResumed
    case manuallyStopped
    case volumeChangedByUser
    case wasPausedAlready
}

/// Serialized Spotify fade/pause/resume runner with ownership.
///
/// Contract:
/// - Spotify matched only via `SpotifyControl` (bundle ID + player state).
/// - All control calls happen on one private serial queue (never main).
/// - 200 ms re-read after each play/pause command.
/// - Resume-only-if-we-paused, same pid: `duck()` takes ownership only when
///   Spotify is playing; any manual pause/volume change, pid change, or Quit
///   relinquishes ownership (volume is preserved, never clobbered).
/// - Generation tokens: overlapping duck/restore cycles can't interleave —
///   stale async work aborts instead of touching playback.
public final class SpotifyFadeAdapter: @unchecked Sendable {
    /// Spotify's bundle identifier. Never match anything else.
    public static let spotifyBundleID = "com.spotify.client"

    public var mode: DuckMode
    public var fadeOutDuration: TimeInterval
    public var fadeInDuration: TimeInterval
    /// Pause between fade steps. Kept small and bounded.
    public var fadeStepInterval: TimeInterval = 0.1
    /// Re-read delay after play/pause commands.
    public var rereadDelay: TimeInterval = 0.2
    /// How long to keep refusing to re-probe after finding Spotify not playing.
    /// Long enough to cover a burst of engine ticks, short enough that starting
    /// playback is noticed promptly.
    public var skipProbeBackoff: TimeInterval = 0.4

    private let control: any SpotifyControl
    private let queue = DispatchQueue(label: "sonar.spotify-fade")

    private let lock = NSLock()
    private var _ownedPID: pid_t?
    private var _ownedVolume: Int?
    private var _duckedVolume: Int?
    private var _generation: UInt64 = 0
    /// True between taking ownership and finishing the pause/mute. While this
    /// is set Spotify is still *playing* by design (a fade takes time), so
    /// reconciliation must not read that as "the user resumed by hand".
    private var _duckInProgress = false
    /// When Spotify was last found not playing, so repeated duck ticks do not
    /// each pay for an AppleEvent round trip.
    private var lastSkipProbeAt: Date?
    /// When we last *sent* the pause command, so a state read that lands
    /// before Spotify has caught up is not mistaken for the user pressing play.
    ///
    /// This is the pause, not the ownership: a fade owns the player for its
    /// whole length, and the state can still be stale long after that.
    private var pausedAt: Date?
    /// How long after our own command a reported state is not yet trusted.
    private static let stateSettleWindow: TimeInterval = 2.0
    /// True while the volume we are responsible for is being restored, so a
    /// reconcile landing mid-fade-in does not read our own `play` as the user
    /// having resumed by hand.
    private var _restoreInProgress = false

    private var restoreInProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _restoreInProgress
    }

    private func setRestoreInProgress(_ value: Bool) {
        lock.lock()
        _restoreInProgress = value
        lock.unlock()
    }

    /// Called on an arbitrary queue for diagnostics.
    public var onEvent: (@Sendable (AdapterEvent) -> Void)?

    /// One-off timing facts, so the gap between "we decided" and "Spotify
    /// actually did it" can be attributed instead of guessed at. Only fires on
    /// state changes, never per tick.
    public var onDiagnostic: (@Sendable (String) -> Void)?

    public init(
        control: (any SpotifyControl)? = nil,
        mode: DuckMode = .fadeAndPause,
        fadeOutDuration: TimeInterval = 2.0,
        fadeInDuration: TimeInterval = 2.0
    ) {
        self.control = control ?? AppleScriptSpotifyControl()
        self.mode = mode
        self.fadeOutDuration = fadeOutDuration
        self.fadeInDuration = fadeInDuration
    }

    /// True while this adapter owns Spotify's playback (we paused/muted it).
    public var isOwned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _ownedPID != nil
    }

    /// Duck Spotify because `source` is producing audio. Async on the serial
    /// queue; safe to call every tick (no-ops while already owned).
    public func duck(source: String) {
        // Only supersede what is already running when this is genuinely a new
        // action.
        //
        // The engine calls this on every 10 Hz tick for as long as another app
        // is loud, so bumping the token unconditionally meant each new tick
        // invalidated the fade already in flight: `fade()` checks the
        // generation every step, saw it had moved, and bailed out before
        // reaching the pause. In Fade mode that never paused Spotify at all -
        // it just pinned the volume to zero and left the player running, which
        // the reconcile then read as the user pressing play, so the engine
        // gave up and started again, several times a second.
        //
        // Keying on "is a duck already in flight" rather than "are we owned"
        // keeps the token doing its real job: a duck that arrives while a
        // *restore* is running is a new action and must supersede it.
        if !duckInProgress { nextGeneration() }
        // autoreleasepool: the AppleEvent round trip returns autoreleased
        // descriptors and this queue is a GCD worker thread.
        queue.async { [weak self] in
            autoreleasepool { self?.duckSync(source: source) }
        }
    }

    /// Restore Spotify after quiet. Async; no-ops unless owned.
    public func restore() {
        // Same reasoning in the other direction: repeated restores while one
        // is already running must not cancel each other.
        if !restoreInProgress { nextGeneration() }
        queue.async { [weak self] in
            autoreleasepool { self?.restoreSync() }
        }
    }

    /// Per-tick reconciliation while idle or owned: detects manual resume /
    /// manual volume change / pid change and relinquishes. Call from the
    /// engine tick; sync (cheap) — performs at most two AppleScript reads.
    public func reconcile() {
        queue.async { [weak self] in
            autoreleasepool { self?.reconcileSync() }
        }
    }

    /// Synchronous variants for tests (run on the calling thread).
    public func duckSync(source: String) { duckImpl(source: source, generation: currentGeneration()) }
    public func restoreSync() { restoreImpl(generation: currentGeneration()) }
    public func reconcileSync() { reconcileImpl() }

    /// Undo a duck as the app quits.
    ///
    /// The process is on its way out, so this is the normal restore with every
    /// nicety traded away: no re-read, no settle, no fade back in, and above
    /// all a *budget*. A quit that hangs is worse than a resume that did not
    /// happen, so the wait gives up and the queue is abandoned once it is spent.
    ///
    /// It is deliberately its own decision rather than `restoreImpl` with a
    /// flag. The normal restore reads the state and then the volume separately
    /// and can spend three round trips before it plays; here the state and the
    /// volume come back in the single `stateAndVolume` read (that is what the
    /// protocol requirement bought) and the volume is only written when this
    /// mode actually lowered it, so the whole undo is at most three AppleEvents.
    ///
    /// Two branches differ from the normal restore, both forced by the clock. A
    /// `play` that lands while the state already reads `.playing` is a no-op
    /// here rather than the "the user pressed play" evidence it is during a live
    /// episode - and our own `pause` may not have landed even though ownership
    /// was taken - so it is sent. And `.stopped` still means hands off: never
    /// start playback the user stopped.
    public func restoreAtShutdown() {
        // Nothing was ducked, so nothing can be stranded. Checked before the
        // queue hop so a normal quit costs nothing at all.
        guard isOwned else { return }
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                let owned = self.snapshot()
                // Same pid or nothing: a Spotify that restarted is its own
                // instance's business, exactly as in the normal restore.
                if let pid = self.liveSpotifyPID(retries: 1), pid == owned.pid {
                    let probe = self.control.stateAndVolume()
                    // Instant never writes the volume, so there is nothing to
                    // hand back and no reason to spend a round trip finding out.
                    // Otherwise the same rule as the normal restore - give the
                    // volume back unless we positively know the user moved it -
                    // using the volume that came back in `probe` instead of
                    // paying for a third read.
                    if self.mode != .instant {
                        let userMovedIt: Bool
                        if let current = probe.volume, let ducked = owned.ducked {
                            userMovedIt = current != ducked
                        } else {
                            userMovedIt = false
                        }
                        if !userMovedIt, let want = owned.volume {
                            self.control.setVolume(want)
                        }
                    }
                    if self.mode != .muteOnly, probe.state != .stopped {
                        self.control.play()
                    }
                    self.onEvent?(.restored)
                }
                self.releaseOwnership()
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.shutdownRestoreBudget)
    }

    /// Wall clock this will spend trying to hand the music back before the quit
    /// continues regardless: one round trip of headroom over the three the undo
    /// above can need.
    private static let shutdownRestoreBudget: TimeInterval = 1.25

    // MARK: - Internals

    private func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _generation
    }

    private func nextGeneration() {
        lock.lock()
        _generation &+= 1
        lock.unlock()
    }

    private func snapshot() -> (pid: pid_t?, volume: Int?, ducked: Int?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (_ownedPID, _ownedVolume, _duckedVolume, _generation)
    }

    private func takeOwnership(pid: pid_t, volume: Int?) {
        lock.lock()
        _ownedPID = pid
        _ownedVolume = volume
        _duckedVolume = nil
        lastSkipProbeAt = nil
        pausedAt = nil
        lock.unlock()
    }

    /// The player state, re-read once if it may not have caught up with a
    /// command we have just sent.
    ///
    /// Spotify does not flip `player state` in the same instant the pause or
    /// play command returns. Reading it straight afterwards can return the
    /// *previous* value, and "playing" read that way looks exactly like the
    /// user pressing play: the adapter relinquishes a duck it is still in the
    /// middle of, the engine immediately ducks again, and in Fade mode that
    /// becomes a visible loop of fade-out / give-up / fade-out. Observed live.
    private func settledPlayerState() -> SpotifyPlayerState? {
        let state = control.playerState()
        guard state == .playing else { return state }
        lock.lock()
        let sentPauseAt = pausedAt
        lock.unlock()
        guard let sentPauseAt,
            Date().timeIntervalSince(sentPauseAt) < Self.stateSettleWindow
        else { return state }
        Thread.sleep(forTimeInterval: 0.2)
        return control.playerState()
    }

    private func markPaused() {
        lock.lock()
        pausedAt = Date()
        lock.unlock()
    }

    /// pid of the running Spotify, with a brief retry.
    ///
    /// One empty read from `NSRunningApplication` is not proof the player quit:
    /// the running-application list is a LaunchServices cache and it does come
    /// back empty for a moment during app-state churn. Believing a single miss
    /// meant relinquishing ownership on a live player, which left Spotify paused
    /// with nobody left to resume it - the worst possible outcome for a feature
    /// whose entire job is to start the music again.
    private func liveSpotifyPID(retries: Int = 3, delay: TimeInterval = 0.12) -> pid_t? {
        for attempt in 0...retries {
            if let pid = control.spotifyPID() { return pid }
            if attempt < retries { Thread.sleep(forTimeInterval: delay) }
        }
        return nil
    }

    private func setDuckedVolume(_ value: Int?) {
        lock.lock()
        _duckedVolume = value
        lock.unlock()
    }

    private var duckInProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _duckInProgress
    }

    private func setDuckInProgress(_ value: Bool) {
        lock.lock()
        _duckInProgress = value
        lock.unlock()
    }

    @discardableResult
    private func relinquish(reason: RelinquishReason) -> RelinquishReason {
        lock.lock()
        _ownedPID = nil
        _duckedVolume = nil
        lastSkipProbeAt = nil
        pausedAt = nil
        lock.unlock()
        onEvent?(.relinquished(reason))
        return reason
    }

    /// Drop ownership without announcing a reason: the cycle finished, so
    /// there is nothing to give up.
    private func releaseOwnership() {
        lock.lock()
        _ownedPID = nil
        _duckedVolume = nil
        lastSkipProbeAt = nil
        pausedAt = nil
        lock.unlock()
    }

    private func duckImpl(source: String, generation: UInt64) {
        let duckStartedAt = Date()
        if isOwned { return } // already ducked; ticks keep calling duck()
        // Do not re-probe Spotify on every tick. The engine calls this at 10 Hz
        // for as long as another app is loud, and even a fast AppleEvent round
        // trip (5-30 ms measured, not the ~300 ms an `osascript` process spawn
        // costs - that figure was in a comment here for months and was simply
        // the wrong number) is a third of the tick budget spent asking Spotify
        // whether it is playing. Worse, the ticks were stretched enough that
        // the engine could not notice the sound stopping, so the resume came
        // seconds late. A player that is not playing does not start playing on
        // its own, so a short backoff is safe.
        if let lastSkip = lastSkipProbeAt, Date().timeIntervalSince(lastSkip) < skipProbeBackoff {
            return
        }
        guard let pid = liveSpotifyPID(retries: 1) else { return } // Quit / not running
        // One AppleEvent instead of two: player state plus the volume we may
        // need to restore. Worth having because it halves the round trips on
        // the path the "instant" mode is named after.
        let probe = control.stateAndVolume()
        guard probe.state == .playing else {
            // Paused/stopped/unknown: user (or Spotify) owns the state.
            // Never take ownership -> later restore() can never resume.
            lock.lock()
            lastSkipProbeAt = Date()
            lock.unlock()
            onEvent?(.skippedNotPlaying)
            return
        }
        lock.lock()
        lastSkipProbeAt = nil
        lock.unlock()
        let probedAt = Date()
        takeOwnership(pid: pid, volume: probe.volume)
        setDuckInProgress(true)
        defer { setDuckInProgress(false) }
        onEvent?(.ducked(source: source))

        switch mode {
        case .fadeAndPause:
            fade(to: 0, over: fadeOutDuration, generation: generation)
            guard generation == currentGeneration() else { return }
            control.pause()
            markPaused()
            reread()
            if generation == currentGeneration() {
                setDuckedVolume(control.volume())
            }
        case .instant:
            // Instant mode never *writes* the volume, but it still has to
            // remember what it was. Without a recorded value the adapter cannot
            // tell "the user moved the slider while we were ducked" from "we own
            // the volume", so an interrupt would write the pre-duck volume back
            // over whatever the user had chosen. The user's 42 becomes 70.
            setDuckedVolume(probe.volume)
            onDiagnostic?("duck: probe took \(Self.ms(since: duckStartedAt))ms, sending pause")
            control.pause()
            markPaused()
            onDiagnostic?("duck: pause command returned in \(Self.ms(since: probedAt))ms")
            settle()
            onDiagnostic?("duck: complete in \(Self.ms(since: duckStartedAt))ms")
        case .muteOnly:
            setVolumeSync(0, generation: generation)
            if generation == currentGeneration() {
                setDuckedVolume(control.volume())
            }
        }
    }

    private func restoreImpl(generation: UInt64) {
        let owned = snapshot()
        guard let ownedPID = owned.pid else { return } // not owned: nothing to do
        guard let pid = liveSpotifyPID() else {
            relinquish(reason: .playerGone)
            return
        }
        guard pid == ownedPID else {
            relinquish(reason: .pidChanged) // restart: new instance owns itself
            return
        }
        // Give a reported state that may predate our own last command a moment
        // to catch up, so our pause is not read back as the user pressing play.
        let probe = (state: settledPlayerState(), volume: control.volume())
        switch probe.state {
        case .playing where mode == .muteOnly:
            // We muted; Spotify was never paused, so "playing" is expected.
            // Hand the volume back and report a completed cycle.
            restoreVolumeIfUntouched(ownedVolume: owned.volume, duckedVolume: owned.ducked)
            lock.lock()
            _ownedPID = nil
            _duckedVolume = nil
            pausedAt = nil
            lock.unlock()
            onEvent?(.restored)
            return
        case .playing:
            // User resumed manually (or it never paused): restore our volume
            // duck if untouched, never call play, release ownership.
            restoreVolumeIfUntouched(ownedVolume: owned.volume, duckedVolume: owned.ducked)
            relinquish(reason: .manuallyResumed)
            return
        case .stopped, .unknown, .none:
            // Stopped (or unreachable): never start playback the user stopped.
            restoreVolumeIfUntouched(ownedVolume: owned.volume, duckedVolume: owned.ducked)
            relinquish(reason: .manuallyStopped)
            return
        case .paused:
            break // ours to resume
        }
        if let current = probe.volume, let ducked = owned.ducked, current != ducked {
            // User moved volume mid-duck: preserve theirs, release everything.
            relinquish(reason: .volumeChangedByUser)
            return
        }
        switch mode {
        case .fadeAndPause:
            setRestoreInProgress(true)
            defer { setRestoreInProgress(false) }
            control.play()
            reread()
            guard generation == currentGeneration() else { return }
            fade(to: owned.volume ?? 100, over: fadeInDuration, generation: generation)
        case .muteOnly:
            // Mute-only never paused anything, so "playing" here is our own
            // state rather than the user jumping in. Restore the volume and
            // report a completed cycle; calling it a manual resume told the
            // user they had done something they had not.
            setRestoreInProgress(true)
            defer { setRestoreInProgress(false) }
            restoreVolumeIfUntouched(ownedVolume: owned.volume, duckedVolume: owned.ducked)
            lock.lock()
            _ownedPID = nil
            _duckedVolume = nil
            pausedAt = nil
            lock.unlock()
            onEvent?(.restored)
            return
        case .instant:
            // As in duck: no volume to reconcile, so skip the extra round trip.
            let startedAt = Date()
            onDiagnostic?("restore: sending play")
            control.play()
            onDiagnostic?("restore: play command returned in \(Self.ms(since: startedAt))ms")
            settle()
        }
        lock.lock()
        _ownedPID = nil
        _duckedVolume = nil
        pausedAt = nil
        lock.unlock()
        onEvent?(.restored)
    }

    private func reconcileImpl() {
        let owned = snapshot()
        guard let ownedPID = owned.pid else { return }
        guard let pid = liveSpotifyPID(retries: 1) else {
            relinquish(reason: .playerGone)
            return
        }
        guard pid == ownedPID else {
            relinquish(reason: .pidChanged) // restart: new instance owns itself
            return
        }
        // One round trip instead of two. Mid-fade Spotify is still playing
        // because *we* have not paused it yet, and mid-restore because *we*
        // just called play, so in both cases "playing" is our own state and not
        // the user acting. Mute-only never pauses at all, so for that mode
        // "playing" carries no information either - and getting it wrong made
        // the adapter fight itself, handing the volume back in the middle of
        // its own duck, which is the loud blare the mode exists to prevent.
        let volume = control.volume()
        let state = settledPlayerState()
        let ourOwnChange = duckInProgress || restoreInProgress
        if state == .playing, !ourOwnChange, mode != .muteOnly {
            restoreVolumeIfUntouched(ownedVolume: owned.volume, duckedVolume: owned.ducked)
            relinquish(reason: .manuallyResumed)
            return
        }
        if ourOwnChange { return }
        // The volume check is independent of the state check, and in mute-only
        // it is the only way to notice the user intervening at all.
        if let current = volume, let ducked = owned.ducked, current != ducked {
            relinquish(reason: .volumeChangedByUser)
        }
    }

    private func restoreVolumeIfUntouched(ownedVolume: Int?, duckedVolume: Int?) {
        guard let want = ownedVolume else { return }
        if let current = control.volume(), let ducked = duckedVolume, current != ducked {
            return // user's now: preserve restore volume on interrupt
        }
        control.setVolume(want)
    }

    private func setVolumeSync(_ value: Int, generation: UInt64) {
        guard generation == currentGeneration() else { return }
        control.setVolume(value)
    }

    /// Linear fade in bounded ~0.1 s steps. Aborts on supersede (generation).
    private func fade(to target: Int, over duration: TimeInterval, generation: UInt64) {
        guard duration > 0 else {
            setVolumeSync(target, generation: generation)
            return
        }
        let start = control.volume() ?? target
        let steps = max(1, Int(duration / fadeStepInterval))
        for i in 1...steps {
            guard generation == currentGeneration() else { return }
            let t = Double(i) / Double(steps)
            setVolumeSync(Int(round(Double(start) + (Double(target) - Double(start)) * t)), generation: generation)
            Thread.sleep(forTimeInterval: fadeStepInterval)
        }
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func reread() {
        Thread.sleep(forTimeInterval: rereadDelay)
        _ = control.playerState()
    }

    /// Same settle delay without the follow-up read. For the instant path,
    /// where no volume has to be reconciled afterwards.
    private func settle() {
        Thread.sleep(forTimeInterval: rereadDelay)
    }
}

/// Adapter diagnostics for the prefs pane / log.
public enum AdapterEvent: Sendable, Equatable {
    case ducked(source: String)
    case restored
    case relinquished(RelinquishReason)
    case skippedNotPlaying
}
