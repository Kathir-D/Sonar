import Foundation

/// Fusion decision for one evaluation tick.
public enum FusionDecision: Sendable, Equatable {
    /// Another app is loud: candidate for fade + pause.
    case candidate(source: String)
    /// All quiet long enough: candidate for resume (the adapter still
    /// applies the Spotify-state veto before touching playback).
    case quiet
    /// Hold current state.
    case hold
}

/// OR-active / AND-quiet fusion state machine.
///
/// Rule: either detector loud continuously for >= activeDuration becomes a
/// pause candidate; both detectors quiet continuously for >= quietDuration
/// becomes a resume candidate. Any loud sample resets the quiet streak and
/// vice versa. Pure value type with injected `now` — fully unit-testable.
public struct FusionState: Sendable {
    /// Seconds a signal must stay loud before it becomes a candidate.
    public var activeDuration: TimeInterval
    /// Seconds all signals must stay quiet before resume.
    public var quietDuration: TimeInterval

    private var loudSince: Date?
    private var quietSince: Date?

    /// Start of the current loud streak, if any (diagnostics countdowns).
    public var loudStreakStart: Date? { loudSince }
    /// Start of the current quiet streak, if any (diagnostics countdowns).
    public var quietStreakStart: Date? { quietSince }

    public init(activeDuration: TimeInterval = 1.0, quietDuration: TimeInterval = 3.0) {
        self.activeDuration = activeDuration
        self.quietDuration = quietDuration
    }

    /// Evaluate current detector signals at `now`.
    public mutating func evaluate(poll: AudioSignal?, tap: AudioSignal?, now: Date = Date()) -> FusionDecision {
        let pollLoud = poll?.isActive == true
        let tapLoud = tap?.isActive == true
        if pollLoud || tapLoud {
            quietSince = nil
            if loudSince == nil { loudSince = now }
            guard now.timeIntervalSince(loudSince!) >= activeDuration else { return .hold }
            switch (pollLoud, tapLoud) {
            case (true, true): return .candidate(source: "poll+tap")
            case (true, false): return .candidate(source: "poll")
            case (false, true): return .candidate(source: "tap")
            case (false, false): return .hold // unreachable
            }
        } else {
            loudSince = nil
            if quietSince == nil { quietSince = now }
            guard now.timeIntervalSince(quietSince!) >= quietDuration else { return .hold }
            return .quiet
        }
    }

    /// Reset both streaks (mode change, enable/disable, sleep/wake).
    public mutating func reset() {
        loudSince = nil
        quietSince = nil
    }
}
