import Foundation

/// A single loudness/activity observation from either detector.
public struct AudioSignal: Sendable, Equatable {
    /// True when the observed app is currently producing audio.
    public var isActive: Bool
    /// RMS loudness 0...1 when known (tap detector); nil for poll detector.
    public var rms: Float?
    /// When the observation was made.
    public var at: Date

    public init(isActive: Bool, rms: Float? = nil, at: Date = Date()) {
        self.isActive = isActive
        self.rms = rms
        self.at = at
    }
}

/// Common interface for the two detection backends.
///
/// - Poll: `IsRunningOutput` process scan, no permissions, coarse.
/// - Tap: CoreAudio tap RMS, needs Audio Capture permission, fine-grained.
///
/// Full implementations land in tasks 5 (poll, SmartPause MIT port) and
/// 6 (tap, clean-room from Apple docs).
public protocol HybridDetector: Sendable {
    /// Human-readable backend name, e.g. "poll" or "tap".
    var name: String { get }
    /// Latest observation, or nil if the backend has no data yet.
    var latestSignal: AudioSignal? { get }
    /// Start producing observations.
    func start()
    /// Stop producing observations and release system resources.
    func stop()
}

/// A detector the engine can re-scan synchronously on its own tick.
///
/// The poll backend is polled this way (a cheap on-demand process scan). The
/// tap backend pushes instead, so it stays on plain `HybridDetector`.
public protocol RefreshingDetector: HybridDetector {
    /// Re-scan now, publish, and return the fresh signal.
    func refresh() -> AudioSignal
    /// User source-selection rules, applied while refreshing.
    var filter: SourceFilter { get set }
}
