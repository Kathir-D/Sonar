import Foundation

/// Bounded file log for Auto-Pause diagnostics: `~/Library/Logs/Sonar/sonar.log`.
/// Caps the file at 256 KB by dropping the oldest half on overflow.
enum SonarLog {
    private static let fileName = "sonar.log"
    private static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "sonar.log")

    /// Container-aware: under the app sandbox this resolves inside
    /// `~/Library/Containers/com.KathirD.sonar/Data/Library/Logs/Sonar/`
    /// (visible in Console.app); unsandboxed it is `~/Library/Logs/Sonar/`.
    /// A literal `~/Library/Logs` path is not writable when sandboxed.
    static var logURL: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib
            .appendingPathComponent("Logs/Sonar", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func write(_ line: String) {
        queue.async {
            let url = logURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
            guard let data = stamped.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                boundIfNeeded(url: url)
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    // `close()` reports success, which the log has no use for.
                    _ = try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func boundIfNeeded(url: URL) {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int, size > maxBytes,
            let data = try? Data(contentsOf: url)
        else { return }
        let kept = data.suffix(maxBytes / 2)
        try? kept.write(to: url)
    }
}
