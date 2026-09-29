import Foundation

/// One-click Auto-Pause configurations.
///
/// A preset sets the duck mode *and* the timings that mode needs. Without
/// this, picking "Instant" only changed the fade behaviour while leaving the
/// multi-second dwell times from the fade preset in place, so "instant" still
/// took seconds to duck and resume.
public enum AutoPausePreset: String, Sendable, CaseIterable, Identifiable {
    /// Gradual: fades out, pauses, waits, then fades back in. For people who
    /// do not want music to stop abruptly.
    case fade
    /// Immediate: pauses on the first detection and resumes as soon as the
    /// other app goes quiet. Timings are near the engine tick so the
    /// configured value is also the felt latency.
    case instant

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fade: return "Fade"
        case .instant: return "Instant"
        }
    }

    public var summary: String {
        switch self {
        case .fade:
            return "Fades out over 2s, pauses, waits 3s of quiet, then fades back in."
        case .instant:
            return "Pauses as soon as another app plays, resumes the moment it goes quiet."
        }
    }

    public var mode: DuckMode {
        switch self {
        case .fade: return .fadeAndPause
        case .instant: return .instant
        }
    }

    /// Seconds another audio must be loud before we act.
    public var activeDuration: TimeInterval {
        switch self {
        case .fade: return 1.0
        case .instant: return 0.1
        }
    }

    /// Seconds of quiet before we resume.
    public var quietDuration: TimeInterval {
        switch self {
        case .fade: return 3.0
        case .instant: return 0.3
        }
    }

    public var fadeOutDuration: TimeInterval {
        switch self {
        case .fade: return 2.0
        case .instant: return 0.0
        }
    }

    public var fadeInDuration: TimeInterval {
        switch self {
        case .fade: return 2.0
        case .instant: return 0.0
        }
    }

    /// RMS at or above which this preset considers the room loud.
    ///
    /// Instant uses a lower threshold than Fade on purpose: its whole promise is
    /// that it reacts before a video has properly started, and a fade can
    /// afford to wait for the sound to be unambiguous.
    public var threshold: Float {
        switch self {
        case .fade: return 0.02
        case .instant: return 0.01
        }
    }

    /// True when the supplied settings are (within float tolerance) exactly
    /// what this preset configures. Drives the "Custom" state in the UI.
    ///
    /// Every field a preset owns participates, including the threshold: the UI
    /// derives "Custom" from this, so leaving one field out would keep labelling
    /// hand-tuned settings as a preset.
    ///
    /// `threshold` has no default on purpose. A default equal to one preset's
    /// value silently answers for every receiver, which made
    /// `AutoPausePreset.instant.matches(...)` permanently false (its threshold
    /// is 0.01, the default was 0.02) and meant "Instant" could never be
    /// reported as selected no matter what the user picked.
    public func matches(
        mode: DuckMode,
        activeDuration: TimeInterval,
        quietDuration: TimeInterval,
        fadeOutDuration: TimeInterval,
        fadeInDuration: TimeInterval,
        threshold: Float
    ) -> Bool {
        mode == self.mode
            && Self.near(activeDuration, self.activeDuration)
            && Self.near(quietDuration, self.quietDuration)
            && Self.near(fadeOutDuration, self.fadeOutDuration)
            && Self.near(fadeInDuration, self.fadeInDuration)
            && Self.near(Float(threshold), self.threshold)
    }

    private static func near(_ a: TimeInterval, _ b: TimeInterval) -> Bool {
        abs(a - b) < 0.001
    }

    private static func near(_ a: Float, _ b: Float) -> Bool {
        abs(a - b) < 0.0001
    }
}
