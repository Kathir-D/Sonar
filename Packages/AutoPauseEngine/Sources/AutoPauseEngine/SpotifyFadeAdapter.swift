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

    /// Called on an arbitrary queue for diagnostics.
    public var onEvent: (@Sendable (AdapterEvent) -> Void)?

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
        lock.unlock()
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
        lock.unlock()
        onEvent?(.relinquished(reason))
        return reason
    }

    private func duckImpl(source: String, generation: UInt64) {
        if isOwned { return } // already ducked; ticks keep calling duck()
        guard let pid = control.spotifyPID() else { return } // Quit / not running
        guard control.playerState() == .playing else {
            // Paused/stopped/unknown: user (or Spotify) owns the state.
            // Never take ownership -> later restore() can never resume.
            onEvent?(.skippedNotPlaying)
            return
        }
        let captured = control.volume()
        takeOwnership(pid: pid, volume: captured)
        setDuckInProgress(true)
        defer { setDuckInProgress(false) }
        onEvent?(.ducked(source: source))

        switch mode {
        case .fadeAndPause:
            fade(to: 0, over: fadeOutDuration, generation: generation)
            guard generation == currentGeneration() else { return }
            control.pause()
            reread()
        case .instant:
            control.pause()
            reread()
        case .muteOnly:
            setVolumeSync(0, generation: generation)
        }
        if generation == currentGeneration() {
            setDuckedVolume(control.volume())
        }
    }

    private func restoreImpl(generation: UInt64) {
        let owned = snapshot()
        guard let ownedPID = owned.pid else { return } // not owned: nothing to do
        guard let pid = control.spotifyPID() else {
            relinquish(reason: .playerGone)
            return
        }
        guard pid == ownedPID else {
            relinquish(reason: .pidChanged) // restart: new instance owns itself
            return
        }
        let state = control.playerState()
        switch state {
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
        if let current = control.volume(), let ducked = owned.ducked, current != ducked {
            // User moved volume mid-duck: preserve theirs, release everything.
            relinquish(reason: .volumeChangedByUser)
            return
        }
        switch mode {
        case .fadeAndPause:
            control.play()
            reread()
            guard generation == currentGeneration() else { return }
            fade(to: owned.volume ?? 100, over: fadeInDuration, generation: generation)
        case .instant:
            control.play()
            reread()
        case .muteOnly:
            setVolumeSync(owned.volume ?? 100, generation: generation)
        }
        lock.lock()
        _ownedPID = nil
        _duckedVolume = nil
        lock.unlock()
        onEvent?(.restored)
    }

    private func reconcileImpl() {
        let owned = snapshot()
        guard let ownedPID = owned.pid else { return }
        guard let pid = control.spotifyPID(), pid == ownedPID else {
            relinquish(reason: control.spotifyPID() == nil ? .playerGone : .pidChanged)
            return
        }
        // One round trip instead of two. Mid-fade Spotify is still playing
        // because *we* have not paused it yet, so that must not count as a
        // manual resume.
        let (state, volume) = control.stateAndVolume()
        if state == .playing && !duckInProgress {
            restoreVolumeIfUntouched(ownedVolume: owned.volume, duckedVolume: owned.ducked)
            relinquish(reason: .manuallyResumed)
            return
        }
        if duckInProgress { return }
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

    private func reread() {
        Thread.sleep(forTimeInterval: rereadDelay)
        _ = control.playerState()
    }
}

/// Adapter diagnostics for the prefs pane / log.
public enum AdapterEvent: Sendable, Equatable {
    case ducked(source: String)
    case restored
    case relinquished(RelinquishReason)
    case skippedNotPlaying
}
