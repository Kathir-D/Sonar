// Ported from https://github.com/yasinozmeen/smartpause @ 69f3a9db31919b1e2ba4d1c6ba6f41564d6ed9b7
// (MIT 2026 Yasin Özmen). Tracking logic is verbatim; comments translated to
// English; types made public. One adaptation: SmartPause's internal `Log`
// is not vendored, so log lines route through `logHandler` (default silent).
// Full license text: THIRD-PARTY-NOTICES.md.

import AppKit
import CoreAudio
import Foundation

/// Tracks WHEN each process started producing audio, event-driven.
/// No polling: Core Audio notifies when the process list or a process's
/// output state changes. Purpose: in dual-source mode the most recently
/// started source is a tie-breaker candidate after the frontmost app.
/// Measured (SmartPause spike D, 2026-09-10): no notification arrives for
/// `kAudioProcessPropertyIsRunningOutput`; `kAudioProcessPropertyIsRunning`
/// does notify but fires rarely since apps usually keep the stream open when
/// paused. So this is an approximate signal: notifications are combined with
/// the snapshot seen on every poll tick. Still no polling of its own.
public final class AudioActivityTracker: @unchecked Sendable {
    public static let shared = AudioActivityTracker()

    private var startedAt: [pid_t: Date] = [:]
    private var watched: Set<AudioObjectID> = []
    private let queue = DispatchQueue(label: "sonar.audio-tracker")
    private let lock = NSLock()
    public var onActivityChange: (@Sendable (_ pid: pid_t, _ isRunning: Bool) -> Void)?
    /// Receives internal log lines. Nil (default) means silent.
    public var logHandler: (@Sendable (String) -> Void)?

    public init() {}

    private func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: sel,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func log(_ line: String) {
        logHandler?(line)
    }

    public func start() {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue) { [weak self] _, _ in
            self?.syncProcessList()
        }
        queue.async { self.syncProcessList() }
    }

    public func startTime(pid: pid_t) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return startedAt[pid]
    }

    /// Merge with the snapshot seen on a poll tick: newly seen players are
    /// recorded, entries that stopped playing are dropped.
    public func observe(playing pids: Set<pid_t>) {
        lock.lock()
        defer { lock.unlock() }
        for pid in pids where startedAt[pid] == nil { startedAt[pid] = Date() }
        for pid in startedAt.keys where !pids.contains(pid) { startedAt[pid] = nil }
    }

    private func syncProcessList() {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return }
        log("[tracker] process list: \(ids.count) objects, watching \(watched.count)")
        for id in ids where !watched.contains(id) {
            watched.insert(id)
            var ra = addr(kAudioProcessPropertyIsRunning)  // 'piro' produces no notifications, 'pir?' does
            let st = AudioObjectAddPropertyListenerBlock(id, &ra, queue) { [weak self] _, _ in self?.update(id) }
            if st != noErr { log("[tracker] listener failed id=\(id) error=\(st)") }
            update(id)
        }
    }

    private func update(_ id: AudioObjectID) {
        var pa = addr(kAudioProcessPropertyPID)
        var ps = UInt32(MemoryLayout<Int32>.size)
        var pid: Int32 = 0
        guard AudioObjectGetPropertyData(id, &pa, 0, nil, &ps, &pid) == noErr else { return }
        var ra = addr(kAudioProcessPropertyIsRunningOutput)
        var rs = UInt32(MemoryLayout<UInt32>.size)
        var running: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &ra, 0, nil, &rs, &running) == noErr else { return }
        var notify: (pid: pid_t, running: Bool)?
        lock.lock()
        if running != 0 {
            if startedAt[pid] == nil {
                startedAt[pid] = Date()
                log("[tracker] pid \(pid) audio started")
                notify = (pid, true)
            }
        } else {
            if startedAt[pid] != nil {
                log("[tracker] pid \(pid) audio stopped")
                notify = (pid, false)
            }
            startedAt[pid] = nil
        }
        lock.unlock()
        if let notify {
            onActivityChange?(notify.pid, notify.running)
        }
    }
}

/// User-intent signal: when each app was last brought to front.
/// NSWorkspace notification, no polling.
public final class ActivationTracker: @unchecked Sendable {
    public static let shared = ActivationTracker()
    private var lastActivated: [pid_t: Date] = [:]
    private var token: NSObjectProtocol?

    public init() {}

    public func start() {
        if let f = NSWorkspace.shared.frontmostApplication { lastActivated[f.processIdentifier] = Date() }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.lastActivated[app.processIdentifier] = Date()
            }
        }
    }

    public func lastActivation(pid: pid_t) -> Date? { lastActivated[pid] }
}
