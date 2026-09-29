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
    /// When we last took ownership by pausing, so a restore that arrives
    /// before Spotify's own state has flipped is not mistaken for the user
    /// pressing play.
    private var duckedAt: Date?
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
        nextGeneration()
        // autoreleasepool: the AppleEvent round trip returns autoreleased
        // descriptors and this queue is a GCD worker thread.
        queue.async { [weak self] in
            autoreleasepool { self?.duckSync(source: source) }
        }
    }

    /// Restore Spotify after quiet. Async; no-ops unless owned.
    public func restore() {
        nextGeneration()
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
        duckedAt = Date()
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
        duckedAt = nil
        lock.unlock()
        onEvent?(.relinquished(reason))
        return reason
    }

    private func duckImpl(source: String, generation: UInt64) {
        let duckStartedAt = Date()
        if isOwned { return } // already ducked; ticks keep calling duck()
        // Do not re-probe Spotify on every tick. The engine calls this at 10 Hz
        // for as long as another app is loud, and one AppleEvent round trip
        // costs ~300 ms, so the ticks were spending nearly all their time
        // asking Spotify whether it was playing. Worse, it stretched the tick
        // so far that the engine could not notice the sound stopping, and the
        // resume came seconds late. A player that is not playing does not
        // start playing on its own, so a short backoff is safe.
        if let lastSkip = lastSkipProbeAt, Date().timeIntervalSince(lastSkip) < skipProbeBackoff {
            return
        }
        guard let pid = liveSpotifyPID(retries: 1) else { return } // Quit / not running
        // One AppleEvent instead of two: player state plus the volume we may
        // need to restore. A round trip costs ~300 ms here, so this alone is
        // the difference between "instant" and "noticeably late".
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
        var probe = control.stateAndVolume()
        if probe.state == .playing, Date().timeIntervalSince(duckedAt ?? .distantPast) < 1.5 {
            // We paused Spotify moments ago and it still reports "playing".
            // That is Spotify's own state transition lagging behind the command,
            // not the user pressing play - and treating it as a manual resume
            // silently ends the duck, leaving the music paused for good. Give
            // the state a moment to catch up before believing it.
            Thread.sleep(forTimeInterval: 0.2)
            probe = control.stateAndVolume()
        }
        switch probe.state {
        case .playing where mode == .muteOnly:
            // We muted; Spotify was never paused, so "playing" is expected.
            // Hand the volume back and report a completed cycle.
            restoreVolumeIfUntouched(ownedVolume: owned.volume, duckedVolume: owned.ducked)
            lock.lock()
            _ownedPID = nil
            _duckedVolume = nil
            duckedAt = nil
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
            duckedAt = nil
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
        case .muteOnly:
            setVolumeSync(owned.volume ?? 100, generation: generation)
        }
        lock.lock()
        _ownedPID = nil
        _duckedVolume = nil
        duckedAt = nil
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
        let (state, volume) = control.stateAndVolume()
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
