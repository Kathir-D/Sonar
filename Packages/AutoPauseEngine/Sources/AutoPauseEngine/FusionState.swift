import Foundation

/// Fusion decision for one evaluation tick.
public enum FusionDecision: Sendable, Equatable {
    /// Another app is loud: candidate for fade + pause.
    case candidate(source: String)
    /// All quiet long enough (and Spotify not independently playing):
    /// candidate for resume.
    case quiet
    /// Hold current state.
    case hold
}

/// OR-active / AND-quiet fusion state machine (skeleton).
///
/// Rule (final, task 7): either detector loud for >= activeDuration
/// becomes a pause candidate; both detectors quiet for >= quietDuration
/// plus `isPlaying() == false` veto becomes a resume candidate.
///
/// Modes: Fade+Pause / Instant / Mute-only (task 7+8).
public struct FusionState: Sendable {
    /// Seconds a signal must stay active before it becomes a candidate.
    public var activeDuration: TimeInterval
    /// Seconds all signals must stay quiet before resume.
    public var quietDuration: TimeInterval

    public init(activeDuration: TimeInterval = 1.0, quietDuration: TimeInterval = 3.0) {
        self.activeDuration = activeDuration
        self.quietDuration = quietDuration
    }

    /// Evaluate current detector signals. Full logic lands in task 7.
    public func evaluate(poll: AudioSignal?, tap: AudioSignal?, now: Date = Date()) -> FusionDecision {
        _ = now
        if poll?.isActive == true || tap?.isActive == true {
            return .candidate(source: "skeleton")
        }
        return .hold
    }
}
