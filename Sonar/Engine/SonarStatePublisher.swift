import AutoPauseEngine
import Darwin
import Foundation

/// Publishes the engine's duck phase to
/// `~/Library/Application Support/Sonar/state.json` for companion tools such
/// as trak. One-way and best effort: nothing in Sonar ever reads the file
/// back, and a write that fails is logged and forgotten.
///
/// Format, version 1:
///
///     {"v":1,"state":"idle|ducking|ducked|resuming","pid":<Spotify pid or null>,"since":<unix seconds>}
///
/// Written atomically - a temp file in the same directory, then `rename(2)` -
/// so a reader never sees half a file.
final class SonarStatePublisher: @unchecked Sendable {
    static let shared = SonarStatePublisher()

    private static let formatVersion = 1
    private let queue = DispatchQueue(label: "sonar.state-publisher")
    private var lastWritten: (phase: AdapterPhase, pid: pid_t?)?
    /// Off while Auto-Pause is switched off, and for good once Sonar is
    /// quitting: the file then says `idle` and nothing else is written over it.
    private var enabled = true

    /// The real home directory, not the sandbox container `NSHomeDirectory()`
    /// resolves to: a companion tool has to be able to find the file at the
    /// documented path. The entitlements carry the matching home-relative
    /// exception for this one directory.
    static var stateURL: URL {
        let home: String
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Sonar", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    /// Record a phase change. Repeats of the phase already on disk are
    /// dropped, so `since` stays the moment the phase actually began.
    func publish(_ phase: AdapterPhase, pid: pid_t?) {
        let since = Int(Date().timeIntervalSince1970)
        let pid = phase == .idle ? nil : pid
        queue.async { [self] in
            guard enabled || phase == .idle else { return }
            if let last = lastWritten, last.phase == phase, last.pid == pid { return }
            if write(phase: phase, pid: pid, since: since) {
                lastWritten = (phase, pid)
            }
        }
    }

    /// Follow the Auto-Pause switch. Switching off publishes `idle` at once and
    /// holds it there; switching on publishes whatever the engine is doing.
    func setEnabled(_ isEnabled: Bool, current phase: AdapterPhase, pid: pid_t?) {
        queue.async { [self] in enabled = isEnabled }
        publish(isEnabled ? phase : .idle, pid: pid)
    }

    /// Publish `idle` and wait for it to land. Used on quit, where an async
    /// write would be abandoned with the process.
    func publishIdleAtQuit() {
        queue.sync { enabled = false }
        publish(.idle, pid: nil)
        queue.sync {}
    }

    private func write(phase: AdapterPhase, pid: pid_t?, since: Int) -> Bool {
        let url = Self.stateURL
        let dir = url.deletingLastPathComponent()
        let pidJSON = pid.map(String.init) ?? "null"
        let json = "{\"v\":\(Self.formatVersion),\"state\":\"\(phase.rawValue)\",\"pid\":\(pidJSON),\"since\":\(since)}\n"
        let temp = dir.appendingPathComponent(".state.json.\(getpid()).tmp")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: temp)
            guard rename(temp.path, url.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: temp)
                SonarLog.write("state.json: rename failed: \(reason)")
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            SonarLog.write("state.json: write failed: \(error.localizedDescription)")
            return false
        }
    }
}
