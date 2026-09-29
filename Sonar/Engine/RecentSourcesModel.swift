import AppKit
import AutoPauseEngine
import Combine
import Foundation

/// Bundle ID to the name and icon a person would recognise.
///
/// The pane used to print raw bundle IDs, which is developer plumbing: nobody
/// can act on `com.apple.Safari`, everybody can act on Safari's icon. Lives
/// here because this is the only file in the sources list's own code path.
final class SourceAppIdentity: @unchecked Sendable {
    static let shared = SourceAppIdentity()

    private struct Info {
        let name: String
        let url: URL?
    }

    private let lock = NSLock()
    private var cache: [String: Info] = [:]

    private init() {}

    /// Display name for a bundle ID, falling back to the running app and then
    /// to the ID itself for anything not installed here.
    func name(for bundleID: String) -> String {
        info(for: bundleID).name
    }

    func icon(for bundleID: String) -> NSImage {
        if let url = info(for: bundleID).url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// False for a rule that names an app this Mac does not have, which is the
    /// one case where the raw ID is the honest label.
    func isInstalled(_ bundleID: String) -> Bool {
        info(for: bundleID).url != nil
    }

    private func info(for bundleID: String) -> Info {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[bundleID] { return hit }

        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.flatMap { bundle in
            (Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleDisplayName")
                as? String)
                ?? (Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?
                .localizedName
            ?? bundleID
        let value = Info(name: name, url: url)
        cache[bundleID] = value
        return value
    }
}

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
        // Only apps that can actually pause Spotify belong in a list whose
        // rows promise what they will do. Spotify, Sonar and system blips are
        // filtered out by the engine, so showing them here would put a "Will
        // pause" verdict on an app that never can.
        let found = PollRules.filtered(
            AudioDetector.runningOutputProcesses(),
            selfPID: getpid(),
            filter: SourceFilter(mode: .allExcept, bundleIDs: [])
        )
        for proc in found {
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
