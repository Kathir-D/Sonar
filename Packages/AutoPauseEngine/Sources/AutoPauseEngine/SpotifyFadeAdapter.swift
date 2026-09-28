import Foundation

/// How Spotify is ducked when another app produces audio.
public enum DuckMode: String, Sendable, CaseIterable {
    /// Fade volume out, pause; fade back in, resume.
    case fadeAndPause
    /// Pause/resume immediately without fading.
    case instant
    /// Set volume to zero and restore, never pausing.
    case muteOnly
}

/// Serialized Spotify fade/pause/resume runner (skeleton).
///
/// Contract (final, task 7):
/// - Matches only `bundleID == com.spotify.client` + AppleScript player state.
/// - Explicit `play`/`pause` (never the `playpause` toggle).
/// - All AppleScript off the main thread on a serial queue,
///   `with timeout of 4 seconds`, 200 ms re-read after each command.
/// - Resume-only-if-we-paused (same pid); manual pause/volume/player
///   restart/Quit relinquishes ownership; generation tokens guard races.
public final class SpotifyFadeAdapter: Sendable {
    /// Spotify's bundle identifier. Never match anything else.
    public static let spotifyBundleID = "com.spotify.client"

    public let mode: DuckMode
    public let fadeOutDuration: TimeInterval
    public let fadeInDuration: TimeInterval

    public init(
        mode: DuckMode = .fadeAndPause,
        fadeOutDuration: TimeInterval = 2.0,
        fadeInDuration: TimeInterval = 2.0
    ) {
        self.mode = mode
        self.fadeOutDuration = fadeOutDuration
        self.fadeInDuration = fadeInDuration
    }

    /// Duck Spotify because `source` is producing audio. Task 7.
    public func duck(source: String) {
        _ = source
    }

    /// Restore Spotify after quiet. Task 7.
    public func restore() {}
}
