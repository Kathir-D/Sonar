import Foundation

/// Engine-level diagnostics for the prefs pane and log.
public enum EngineEvent: Sendable, Equatable {
    case candidate(source: String)
    case ducked(source: String)
    case restored
    case relinquished(RelinquishReason)
    case skippedNotPlaying
    case tapUnavailable(reason: String)
    /// The tap started: loudness (RMS) detection is live, so silence is
    /// finally distinguishable from sound.
    case tapReady
    /// The tap has carried real signal, so it is now trusted over poll.
    case tapVerified
}

/// Orchestrates poll + tap detectors, fusion, and the fade adapter.
///
/// - Ticks every `tickInterval` (0.1 s): poll refresh, tap latest, fusion
///   evaluate, duck/restore/reconcile.
/// - Owns nothing Spotify-side itself; all playback goes through
///   `SpotifyFadeAdapter` (ownership, generations, serial queue).
/// - If the tap reports `.unavailable`/`.denied`, the engine keeps running
///   poll-only and emits `.tapUnavailable` for the diagnostics banner.
public final class AutoPauseController: @unchecked Sendable {
    public var poll: any RefreshingDetector
    /// Nil (or unavailable) means poll-only mode.
    public var tap: TapDetector?
    public var fusion = FusionState()
    public var adapter: SpotifyFadeAdapter
    public var enabled = true
    public var tickInterval: TimeInterval = 0.1
    /// Minimum spacing between ownership reconciliations.
    ///
    /// Reconcile costs an AppleEvent round trip (or several), and it used to
    /// run on every 0.1 s tick. That starved the fusion evaluation: measured
    /// with quietDuration = 1 s, resume actually took ~5.3 s because the tick
    /// was still draining queued AppleEvents. Detecting a manual pause/resume
    /// or volume nudge does not need 10 Hz.
    public var reconcileInterval: TimeInterval = 0.5

    /// Called on an arbitrary queue for diagnostics / logging.
    public var onEvent: (@Sendable (EngineEvent) -> Void)?

    private let queue = DispatchQueue(label: "sonar.autopause-engine")
    private var timer: DispatchSourceTimer?
    private var tapIsUsable = true
    private var lastReconcileAt: Date?
    /// Set once the tap has reported a non-zero RMS sample since it started.
    ///
    /// An aggregate containing only a tap can come up cleanly, report
    /// "active", and then deliver nothing but zeros - no running clock, no
    /// data. Trusting a tap in that state would mean auto-pause never fires
    /// at all, which is worse than the poll fallback. So the tap only earns
    /// the vote by proving it carries signal: until then poll drives
    /// decisions, and the moment any real sound arrives the tap takes over
    /// and silence finally becomes distinguishable from sound.
    private var tapHasAudibleSignal = false
    /// Fusion reports `.candidate` on every tick once the streak is long
    /// enough. Emit the event only on the transition into that state so the
    /// diagnostics log shows one line per episode, not one per tick.
    private var candidateAnnounced = false

    public init(
        poll: any RefreshingDetector = PollDetector(),
        tap: TapDetector? = TapDetector(),
        adapter: SpotifyFadeAdapter = SpotifyFadeAdapter()
    ) {
        self.poll = poll
        self.tap = tap
        self.adapter = adapter
        adapter.onEvent = { [weak self] event in self?.forward(event) }
        tap?.onStatusChange = { [weak self] status in self?.tapStatusChanged(status) }
    }

    public func start() {
        poll.start()
        tap?.start()
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        poll.stop()
        tap?.stop()
        fusion.reset()
        lastReconcileAt = nil
        candidateAnnounced = false
        tapHasAudibleSignal = false
    }

    /// One engine tick. Public + synchronous for tests.
    public func tick() {
        // The engine queue is a GCD worker thread, and the poll scan plus the
        // AppleEvent reads hand back autoreleased objects (NSAppleScript
        // descriptors, NSRunningApplication results). Without a pool they get
        // over-released and the next tick reads freed memory.
        autoreleasepool {
            guard enabled else { return }
            // Always refresh poll: it feeds the diagnostics UI. But poll can
            // only ask "does this process hold the audio output?", never "is
            // it making sound" - 45s of pure digital silence reads as loud,
            // and an app holding the device (a paused browser tab) reads as
            // loud for as long as it holds it. So while the tap is live it is
            // the only signal that gets a vote: it is the sole detector that
            // measures actual loudness. Poll is the fallback for when the
            // tap is unavailable, not a second opinion to overrule it.
            let pollSignal = poll.refresh()
            let tapSignal = tapIsUsable ? tap?.latestSignal : nil
            if let rms = tapSignal?.rms, rms > 0.0001, !tapHasAudibleSignal {
                tapHasAudibleSignal = true
                onEvent?(.tapVerified)
            }
            let useTap = tapIsUsable && tapHasAudibleSignal
            let decision: FusionDecision
            if useTap {
                decision = fusion.evaluate(poll: nil, tap: tapSignal)
            } else {
                decision = fusion.evaluate(poll: pollSignal, tap: nil)
            }
            switch decision {
            case .candidate(let source):
                if !candidateAnnounced {
                    candidateAnnounced = true
                    onEvent?(.candidate(source: source))
                }
                adapter.duckSync(source: source)
            case .quiet:
                candidateAnnounced = false
                adapter.restoreSync()
            case .hold:
                if shouldReconcile() { adapter.reconcileSync() }
            }
        }
    }

    /// True at most once per `reconcileInterval`. Cheap guards first so the
    /// throttle never costs an AppleEvent of its own.
    private func shouldReconcile() -> Bool {
        guard adapter.isOwned else { return false }
        let now = Date()
        if let last = lastReconcileAt, now.timeIntervalSince(last) < reconcileInterval {
            return false
        }
        lastReconcileAt = now
        return true
    }

    // MARK: - Internals

    private func tapStatusChanged(_ status: TapStatus) {
        switch status {
        case .unavailable(let reason):
            tapIsUsable = false
            tapHasAudibleSignal = false
            onEvent?(.tapUnavailable(reason: reason))
        case .active:
            tapIsUsable = true
            onEvent?(.tapReady)
        case .starting:
            tapIsUsable = true
        case .idle:
            break
        }
    }

    private func forward(_ event: AdapterEvent) {
        switch event {
        case .ducked(let source): onEvent?(.ducked(source: source))
        case .restored: onEvent?(.restored)
        case .relinquished(let reason): onEvent?(.relinquished(reason))
        case .skippedNotPlaying: onEvent?(.skippedNotPlaying)
        }
    }
}
