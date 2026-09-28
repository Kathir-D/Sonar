import Foundation

/// Which apps the poll detector pays attention to.
public enum SourceFilterMode: String, Sendable, CaseIterable {
    /// Every audio source counts, except the ones explicitly excluded.
    case allExcept = "allExcept"
    /// Only the listed bundle IDs count.
    case watchedOnly = "watchedOnly"
}

/// Bundle-ID based source selection. Matching uses the *responsible* bundle
/// ID (so Safari/WebKit helpers count as Safari) with the raw bundle ID as
/// fallback.
public struct SourceFilter: Sendable, Equatable {
    public var mode: SourceFilterMode
    /// Bundle IDs for the mode. Empty = no user rules.
    public var bundleIDs: Set<String>

    public init(mode: SourceFilterMode = .allExcept, bundleIDs: Set<String> = []) {
        self.mode = mode
        self.bundleIDs = bundleIDs
    }

    func allows(_ process: AudioProcess) -> Bool {
        let id = process.responsibleBundleID.isEmpty ? process.bundleID : process.responsibleBundleID
        switch mode {
        case .allExcept:
            return !bundleIDs.contains(id)
        case .watchedOnly:
            return bundleIDs.contains(id)
        }
    }
}

/// Sonar-new glue over the ported SmartPause detector: hard exclusions that
/// always apply, plus the user-configurable `SourceFilter`.
public enum PollRules {
    /// Bundle IDs (own or responsible) that never count as external audio.
    public static let excludedBundleIDs: Set<String> = [
        "com.spotify.client",  // the player itself + its helpers
        "com.KathirD.sonar",  // self, in case Sonar ever emits audio
    ]

    /// Daemon process names (they usually have no bundle ID) that never count.
    public static let excludedNames: Set<String> = [
        "systemsoundserverd",  // UI blips, not media
        "usernoted",  // notification sounds, not media
    ]

    /// True when the process must never be treated as external audio.
    /// Checks both the raw and the responsible pid/bundle so helpers
    /// (Spotify Helper, WebKit.GPU, ...) resolve to their parent.
    public static func isExcluded(_ process: AudioProcess, selfPID: pid_t) -> Bool {
        if process.pid == selfPID || process.responsiblePID == selfPID { return true }
        if excludedBundleIDs.contains(process.bundleID) { return true }
        if excludedBundleIDs.contains(process.responsibleBundleID) { return true }
        if excludedNames.contains(process.name) { return true }
        return false
    }

    /// Pure, hardware-independent filtering: exclusions first, then the
    /// user filter. This is what the unit tests exercise.
    public static func filtered(
        _ processes: [AudioProcess],
        selfPID: pid_t,
        filter: SourceFilter
    ) -> [AudioProcess] {
        processes.filter { !isExcluded($0, selfPID: selfPID) && filter.allows($0) }
    }
}

/// No-permission poll backend: `IsRunningOutput` scan on demand (~14 ms),
/// 0 idle CPU. Wraps the ported `AudioDetector` with Sonar's exclusion and
/// filter rules and exposes the `HybridDetector` interface.
public final class PollDetector: HybridDetector, @unchecked Sendable {
    public let name = "poll"

    private let lock = NSLock()
    private var _latest: AudioSignal?
    private let tracker = AudioActivityTracker()

    /// User source-selection rules (task 8 prefs).
    public var filter = SourceFilter()
    /// Own pid, for the self-exclusion. Injectable for tests.
    public var selfPID: pid_t = getpid()

    public init() {}

    public var latestSignal: AudioSignal? {
        lock.lock()
        defer { lock.unlock() }
        return _latest
    }

    public func start() {
        tracker.start()
    }

    public func stop() {
        // Nothing to release: scans are on-demand, the tracker only holds
        // Core Audio listeners for start-time bookkeeping.
    }

    /// Currently audible external sources after exclusions + user filter.
    public func activeSources() -> [AudioProcess] {
        let found = AudioDetector.runningOutputProcesses()
        tracker.observe(playing: Set(found.map(\.pid)))
        return PollRules.filtered(found, selfPID: selfPID, filter: filter)
    }

    /// One poll tick. Returns the signal and publishes it as `latestSignal`.
    @discardableResult
    public func refresh() -> AudioSignal {
        let sources = activeSources()
        let signal = AudioSignal(isActive: !sources.isEmpty, rms: nil)
        lock.lock()
        _latest = signal
        lock.unlock()
        return signal
    }
}
