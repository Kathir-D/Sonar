import AutoPauseEngine
import Combine
import Foundation

/// Audio sources heard in the last 3 minutes (bundle ID -> name/last seen).
/// Powers the "recent sources" finder in the Auto-Pause pane.
final class RecentSourcesModel: ObservableObject {
    struct Entry: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let lastSeen: Date
    }

    /// Window for "recent".
    var window: TimeInterval = 180

    @Published private(set) var entries: [Entry] = []

    private var seen: [String: (name: String, at: Date)] = [:]
    private var timer: Timer?

    func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let now = Date()
        for proc in AudioDetector.runningOutputProcesses() {
            let id = proc.responsibleBundleID.isEmpty ? proc.bundleID : proc.responsibleBundleID
            guard !id.isEmpty else { continue }
            seen[id] = (proc.name, now)
        }
        for id in seen.keys where now.timeIntervalSince(seen[id]!.at) > window {
            seen[id] = nil
        }
        entries = seen
            .map { Entry(bundleID: $0.key, name: $0.value.name, lastSeen: $0.value.at) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }
}
