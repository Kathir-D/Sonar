/// AutoPauseEngine — hybrid Spotify auto-pause engine for Sonar.
///
/// Fuses two no-permission/low-permission signals to decide when another app
/// is producing audio, then fades + pauses Spotify and resumes when quiet:
///
/// - ``HybridDetector``: poll (`IsRunningOutput`) + CoreAudio tap (RMS) inputs.
/// - ``FusionState``: OR-active / AND-quiet state machine.
/// - ``SpotifyFadeAdapter``: bounded, serialized Spotify fade/pause/resume.
///
/// New code in this package is MIT (c) 2026 Sonar Contributors.
/// Poll-detector files additionally carry their SmartPause MIT provenance
/// headers; see THIRD-PARTY-NOTICES.md. The tap detector is a clean-room
/// implementation from Apple documentation only — no FlowSound code.
public enum AutoPauseEngine {
    /// Semantic version of the engine API. Bump on breaking changes.
    public static let version = "0.1.0"
}
