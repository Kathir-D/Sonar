import AppKit
import Foundation

/// Which detector is actually driving decisions right now.
///
/// This is not a preference, it is a fact about what the machine can tell us:
/// only the tap measures loudness. Poll can answer "is this process holding the
/// audio output", never "is it making sound", so a paused video in a browser
/// reads as loud and the resume is seconds late.
public enum DetectorKind: String, Sendable {
    case tap
    case poll
}

/// Where the Spotify adapter's work runs relative to the engine's tick.
public enum AdapterDispatch: Sendable, Equatable {
    /// The tick calls the adapter's synchronous variants, so a test can tick and
    /// immediately assert ownership. Deterministic, at the cost of the tick
    /// waiting on AppleEvents.
    case onEngineQueue
    /// The tick hands work to the adapter's own serial queue and moves on.
    ///
    /// This is what production uses, and the reason is a fade: `fade()` is a
    /// loop of AppleScript volume writes with a sleep between each, so a
    /// nominal 2 s fade occupied the engine queue for two whole seconds during
    /// which no loud/quiet streak could be evaluated at all - the resume could
    /// not even be *noticed*, let alone acted on. Every command still runs on
    /// one queue, so `NSAppleScript` is never entered from two threads at once.
    case onAdapterQueue
}

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
    /// Where adapter work runs. Tests use `.onEngineQueue`; the app sets
    /// `.onAdapterQueue` so a fade cannot stall detection.
    public var adapterDispatch: AdapterDispatch = .onEngineQueue
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

    /// Low-rate engine telemetry. The decisions are only as good as the loop
    /// that makes them, so the loop itself has to be observable: a tick rate
    /// that has quietly collapsed is indistinguishable from "detection is
    /// slow" from the outside.
    public var onDiagnostic: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "sonar.autopause-engine")
    private var timer: DispatchSourceTimer?
    private var tapIsUsable = true
    private var lastReconcileAt: Date?
    /// Set once the tap's IOProc has delivered a buffer since it was built.
    ///
    /// An aggregate containing only a tap can come up cleanly, report "active",
    /// and then deliver nothing at all (that is exactly what a mis-built
    /// aggregate does: zero streams, no callbacks, no error). Trusting a tap in
    /// that state means loudness detection silently never fires, which is worse
    /// than the poll fallback, so the tap only earns the vote by proving it
    /// carries buffers. Poll drives decisions until then and is the permanent
    /// fallback when the tap is unavailable.
    ///
    /// A rebuild in between does *not* clear it: for the second or two a rebuild
    /// takes there is no evidence either way, and `.tapVerified` re-announcing
    /// itself every time the tap rebuilt was one log line per rebuild.
    private var tapHasAudibleSignal = false
    /// Observation from `NSApplication.willTerminateNotification`, so quitting
    /// while ducked does not leave Spotify paused with nothing scheduled to
    /// resume it. The observer captures the controller weakly, so this token is
    /// only a removal handle.
    private var terminateObserver: NSObjectProtocol?
    private var _drivingDetector: DetectorKind = .poll
    /// Fusion reports `.candidate` on every tick once the streak is long
    /// enough. Emit the event only on the transition into that state so the
    /// diagnostics log shows one line per episode, not one per tick.
    private var candidateAnnounced = false
    /// Tick-rate telemetry state (engine-queue confined).
    private var tickCounter = 0
    private var lastTickReport = Date()
    /// Often enough to diagnose a collapsed loop, rare enough that a day of
    /// running does not push the bounded log's useful history out.
    private static let tickReportInterval: TimeInterval = 30

    /// Which detector the last tick actually used. `.tap` only while the tap
    /// is receiving buffers; otherwise poll-only, which the UI must say out
    /// loud because it cannot tell silence from sound.
    public var drivingDetector: DetectorKind { _drivingDetector }

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
        // Clean up aggregate devices left by a previous run before making a
        // new one, so a force quit cannot pile them up in Audio MIDI Setup.
        let swept = TapDetector.purgeStaleAggregates()
        if !swept.isEmpty {
            onDiagnostic?(
                "removed \(swept.count) leftover aggregate(s): "
                    + swept.map { "\($0.id) (\($0.status))" }.joined(separator: ", ")
            )
        }
        poll.start()
        tap?.start()
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        observeTermination()
    }

    /// Quitting Sonar is indistinguishable, from Spotify's point of view, from
    /// deciding to leave the music paused: the process that knows it was ducked
    /// is going away, and the tick loop stops. So a normal quit (Cmd-Q, logout)
    /// hands the music back on the way out. A force quit cannot be helped -
    /// no code runs at all - which is the one case in this feature where a
    /// wrong music state is unavoidable, and the reason this hook exists for
    /// every other exit path.
    private func observeTermination() {
        guard terminateObserver == nil else { return }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.adapter.restoreAtShutdown()
        }
    }

    public func stop() {
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
            terminateObserver = nil
        }
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
            // loud for as long as it holds it. Measured on macOS 27: a browser
            // playing a video reports "not running output" while the tap
            // clearly sees the sound. So while the tap is live it is the only
            // signal that gets a vote, and poll is the fallback rather than a
            // second opinion to overrule it.
            let pollSignal = poll.refresh()
            // `isCapturing`, not "the tap exists": a tap that never delivers
            // buffers measures nothing, and trusting it would mean never
            // pausing at all.
            let tapIsLive = tapIsUsable && (tap?.isCapturing ?? false)
            // A tap that is mid-rebuild is not the same as a tap that is
            // unavailable, and `isCapturing` cannot tell them apart: it is false
            // for the whole second or two a build takes. Letting poll decide
            // through that window was the worst of both detectors - the engine
            // switched sources mid-episode and credited the streak to poll,
            // which reads a browser holding the output as loud, so plugging in
            // AirPods (a rebuild) paused the music while the room was silent.
            // Holding is the only honest answer: there is no evidence either
            // way, so no new episode starts and no resume is missed. When the
            // build lands, the tap either captures (and takes the vote back) or
            // reports `.unavailable` (and `tapIsUsable` hands it to poll for
            // good).
            let tapIsRebuilding = !tapIsLive && (tap?.isRebuilding ?? false)
            if tapIsLive, !tapHasAudibleSignal {
                tapHasAudibleSignal = true
                onEvent?(.tapVerified)
            } else if !tapIsLive, !tapIsRebuilding {
                tapHasAudibleSignal = false
            }
            // Reported as `.poll` while a rebuild is in flight even though poll
            // is not being consulted: the honest answer to "Sonar can tell
            // silence from sound right now" is no, and the label is only
            // correct again a second later.
            _drivingDetector = tapIsLive ? .tap : .poll
            let decision: FusionDecision
            if tapIsRebuilding {
                decision = .hold
            } else if tapIsLive {
                decision = fusion.evaluate(poll: nil, tap: tap?.latestSignal)
            } else {
                decision = fusion.evaluate(poll: pollSignal, tap: nil)
            }
            // Validate ownership on every tick, not only on `.hold`.
            //
            // Reconcile is the only thing that notices when the world stops
            // matching our assumption - the user pressed play, paused it,
            // moved the volume, quit Spotify, or it restarted. Restricting it
            // to `.hold` meant a long loud streak never re-checked, so an
            // ownership that had gone stale survived indefinitely: the engine
            // believed it had paused Spotify, `duck()` short-circuited on
            // `isOwned`, and auto-pause silently stopped working until the app
            // was restarted. Seen live after toggling Auto-Pause off and on.
            //
            // The throttle is what keeps this affordable: one AppleEvent round
            // trip per `reconcileInterval`, not per tick.
            if adapter.isOwned, shouldReconcile() {
                switch adapterDispatch {
                case .onEngineQueue: adapter.reconcileSync()
                case .onAdapterQueue: adapter.reconcile()
                }
            }

            tickCounter += 1
            let now = Date()
            if now.timeIntervalSince(lastTickReport) > Self.tickReportInterval {
                let elapsed = now.timeIntervalSince(lastTickReport)
                onDiagnostic?(
                    "tick: \(String(format: "%.1f", Double(tickCounter) / elapsed)) Hz "
                        + "detector=\(_drivingDetector.rawValue) "
                        + "mode=\(adapter.mode.rawValue) tap=\(String(format: "%.4f", tap?.lastRMS ?? 0)) "
                        + "poll=\(pollSignal.isActive ? "loud" : "quiet") decision=\(decision) "
                        + "active=\(String(format: "%.1f", fusion.activeDuration))s "
                        + "quiet=\(String(format: "%.1f", fusion.quietDuration))s owned=\(adapter.isOwned)"
                )
                lastTickReport = now
                tickCounter = 0
            }
            switch decision {
            case .candidate(let source):
                if !candidateAnnounced {
                    candidateAnnounced = true
                    onEvent?(.candidate(source: source))
                }
                switch adapterDispatch {
                case .onEngineQueue: adapter.duckSync(source: source)
                case .onAdapterQueue: adapter.duck(source: source)
                }
            case .quiet:
                candidateAnnounced = false
                switch adapterDispatch {
                case .onEngineQueue: adapter.restoreSync()
                case .onAdapterQueue: adapter.restore()
                }
            case .hold:
                break
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
