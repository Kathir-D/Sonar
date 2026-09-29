import AutoPauseEngine
import Combine
import Foundation

/// UI-facing engine state for the menu dot + diagnostics.
enum AutoPauseUIState: String {
    case idle
    case listening
    case ducked
    case tapUnavailable
}

/// App singleton owning the `AutoPauseController`. Applies prefs live;
/// the tap itself rebuilds only when its rules change (see TapDetector).
final class SonarEngineHost: ObservableObject {
    static let shared = SonarEngineHost()

    let controller = AutoPauseController()

    @Published private(set) var uiState: AutoPauseUIState = .idle
    @Published private(set) var tapStatusText = "Tap idle"
    @Published private(set) var tapRMS: Float = 0
    @Published private(set) var lastEventText = "—"
    @Published private(set) var pollActive = false
    @Published private(set) var loudCountdown: TimeInterval?
    @Published private(set) var quietCountdown: TimeInterval?
    /// Which detector the engine is actually using. `.poll` means Sonar cannot
    /// tell silence from sound, so a paused video can hold the resume for
    /// seconds — the UI has to say that out loud rather than looking healthy.
    @Published private(set) var drivingDetector: DetectorKind = .poll

    /// True only when the tap is genuinely capturing audio. Not "the tap
    /// object exists" and not "the status says active": a mis-built aggregate
    /// comes up clean and then delivers nothing, and treating that as working
    /// is what made this feature look enabled while it did nothing.
    var tapIsOperational: Bool {
        guard let tap = controller.tap else { return false }
        return tap.isCapturing && {
            if case .active = tap.status { return true }
            return false
        }()
    }

    private var lastRulesFingerprint = ""
    private var cancellables = Set<AnyCancellable>()

    init() {
        controller.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        // One-off build facts (the stream format the HAL settled on, an
        // aggregate that never came alive) belong in the log next to the
        // duck/restore timeline, not just in a transient status string.
        controller.tap?.onDiagnostic = { message in
            SonarLog.write("tap: \(message)")
        }
        controller.adapter.onDiagnostic = { message in
            SonarLog.write("spotify: \(message)")
        }
        controller.onDiagnostic = { message in
            SonarLog.write("engine: \(message)")
        }
    }

    /// Start the engine with the current prefs (called once at launch).
    func start(with prefs: AutoPausePreferencesModel) {
        // A fade is 20 AppleScript writes with sleeps; run it on the adapter's
        // queue so the engine's 10 Hz loop keeps evaluating streaks throughout.
        controller.adapterDispatch = .onAdapterQueue
        lastRulesFingerprint = prefs.rulesFingerprint
        apply(prefs, forceTapRebuild: true)
        controller.start()
        SonarLog.write("engine started (poll-only until tap ready)")
    }

    /// Live-apply prefs. Restarts the tap only when rules changed.
    func apply(_ prefs: AutoPausePreferencesModel, forceTapRebuild: Bool = false) {
        controller.enabled = prefs.enabled
        controller.fusion.activeDuration = prefs.activeDuration
        controller.fusion.quietDuration = prefs.quietDuration
        controller.adapter.mode = prefs.mode
        controller.adapter.fadeOutDuration = prefs.fadeOutDuration
        controller.adapter.fadeInDuration = prefs.fadeInDuration
        controller.poll.filter = prefs.sourceFilter

        let fingerprint = prefs.rulesFingerprint
        var tapConfig = controller.tap?.config ?? TapConfig()
        tapConfig.threshold = Float(prefs.threshold)
        tapConfig.filter = prefs.sourceFilter
        // The tap reports "is it loud right now"; fusion owns how long it has
        // to stay that way. Leaving the tap's own dwell at its 1 s default
        // meant the two stacked and the "Instant" preset still took over a
        // second to react, because the tap never reported itself active in
        // time for the 0.1 s fusion streak to matter.
        tapConfig.activeDuration = 0
        // Just enough hysteresis to ride out a dropped buffer or a momentary
        // dip, not so much that it doubles the resume latency on top of
        // `quietDuration`.
        tapConfig.gapTolerance = 0.15
        if forceTapRebuild || fingerprint != lastRulesFingerprint {
            lastRulesFingerprint = fingerprint
            if controller.tap?.isRunning == true {
                controller.tap?.stop()
                controller.tap?.config = tapConfig
                controller.tap?.start()
                SonarLog.write("tap restarted (rules changed)")
            } else {
                // Not running yet: hand the rules over and let `start()` build.
                // Starting here raced the engine's own start-up sweep, which
                // destroyed the aggregate this had just created - the tap came
                // up "active" and then delivered nothing at all.
                controller.tap?.config = tapConfig
            }
        } else {
            controller.tap?.config = tapConfig
        }

        if !prefs.enabled, controller.adapter.isOwned {
            controller.adapter.restore()
        }
        refreshDiagnostics()
        DispatchQueue.main.async { [weak self] in self?.updateUIState() }
    }

    /// Publish a diagnostics snapshot (called by the pane timer + apply).
    func refreshDiagnostics() {
        let poll = controller.poll.latestSignal
        let tap = controller.tap?.latestSignal
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollActive = poll?.isActive == true
            self.tapRMS = tap?.rms ?? self.controller.tap?.lastRMS ?? 0
            let now = Date()
            if let start = self.controller.fusion.loudStreakStart {
                let elapsed = now.timeIntervalSince(start)
                self.loudCountdown = max(0, self.controller.fusion.activeDuration - elapsed)
                self.quietCountdown = nil
            } else if let start = self.controller.fusion.quietStreakStart {
                let elapsed = now.timeIntervalSince(start)
                self.quietCountdown = max(0, self.controller.fusion.quietDuration - elapsed)
                self.loudCountdown = nil
            } else {
                self.loudCountdown = nil
                self.quietCountdown = nil
            }
            self.updateUIState()
        }
    }

    // MARK: - Internals

    private func handle(_ event: EngineEvent) {
        switch event {
        case .candidate(let source):
            lastEventText = "Candidate (\(source))"
            SonarLog.write("candidate: \(source)")
        case .ducked(let source):
            lastEventText = "Ducked (\(source))"
            SonarLog.write("ducked: \(source)")
        case .restored:
            lastEventText = "Restored"
            SonarLog.write("restored")
        case .relinquished(let reason):
            lastEventText = "Relinquished (\(reason.rawValue))"
            SonarLog.write("relinquished: \(reason.rawValue)")
        case .skippedNotPlaying:
            lastEventText = "Skipped (Spotify not playing)"
        case .tapReady:
            lastEventText = "Tap starting (waiting for buffers)"
            SonarLog.write("tap ready: waiting for buffers to confirm it carries audio")
        case .tapVerified:
            lastEventText = "Tap capturing (loudness detection)"
            SonarLog.write("tap verified: RMS detection is driving decisions (silence is now measured)")
        case .tapUnavailable(let reason):
            lastEventText = "Tap unavailable — poll-only"
            tapStatusText = "Tap unavailable (poll-only)"
            SonarLog.write("tap unavailable: \(reason)")
        }
        updateUIState()
    }

    private func updateUIState() {
        drivingDetector = controller.drivingDetector
        if controller.adapter.isOwned {
            uiState = .ducked
            return
        }
        guard let tap = controller.tap else {
            tapStatusText = "Tap off (poll-only)"
            uiState = pollActive ? .listening : .idle
            return
        }
        switch tap.status {
        case .active:
            if tap.isCapturing {
                tapStatusText = String(format: "Tap capturing (RMS %.3f)", tap.lastRMS)
                uiState = .listening
            } else {
                // Started but starved: the buffers that prove it works have not
                // arrived. Reporting "active" here is what made this look
                // enabled while it measured nothing.
                tapStatusText = "Tap started, no audio (poll-only)"
                uiState = .tapUnavailable
            }
        case .starting:
            tapStatusText = "Tap starting…"
            uiState = .listening
        case .unavailable(let reason):
            tapStatusText = "Tap unavailable (poll-only): \(reason)"
            uiState = .tapUnavailable
        case .idle:
            tapStatusText = "Tap idle"
            uiState = pollActive ? .listening : .idle
        }
    }
}
