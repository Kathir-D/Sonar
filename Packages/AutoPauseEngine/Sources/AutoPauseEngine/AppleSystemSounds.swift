import Darwin
import Foundation

/// Recognises the processes macOS uses to play its own sounds, so a
/// notification ding or an alert beep does not pause the music.
///
/// Identification is by *who is playing*, never by how long or how loud the
/// sound is. A short clip from any other app (a Slack ping, a game effect, a
/// two-second video) is still that app's audio and still pauses Spotify.
///
/// Measured on macOS 27.0 (2026-10-03) by watching
/// `kAudioProcessPropertyIsRunningOutput` while each sound played:
///
/// | Sound                                                   | Process              |
/// | ------------------------------------------------------- | -------------------- |
/// | Notification Center banner sound (a Reminders alarm)    | `systemsoundserverd` |
/// | `NSBeep`, `AudioServicesPlayAlertSound`                 | `systemsoundserverd` |
/// | `AudioServicesPlaySystemSound` from any app             | `systemsoundserverd` |
/// | Screenshot shutter                                      | `systemsoundserverd` |
/// | Charger connected chime                                 | `PowerChime`         |
/// | `NSSound(named:).play()` / `afplay` (in-process audio)  | the app itself       |
///
/// The last row is the point: an app playing a sound file itself shows up as
/// that app, so it is never mistaken for a system sound.
///
/// Why the executable path and not the name or the bundle id: Core Audio's
/// bundle id is whatever the binary's Info.plist says, and any app can claim
/// `systemsoundserverd`. `NSRunningApplication` has no `localizedName` for a
/// daemon at all, which is why the old name-only rule (`"systemsoundserverd"`
/// against a name that actually reads `"pid 3021"`) never matched a single
/// process on a real machine. The path comes from the kernel (`proc_pidpath`),
/// and the directories accepted below are on the sealed, SIP-protected system
/// volume, where nothing but an OS update can put a binary.
public enum AppleSystemSounds {
    /// Executable names of the system-sound players.
    public static let executableNames: Set<String> = [
        "systemsoundserverd",  // alerts, beeps, notification and UI sounds
        "usernoted",  // Notification Center's daemon
        "PowerChime",  // the charger chime
    ]

    /// Directory prefixes that only the OS can write to. `/usr/local` is
    /// deliberately absent: it is user-writable, so a binary there proves
    /// nothing.
    public static let protectedPrefixes: [String] = [
        "/System/",
        "/usr/sbin/",
        "/usr/libexec/",
        "/usr/bin/",
    ]

    /// True when `path` is one of Apple's system-sound players.
    public static func isSystemSoundPlayer(executablePath path: String) -> Bool {
        guard protectedPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        // `..` could walk out of a protected directory and back into an
        // unprotected one. The kernel never reports such a path, but this
        // check is cheaper than proving that for every macOS release.
        guard !path.contains("/../") else { return false }
        let name = (path as NSString).lastPathComponent
        return executableNames.contains(name)
    }

    public static func isSystemSoundPlayer(_ process: AudioProcess) -> Bool {
        isSystemSoundPlayer(executablePath: process.executablePath)
    }

    /// The kernel's record of where `pid`'s executable lives. One syscall, no
    /// allocation beyond the result string, so it is cheap enough to call for
    /// every process on every scan.
    public static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
