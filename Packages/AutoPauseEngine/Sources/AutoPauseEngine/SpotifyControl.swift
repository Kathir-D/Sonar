import AppKit
import Foundation

/// Spotify player state as reported by AppleScript (`player state`).
public enum SpotifyPlayerState: String, Sendable, Equatable {
    case playing
    case paused
    case stopped
    /// Not running, unreachable, or unrecognized response.
    case unknown
}

/// Test seam + contract boundary for everything the engine needs from Spotify.
///
/// Implementations must:
/// - match only `bundleID == com.spotify.client` (never Dock/window),
/// - use explicit `play`/`pause` (never the `playpause` toggle),
/// - run AppleScript off the main thread with `with timeout of 4 seconds`.
public protocol SpotifyControl: Sendable {
    static var spotifyBundleID: String { get }
    /// Current player state (nil only on transport failure, not on stopped).
    func playerState() -> SpotifyPlayerState?
    /// Current `sound volume` 0...100, nil when unreadable.
    func volume() -> Int?
    /// Set `sound volume`, clamped to 0...100.
    func setVolume(_ value: Int)
    func play()
    func pause()
    /// pid of the running Spotify app, nil when not running.
    func spotifyPID() -> pid_t?
}

public extension SpotifyControl {
    static var spotifyBundleID: String { "com.spotify.client" }

    /// Player state and volume in one go.
    ///
    /// The default performs two reads so test fakes need no changes; the
    /// AppleScript implementation overrides it with a single round trip,
    /// which is what keeps the engine's serial queue responsive.
    func stateAndVolume() -> (state: SpotifyPlayerState?, volume: Int?) {
        (playerState(), volume())
    }
}

/// AppleScript strings. `with timeout of 4 seconds` on every command so a
/// hung Spotify can never wedge the engine's serial queue for long.
public enum SpotifyScript {
    public static func wrap(_ body: String) -> String {
        "with timeout of 4 seconds\n\(body)\nend timeout"
    }

    public static var playerState: String {
        wrap("""
        tell application "Spotify"
            if it is running then
                return player state as string
            else
                return "stopped"
            end if
        end tell
        """)
    }

    public static var stateAndVolume: String {
        wrap("""
        tell application "Spotify"
            if it is running then
                return (player state as string) & "/" & ((sound volume as integer) as string)
            else
                return "stopped/0"
            end if
        end tell
        """)
    }

    public static var getVolume: String {
        wrap("""
        tell application "Spotify"
            if it is running then
                return sound volume as integer
            end if
        end tell
        """)
    }

    public static func setVolume(_ value: Int) -> String {
        wrap("tell application \"Spotify\" to set sound volume to \(min(100, max(0, value)))")
    }

    public static var play: String {
        wrap("tell application \"Spotify\" to play")
    }

    public static var pause: String {
        wrap("tell application \"Spotify\" to pause")
    }

    public static func parseState(_ raw: String?) -> SpotifyPlayerState {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing": return .playing
        case "paused": return .paused
        case "stopped": return .stopped
        default: return .unknown
        }
    }
}

/// Default `SpotifyControl`: NSAppleScript over the serial caller queue plus
/// NSRunningApplication pid lookup by bundle ID.
public final class AppleScriptSpotifyControl: SpotifyControl, @unchecked Sendable {
    public init() {}

    public func playerState() -> SpotifyPlayerState? {
        guard let raw = run(SpotifyScript.playerState) else { return nil }
        return SpotifyScript.parseState(raw)
    }

    public func stateAndVolume() -> (state: SpotifyPlayerState?, volume: Int?) {
        guard let raw = run(SpotifyScript.stateAndVolume) else { return (nil, nil) }
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard let state = parts.first else { return (nil, nil) }
        let volume = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (SpotifyScript.parseState(state), volume)
    }

    public func volume() -> Int? {
        guard let raw = run(SpotifyScript.getVolume)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return Int(raw)
    }

    public func setVolume(_ value: Int) {
        _ = run(SpotifyScript.setVolume(value))
    }

    public func play() {
        _ = run(SpotifyScript.play)
    }

    public func pause() {
        _ = run(SpotifyScript.pause)
    }

    public func spotifyPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotifyBundleID).first?.processIdentifier
    }

    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        return script.executeAndReturnError(&error).stringValue
    }
}
