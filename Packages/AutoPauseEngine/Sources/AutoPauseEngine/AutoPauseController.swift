import Foundation

/// Engine-level diagnostics for the prefs pane and log.
public enum EngineEvent: Sendable, Equatable {
    case candidate(source: String)
    case ducked(source: String)
    case restored
    case relinquished(RelinquishReason)
    case skippedNotPlaying
    case tapUnavailable(reason: String)
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
    public var poll: PollDetector
    /// Nil (or unavailable) means poll-only mode.
    public var tap: TapDetector?
    public var fusion = FusionState()
    public var adapter: SpotifyFadeAdapter
    public var enabled = true
    public var tickInterval: TimeInterval = 0.1

    /// Called on an arbitrary queue for diagnostics / logging.
    public var onEvent: (@Sendable (EngineEvent) -> Void)?

    private let queue = DispatchQueue(label: "sonar.autopause-engine")
    private var timer: DispatchSourceTimer?
    private var tapIsUsable = true

    public init(
        poll: PollDetector = PollDetector(),
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
    }

    /// One engine tick. Public + synchronous for tests.
    public func tick() {
        guard enabled else { return }
        let pollSignal = poll.refresh()
        let tapSignal = tapIsUsable ? tap?.latestSignal : nil
        let decision = fusion.evaluate(poll: pollSignal, tap: tapSignal)
        switch decision {
        case .candidate(let source):
            onEvent?(.candidate(source: source))
            adapter.duckSync(source: source)
        case .quiet:
            adapter.restoreSync()
        case .hold:
            adapter.reconcileSync()
        }
    }

    // MARK: - Internals

    private func tapStatusChanged(_ status: TapStatus) {
        switch status {
        case .unavailable(let reason):
            tapIsUsable = false
            onEvent?(.tapUnavailable(reason: reason))
        case .active, .starting:
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
