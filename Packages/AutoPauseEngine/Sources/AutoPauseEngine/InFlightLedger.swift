// New Sonar code, MIT (c) 2026 Sonar Contributors.

import Foundation

/// A set of operations that are outstanding right now, each with a deadline.
///
/// The whole point of this type is that an entry cannot be left behind. Two
/// system calls in Auto-Pause block on something outside the app — the
/// `CGPreflightScreenCaptureAccess` family and, much worse,
/// `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)`, which waits
/// on a system dialog nobody in this process controls. A flag that records
/// "a request is in flight" is therefore not self-clearing: if the dialog is
/// dismissed without a reply, or the process is killed while it is up, the flag
/// outlives the thing it describes and the UI sits on a spinner forever with no
/// way forward.
///
/// A deadline fixes that without making every caller remember a `DispatchQueue`
/// hop: `expire(at:)` is a pure function of the clock, so the only two ways out
/// are "the work came back" (`finish`) and "enough time passed" (`expire`).
/// A caller that schedules `expire` on a timer and forgets everything else
/// still cannot strand an entry, and the rule is testable without a Mac full of
/// permission dialogs.
///
/// Value-typed and key-generic on purpose: the app owns the keys
/// (`SonarPermission`), and nothing here needs to know what they mean.
public struct InFlightLedger<Key: Hashable & Sendable>: Sendable {
    /// One outstanding operation, with the moment it started and the moment it
    /// stops being believable.
    public struct Entry: Equatable, Sendable {
        public let key: Key
        public let startedAt: Date
        public let deadline: Date

        public func isExpired(at now: Date) -> Bool { now >= deadline }
        public func age(at now: Date) -> TimeInterval { now.timeIntervalSince(startedAt) }
    }

    private var entries: [Key: Entry] = [:]

    public init() {}

    /// The keys currently outstanding. This is what a UI shows as "waiting".
    public var keys: Set<Key> { Set(entries.keys) }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public func contains(_ key: Key) -> Bool { entries[key] != nil }
    public func entry(for key: Key) -> Entry? { entries[key] }
    public func startedAt(_ key: Key) -> Date? { entries[key]?.startedAt }

    /// True once the entry has outlived its deadline. An expired entry is
    /// still "in flight" until `expire` runs — reporting it early would let a
    /// caller re-issue work that is still occupying a thread, and reporting it
    /// late is the bug this type exists to prevent.
    public func isExpired(_ key: Key, at now: Date) -> Bool {
        entries[key]?.isExpired(at: now) ?? false
    }

    /// The entry every expired key should give up at, so a caller can schedule
    /// the expiry itself with a `Timer` instead of polling.
    public func deadline(for key: Key) -> Date? { entries[key]?.deadline }

    /// Record an operation as outstanding.
    ///
    /// Re-beginning a key that is already in flight restarts its clock rather
    /// than making two entries: a second request for a permission the OS is
    /// already asking about is the same request, and two deadlines for one
    /// dialog is how the shorter one strands the longer.
    @discardableResult
    public mutating func begin(
        _ key: Key,
        at now: Date,
        timeout: TimeInterval
    ) -> Entry {
        let entry = Entry(key: key, startedAt: now, deadline: now.addingTimeInterval(timeout))
        entries[key] = entry
        return entry
    }

    /// The work came back. Returns whether there was anything to clear.
    @discardableResult
    public mutating func finish(_ key: Key) -> Bool {
        entries.removeValue(forKey: key) != nil
    }

    /// Give up on everything past its deadline. Returns the keys given up, in no
    /// particular order, so the caller can log them and fix up whatever it
    /// published from them.
    @discardableResult
    public mutating func expire(at now: Date) -> [Key] {
        let expired = entries.values.filter { $0.isExpired(at: now) }.map(\.key)
        for key in expired { entries.removeValue(forKey: key) }
        return expired
    }

    /// Give up on one key, deadline or not. Used when something *outside* the
    /// clock says the wait is over — the user came back to the app, so whatever
    /// dialog was up is gone and re-reading the truth beats waiting.
    @discardableResult
    public mutating func expire(_ key: Key) -> Bool {
        entries.removeValue(forKey: key) != nil
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

/// How long each kind of permission wait is allowed to last.
///
/// These are the numbers the app and the tests share, so a test cannot pass
/// against a timeout the app does not actually use.
///
/// **The caller has to be able to *arrive* at the deadline, though, and on macOS
/// that is not automatic.** A `Timer` is scheduled onto the current thread's
/// run loop; a `Timer` created from a background thread — which is exactly when
/// a probe discovers it needs a deadline — lands on no run loop and never fires.
/// Both `Timer(timeInterval:)` and `Timer.scheduledTimer(withTimeInterval:)`
/// were measured doing nothing in that position, while
/// `DispatchQueue.main.asyncAfter` fired every time. So the scheduling is done
/// with main-queue work items, and these timeouts only mean something because
/// something on the main queue is watching for them.
public enum InFlightTimeout {
    /// A permission *read*. These are documented not to prompt and answer in
    /// microseconds, so a few seconds of silence means the call is wedged, not
    /// busy — and the recovery has to start a second read rather than trust the
    /// first one to come back.
    public static let probe: TimeInterval = 3

    /// A grant *request*, which blocks on a system dialog. Generous on purpose:
    /// the person being asked has to read a dialog and decide, and cutting that
    /// short would show them a row that has given up while they are still
    /// answering. It only has to be short enough that a dialog nobody ever
    /// answers does not outlive the app's patience.
    public static let grantRequest: TimeInterval = 60

    /// How long a read that has already been given up on stays un-retried.
    ///
    /// A read is retried when the user comes back to the app, not when a timer
    /// fires. A permission check that has been observed never returning does not
    /// start returning because a second went by, and retrying it on a poll is
    /// how one wedged call becomes an unbounded pile of them: measured at 14
    /// calls started and 0 finished in 14 seconds, every one of them holding a
    /// thread. This is the floor for the paths that have no activation event to
    /// ride on.
    public static let wedgedReadRetry: TimeInterval = 60
}
