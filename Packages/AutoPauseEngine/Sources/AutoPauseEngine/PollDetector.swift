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
public final class PollDetector: RefreshingDetector, @unchecked Sendable {
    public let name = "poll"

    private let lock = NSLock()
    private var _latest: AudioSignal?
    private let tracker = AudioActivityTracker()

    /// User source-selection rules (task 8 prefs).
    public var filter = SourceFilter()
    /// Own pid, for the self-exclusion. Injectable for tests.
    public var selfPID: pid_t = getpid()

    /// CoreAudio's process scan is not cheap and is not reliably fast: it
    /// reads several properties per process and resolves names through
    /// NSRunningApplication, and a browser with many helpers makes it slow
    /// enough to take seconds. Running that on the engine's tick starved
    /// fusion entirely - the engine spent 100% of its time inside the scan
    /// and never evaluated a decision, so auto-pause did nothing. So the scan
    /// runs on its own queue, at most one in flight, and the tick reads the
    /// last result instead of blocking on a fresh one.
    private let scanQueue = DispatchQueue(
        label: "sonar.poll-scan",
        qos: .utility
    )
    /// Minimum spacing between scans. Activity detection does not need the
    /// engine's full 10 Hz.
    public var minScanInterval: TimeInterval = 0.25
    private let scanLock = NSLock()
    private var lastScanAt: Date?
    private var scanInFlight = false

    public init() {}

    public var latestSignal: AudioSignal? {
        lock.lock()
        defer { lock.unlock() }
        return _latest
    }

    public func start() {
        tracker.start()
        // Seed through `refresh()`, so the first scan lands on the scan queue.
        //
        // It used to run synchronously here, and `start()` is called by
        // `AutoPauseController.start()` - which the app calls on the main thread
        // at launch, before it has finished launching. The scan this comment
        // above already warns can take *seconds* with a browser's worth of audio
        // helpers, so the synchronous seed was a multi-second frozen menu bar
        // on the user's first launch after login.
        //
        // The seed exists so the first tick does not read a false "all quiet",
        // and losing it costs at most one tick: fusion sees quiet, which resolves
        // to `restore()`, and the adapter ignores a restore it never earned
        // because nothing was ducked yet.
        refresh()
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

    /// One poll tick. Returns the most recent signal and schedules a refresh
    /// when one is due. Never blocks the caller on CoreAudio.
    @discardableResult
    public func refresh() -> AudioSignal {
        let now = Date()
        let due: Bool = scanLock.withLock {
            if scanInFlight { return false }
            if let last = lastScanAt, now.timeIntervalSince(last) < minScanInterval {
                return false
            }
            scanInFlight = true
            lastScanAt = now
            return true
        }
        if due {
            scanQueue.async { [weak self] in
                autoreleasepool {
                    guard let self else { return }
                    defer { self.scanLock.withLock { self.scanInFlight = false } }
                    self.performScan()
                }
            }
        }
        return latestSignal ?? AudioSignal(isActive: false, rms: nil)
    }

    private func performScan() {
        let sources = activeSources()
        let signal = AudioSignal(isActive: !sources.isEmpty, rms: nil)
        lock.lock()
        _latest = signal
        lock.unlock()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
