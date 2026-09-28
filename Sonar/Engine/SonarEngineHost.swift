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

    private var lastRulesFingerprint = ""
    private var cancellables = Set<AnyCancellable>()

    init() {
        controller.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
    }

    /// Start the engine with the current prefs (called once at launch).
    func start(with prefs: AutoPausePreferencesModel) {
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
        if forceTapRebuild || fingerprint != lastRulesFingerprint {
            lastRulesFingerprint = fingerprint
            controller.tap?.stop()
            controller.tap?.config = tapConfig
            controller.tap?.start()
            SonarLog.write("tap restarted (rules changed)")
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
        case .tapUnavailable(let reason):
            lastEventText = "Tap unavailable — poll-only"
            tapStatusText = "Tap unavailable (poll-only)"
            SonarLog.write("tap unavailable: \(reason)")
        }
        updateUIState()
    }

    private func updateUIState() {
        if controller.adapter.isOwned {
            uiState = .ducked
            return
        }
        if let tap = controller.tap {
            switch tap.status {
            case .active:
                tapStatusText = String(format: "Tap active (RMS %.3f)", tap.lastRMS)
                uiState = .listening
            case .starting:
                tapStatusText = "Tap starting…"
                uiState = .listening
            case .unavailable:
                tapStatusText = "Tap unavailable (poll-only)"
                uiState = .tapUnavailable
            case .idle:
                tapStatusText = "Tap idle"
                uiState = pollActive ? .listening : .idle
            }
        } else {
            tapStatusText = "Tap off (poll-only)"
            uiState = pollActive ? .listening : .idle
        }
    }
}
