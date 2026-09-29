// Clean-room implementation from Apple documentation only — no FlowSound code:
// - https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
// - https://developer.apple.com/documentation/coreaudio/catapdescription
// - CoreAudio SDK headers (AudioHardwareTapping.h, CATapDescription.h)
//
// Design (documented flow): CATapDescription scoped by process object IDs
// (bundle IDs resolved to object IDs first, because CATapDescription.bundleIDs
// requires macOS 26 and Sonar targets macOS 15) -> AudioHardwareCreateProcessTap
// -> aggregate device (name + UID) with the tap attached via
// kAudioAggregateDevicePropertyTapList -> IO proc on the aggregate -> RMS per
// audio block. If tap creation/start fails (e.g. Audio Capture not granted),
// the detector reports .unavailable and the engine degrades to poll-only.
//
// Live-test notes (2026-09-28, macOS 26.5 SDK): tap creation, UID readback,
// attach, and IO-proc creation verified working; HAL logs show tap IOContexts
// registering. AudioDeviceStart currently returns 'nope' (bad device) on this
// machine for process-scoped taps until Audio Capture consent is granted; the
// global tap starts. Re-verify live RMS via task-8 diagnostics after granting
// consent (System Settings may prompt on first start from Sonar.app).
// New Sonar code, MIT (c) 2026 Sonar Contributors.

import AppKit
import CoreAudio
import Foundation

/// Tunables for the tap backend. Defaults per TODO task 6.
public struct TapConfig: Sendable, Equatable {
    /// RMS at or above this counts as loud (0...1).
    public var threshold: Float
    /// Sustained loudness needed before the signal goes active.
    public var activeDuration: TimeInterval
    /// Brief dips shorter than this do not reset the active streak.
    public var gapTolerance: TimeInterval
    /// How often quiet is re-checked even when no audio blocks arrive.
    public var quietCheckInterval: TimeInterval
    /// Which bundles the tap listens to.
    public var filter: SourceFilter

    public init(
        threshold: Float = 0.02,
        activeDuration: TimeInterval = 1.0,
        gapTolerance: TimeInterval = 0.75,
        quietCheckInterval: TimeInterval = 0.1,
        filter: SourceFilter = SourceFilter()
    ) {
        self.threshold = threshold
        self.activeDuration = activeDuration
        self.gapTolerance = gapTolerance
        self.quietCheckInterval = quietCheckInterval
        self.filter = filter
    }
}

public enum TapStatus: Sendable, Equatable {
    case idle
    case starting
    case active(rms: Float)
    case unavailable(reason: String)
}

/// Pure loudness math over de-interleaved Float32 samples. Test seam.
public enum TapMeter {
    /// RMS of Float32 mono samples in 0...1 for normalized audio.
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}

/// Pure active/gap state machine. `now` is injected so tests control time.
public struct TapSmoother: Sendable {
    public var config: TapConfig
    private var loudSince: Date?
    private var lastLoud: Date?

    public init(config: TapConfig) {
        self.config = config
    }

    /// Feed one RMS sample. Returns whether the tap signal is active.
    public mutating func sample(rms: Float, at now: Date) -> Bool {
        if rms >= config.threshold {
            lastLoud = now
            if loudSince == nil { loudSince = now }
        } else if let last = lastLoud, now.timeIntervalSince(last) > config.gapTolerance {
            loudSince = nil
        }
        guard let since = loudSince, let last = lastLoud else { return false }
        guard now.timeIntervalSince(last) <= config.gapTolerance else {
            loudSince = nil
            return false
        }
        return now.timeIntervalSince(since) >= config.activeDuration
    }

    /// Re-evaluate without a new sample (quiet-check tick).
    public mutating func reevaluate(at now: Date) -> Bool {
        sample(rms: -1, at: now)
    }
}

/// CoreAudio tap backend: bundle-scoped process tap with RMS loudness.
///
/// Lifecycle: `start()` builds the tap for the current `config.filter` and
/// begins metering; `stop()` tears everything down. The tap rebuilds itself
/// on audio-device changes, process-list changes, sleep/wake, and filter
/// changes. All Core Audio work happens off the main thread on a private
/// serial queue; the real-time IO block only computes RMS and hops to that
/// queue for state updates.
public final class TapDetector: HybridDetector, @unchecked Sendable {
    public let name = "tap"

    private let queue = DispatchQueue(label: "sonar.tap-detector")
    private let lock = NSLock()
    private var _latest = AudioSignal(isActive: false, rms: 0)
    private var _status: TapStatus = .idle
    private var smoother: TapSmoother
    private var timer: DispatchSourceTimer?

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    /// How many times the IOProc has actually delivered buffers. A tap can
    /// start cleanly and still deliver nothing, so this is the only honest
    /// proof the capture path works.
    private var ioProcCallbacks: Int = 0
    private let callbackLock = NSLock()
    private var listenersInstalled = false
    private var sleepObservers: [NSObjectProtocol] = []
    private var running = false
    private var lastTargets: TapTargets?
    private var lastBuildAt = Date.distantPast
    private var rebuildScheduled = false
    /// Minimum time between tap rebuilds; device/process notifications are
    /// chatty (our own aggregate appearing fires one) so rebuilds coalesce.
    private let rebuildDebounce: TimeInterval = 2.0

    public var config: TapConfig {
        didSet {
            queue.async { [weak self] in
                guard let self else { return }
                self.smoother.config = self.config
                // Conditional: rebuilds only when the resolved targets
                // changed, so Save restarts the tap only when rules change.
                self.rebuildIfNeeded(reason: "config")
            }
        }
    }

    /// Called on an arbitrary queue whenever status changes.
    public var onStatusChange: (@Sendable (TapStatus) -> Void)?

    public init(config: TapConfig = TapConfig()) {
        self.config = config
        self.smoother = TapSmoother(config: config)
        installSystemListeners()
    }

    deinit {
        removeSystemListeners()
        tearDownTap()
        timer?.cancel()
    }

    public var latestSignal: AudioSignal? {
        lock.lock()
        defer { lock.unlock() }
        return _latest
    }

    public var status: TapStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    /// Last measured RMS regardless of active state (for diagnostics).
    public var lastRMS: Float {
        lock.lock()
        defer { lock.unlock() }
        return _latest.rms ?? 0
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.setStatus(.starting)
            self.rebuildIfNeeded(reason: "start", force: true)
        }
        startQuietTimer()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.rebuildScheduled = false
            self.lastTargets = nil
            self.tearDownTap()
        }
        setStatus(.idle)
    }

    // MARK: - Tap construction (documented Apple flow)

    /// Rebuild unless debounced away. Process/device notifications only
    /// rebuild when the resolved targets actually changed — our own
    /// aggregate appearing/disappearing fires device notifications that
    /// must not loop.
    private func rebuildIfNeeded(reason: String, force: Bool = false) {
        guard running else { return }
        let wanted = resolveTapTargets()
        if !force, wanted == lastTargets {
            return
        }
        let now = Date()
        if !force, now.timeIntervalSince(lastBuildAt) < rebuildDebounce {
            guard !rebuildScheduled else { return }
            rebuildScheduled = true
            queue.asyncAfter(deadline: .now() + rebuildDebounce) { [weak self] in
                guard let self else { return }
                self.rebuildScheduled = false
                self.rebuildIfNeeded(reason: "debounced \(reason)")
            }
            return
        }
        lastBuildAt = now
        lastTargets = wanted
        tearDownTap()
        do {
            try buildTap(targets: wanted)
        } catch {
            setStatus(.unavailable(reason: "\(reason): \(error)"))
        }
    }

    /// What the tap should capture, resolved from bundle rules to Core Audio
    /// process object IDs (bundleIDs property needs macOS 26; object IDs
    /// work on macOS 15).
    private struct TapTargets: Equatable {
        /// Empty object list + exclusive == global tap minus exclusions.
        var excludedObjectIDs: [AudioObjectID]
        /// Non-empty == mixdown of exactly these processes.
        var includedObjectIDs: [AudioObjectID]
        var exclusive: Bool
    }

    private func resolveTapTargets() -> TapTargets {
        let objectIDs = processObjectIDsByBundle()
        switch config.filter.mode {
        case .allExcept:
            var excluded = Set<AudioObjectID>()
            let skip = config.filter.bundleIDs.union(PollRules.excludedBundleIDs)
            for (objectID, bundleID, pid) in objectIDs {
                let rpid = ResponsibleProcess.pid(for: pid)
                let rbundle = NSRunningApplication(processIdentifier: rpid)?.bundleIdentifier ?? bundleID
                if pid == getpid() || rpid == getpid() { excluded.insert(objectID); continue }
                if skip.contains(bundleID) || skip.contains(rbundle) { excluded.insert(objectID); continue }
                if PollRules.excludedNames.contains(
                    NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
                ) { excluded.insert(objectID); continue }
            }
            return TapTargets(
                excludedObjectIDs: excluded.sorted(),
                includedObjectIDs: [],
                exclusive: true
            )
        case .watchedOnly:
            var included = Set<AudioObjectID>()
            for (objectID, bundleID, pid) in objectIDs {
                let rpid = ResponsibleProcess.pid(for: pid)
                let rbundle = NSRunningApplication(processIdentifier: rpid)?.bundleIdentifier ?? bundleID
                if config.filter.bundleIDs.contains(bundleID) || config.filter.bundleIDs.contains(rbundle) {
                    included.insert(objectID)
                }
            }
            return TapTargets(excludedObjectIDs: [], includedObjectIDs: included.sorted(), exclusive: false)
        }
    }

    /// (objectID, bundleID, pid) for every current audio process object.
    private func processObjectIDsByBundle() -> [(AudioObjectID, String, pid_t)] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bsize = UInt32(MemoryLayout<CFString?>.size)
            var raw: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &bsize, &raw) == noErr else { return nil }
            let bundle = (raw?.takeRetainedValue() as String?) ?? ""
            var pa = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var psize = UInt32(MemoryLayout<pid_t>.size)
            var pid: pid_t = 0
            guard AudioObjectGetPropertyData(id, &pa, 0, nil, &psize, &pid) == noErr else { return nil }
            return (id, bundle, pid)
        }
    }

    private enum TapError: Error, CustomStringConvertible {
        case noTargets
        case create(OSStatus)
        case uidMissing
        case aggregate(OSStatus)
        case attach(OSStatus)
        case ioProc(OSStatus)
        case start(OSStatus)

        var description: String {
            switch self {
            case .noTargets: return "no matching processes to tap"
            case .create(let st): return "AudioHardwareCreateProcessTap failed (\(st))"
            case .uidMissing: return "tap UID unreadable"
            case .aggregate(let st): return "aggregate creation failed (\(st))"
            case .attach(let st): return "tap attach failed (\(st))"
            case .ioProc(let st): return "IO proc creation failed (\(st))"
            case .start(let st): return "device start failed (\(st))"
            }
        }
    }

    private func buildTap(targets: TapTargets) throws {
        let description: CATapDescription
        if targets.includedObjectIDs.isEmpty, targets.exclusive {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: targets.excludedObjectIDs)
        } else if !targets.includedObjectIDs.isEmpty {
            description = CATapDescription(stereoMixdownOfProcesses: targets.includedObjectIDs)
        } else {
            throw TapError.noTargets
        }
        description.name = "Sonar auto-pause"
        description.isPrivate = true
        // Per CATapDescription.h, deviceUID/stream say which output the tap
        // captures and the tap's format matches that stream. Left unset, the
        // tap starts and delivers buffers, but they are silence on this OS.
        // Bind it to the current default output, stream 0.
        if let deviceUID = defaultOutputDeviceUID() {
            description.deviceUID = deviceUID
            description.stream = 0
        }
        // Required: per CATapDescription.h, `exclusive` means "tap all
        // processes except the processes listed". A global-except tap with
        // isExclusive=false refuses AudioDeviceStart ('nope'); verified live.
        description.isExclusive = targets.exclusive

        var tap = AudioObjectID(0)
        var st = AudioHardwareCreateProcessTap(description, &tap)
        guard st == noErr else { throw TapError.create(st) }
        tapID = tap

        guard let uid = tapPropertyUID(tap) else {
            tearDownTap()
            throw TapError.uidMissing
        }

        // Aggregate holds name + UID only (per Apple's sample); the tap is
        // attached afterwards via kAudioAggregateDevicePropertyTapList.
        // The aggregate is deliberately NOT private: a private aggregate
        // refuses AudioDeviceStart ('nope'/bad device, verified live), while
        // Apple's sample flow uses a visible aggregate. The tap itself stays
        // private so only Sonar sees the captured audio.
        //
        // The UID is per-aggregate, per Apple: their sample uses
        // UUID().uuidString. A fixed UID means a crashed or killed run leaves
        // a stale aggregate registered system-wide, and every later
        // AudioHardwareCreateAggregateDevice then fails with 'nope'
        // (0x6E6F7065) - the tap would never recover. A per-pid UID is not
        // enough either, because a rebuild within one run would collide with
        // the aggregate it is replacing.
        let aggregate: CFDictionary = [
            kAudioAggregateDeviceNameKey: "Sonar auto-pause",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
        ] as CFDictionary
        var agg = AudioObjectID(0)
        st = AudioHardwareCreateAggregateDevice(aggregate, &agg)
        guard st == noErr else {
            tearDownTap()
            throw TapError.aggregate(st)
        }
        aggregateID = agg
        do {
            try attachTap(uid: uid, to: agg)
        } catch {
            tearDownTap()
            throw error
        }

        var proc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, inInputData, _, _, _ in
            self?.handleAudioBlock(inInputData)
        }
        guard st == noErr, let proc else {
            tearDownTap()
            throw TapError.ioProc(st)
        }
        ioProc = proc

        // A freshly created aggregate is not immediately startable: until the
        // HAL brings it up, AudioDeviceStart answers 'nope' (0x6E6F7065).
        // Wait for it to report alive, then start with a bounded retry so a
        // slow bring-up cannot look like a hard failure.
        guard waitForAggregateReady(agg) else {
            tearDownTap()
            throw TapError.start(noErr)
        }

        st = startWithRetry(agg, proc)
        guard st == noErr else {
            tearDownTap()
            throw TapError.start(st)
        }
        setStatus(.active(rms: 0))
        confirmAudioIsFlowing()
    }

    /// A tap can come up successfully and still never deliver a buffer - the
    /// aggregate runs, the IOProc exists, and the output is silence. Left
    /// alone that is the worst case: the UI claims loudness detection is on
    /// while it measures nothing. So confirm audio arrives shortly after
    /// starting, and downgrade to unavailable if it does not, which hands
    /// detection back to poll.
    private func confirmAudioIsFlowing(wait: TimeInterval = 3.0) {
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            callbackLock.lock()
            let seen = ioProcCallbacks
            callbackLock.unlock()
            if seen > 0 { return }  // real buffers: the capture path works
            Thread.sleep(forTimeInterval: 0.1)
        }
        callbackLock.lock()
        let seen = ioProcCallbacks
        callbackLock.unlock()
        guard seen == 0 else { return }
        tearDownTap()
        setStatus(
            .unavailable(
                reason: "tap started but delivered no audio (aggregate running, no buffers)"
            ))
    }

    /// Poll the aggregate until it reports alive (or the device list says it
    /// has come up). Bounded so a wedged HAL cannot stall the engine.
    private func waitForAggregateReady(
        _ aggregate: AudioObjectID,
        timeout: TimeInterval = 3.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if aggregateIsAlive(aggregate) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Some HAL configurations never set the flag but are startable; let
        // the caller's retry decide rather than failing outright here.
        return true
    }

    private func aggregateIsAlive(_ aggregate: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, &alive)
            == noErr else { return false }
        return alive != 0
    }

    /// The aggregate can refuse the first start while it finishes coming up,
    /// so retry briefly before reporting failure.
    private func startWithRetry(
        _ aggregate: AudioObjectID,
        _ proc: AudioDeviceIOProcID,
        attempts: Int = 10,
        delay: TimeInterval = 0.1
    ) -> OSStatus {
        var st = AudioDeviceStart(aggregate, proc)
        var tries = 0
        while st != noErr && tries < attempts {
            tries += 1
            Thread.sleep(forTimeInterval: delay)
            st = AudioDeviceStart(aggregate, proc)
        }
        return st
    }


    /// UID of the system default output device, if there is one.
    private func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device
        ) == noErr, device != kAudioObjectUnknown else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(
            device, &uidAddr, 0, nil, &uidSize, &uid
        ) == noErr else { return nil }
        let value = uid as String
        return value.isEmpty ? nil : value
    }

    /// Attach the tap to the aggregate via kAudioAggregateDevicePropertyTapList,
    /// following Apple's "Capturing system audio with Core Audio taps" sample:
    /// read the current list, add this tap's UID if it is missing, write it
    /// back. The list is an array of CFString tap UIDs - not dictionaries.
    private func attachTap(uid: String, to aggregate: AudioObjectID) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &addr, 0, nil, &size) == noErr
        else { throw TapError.attach(noErr) }

        var list: CFArray? = nil
        _ = withUnsafeMutablePointer(to: &list) { ptr in
            AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, ptr)
        }

        var uids: [String] = (list as? [String]) ?? []
        if !uids.contains(uid) { uids.append(uid) }

        var out: CFArray = uids as CFArray
        let st = withUnsafeMutablePointer(to: &out) { ptr in
            AudioObjectSetPropertyData(
                aggregate, &addr, 0, nil,
                UInt32(MemoryLayout<CFArray>.size), ptr
            )
        }
        guard st == noErr else { throw TapError.attach(st) }
    }

    private func tapPropertyUID(_ tap: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var raw: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &raw) == noErr else { return nil }
        return raw?.takeRetainedValue() as String?
    }

    private func tearDownTap() {
        if let proc = ioProc, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProc = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    // MARK: - Metering

    private func handleAudioBlock(_ inInputData: UnsafePointer<AudioBufferList>) {
        callbackLock.lock()
        ioProcCallbacks += 1
        callbackLock.unlock()
        let measured = meter(block: inInputData)
        queue.async { [weak self] in self?.ingest(rms: measured) }
    }

    private func meter(block ioData: UnsafePointer<AudioBufferList>) -> Float {
        var sum: Double = 0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ioData)) {
            guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<n {
                let s = Double(base[i])
                sum += s * s
            }
            count += n
        }
        guard count > 0 else { return 0 }
        return Float((sum / Double(count)).squareRoot())
    }

    private func ingest(rms: Float) {
        let active = smoother.sample(rms: rms, at: Date())
        publish(active: active, rms: rms)
    }

    private func publish(active: Bool, rms: Float) {
        lock.lock()
        _latest = AudioSignal(isActive: active, rms: rms)
        let lastStatus = _status
        lock.unlock()
        // Keep the status at .active(rms:) while the tap runs so diagnostics
        // always show live RMS; a broken tap reports .unavailable instead.
        switch lastStatus {
        case .active, .starting:
            setStatus(.active(rms: rms))
        case .idle, .unavailable:
            break
        }
    }

    private func setStatus(_ status: TapStatus) {
        lock.lock()
        _status = status
        lock.unlock()
        onStatusChange?(status)
    }

    private func startQuietTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + config.quietCheckInterval, repeating: config.quietCheckInterval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let active = self.smoother.reevaluate(at: Date())
            self.lock.lock()
            let last = self._latest
            self.lock.unlock()
            if active != last.isActive {
                self.publish(active: active, rms: last.rms ?? 0)
            }
        }
        t.resume()
        timer = t
    }

    // MARK: - Rebuild triggers

    private func installSystemListeners() {
        queue.async { [weak self] in
            guard let self, !self.listenersInstalled else { return }
            self.listenersInstalled = true
            let sys = AudioObjectID(kAudioObjectSystemObject)
            var dev = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(sys, &dev, self.queue) { [weak self] _, _ in
                self?.queue.async { self?.rebuildIfNeeded(reason: "device change") }
            }
            var procs = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(sys, &procs, self.queue) { [weak self] _, _ in
                self?.queue.async { self?.rebuildIfNeeded(reason: "process change") }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.tearDownTap() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.rebuildIfNeeded(reason: "wake", force: true) }
            },
        ]
    }

    private func removeSystemListeners() {
        for token in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        sleepObservers = []
    }
}
