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

/// The sample format the tap's aggregate device is actually running, read back
/// from the HAL rather than assumed. A tap hands over whatever format the mix
/// settled on, and misreading it is silent: the buffers are interpreted as
/// noise (or as nothing at all) instead of audio.
public struct TapAudioFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int
    public var isFloat: Bool
    public var bitsPerChannel: Int
    /// True when each `AudioBuffer` holds one channel rather than interleaved
    /// frames. RMS is identical either way, but it explains the buffer shape in
    /// the diagnostics.
    public var isNonInterleaved: Bool

    public init(
        sampleRate: Double,
        channels: Int,
        isFloat: Bool,
        bitsPerChannel: Int,
        isNonInterleaved: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.isFloat = isFloat
        self.bitsPerChannel = bitsPerChannel
        self.isNonInterleaved = isNonInterleaved
    }

    /// Parse an `AudioStreamBasicDescription`, or nil when the format is one
    /// the meter cannot read (compressed, or a sample size we do not convert).
    public init?(_ asbd: AudioStreamBasicDescription) {
        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInt = flags & kAudioFormatFlagIsSignedInteger != 0
        guard isFloat || isSignedInt, asbd.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }
        // Only 32-bit float and 16-bit signed integer are converted. Anything
        // else is reported as unsupported rather than misread as one of them.
        guard (isFloat && asbd.mBitsPerChannel == 32)
            || (isSignedInt && asbd.mBitsPerChannel == 16)
        else { return nil }
        self.init(
            sampleRate: asbd.mSampleRate,
            channels: max(1, Int(asbd.mChannelsPerFrame)),
            isFloat: isFloat,
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            isNonInterleaved: flags & kAudioFormatFlagIsNonInterleaved != 0
        )
    }

    /// Frames in a buffer of `byteSize` bytes, for the diagnostics line.
    public func frames(perBufferByteSize byteSize: Int) -> Int {
        let bytesPerFrame = max(1, bitsPerChannel / 8 * max(1, isNonInterleaved ? 1 : channels))
        return byteSize / bytesPerFrame
    }
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

    /// RMS straight off the IOProc's buffer list, honouring the real sample
    /// format. Returns nil when there is nothing to measure, which is how a
    /// tap that is running but starved (zero-byte buffers) is told apart from
    /// one that is genuinely silent.
    ///
    /// Squaring and summing is order-independent, so interleaved and
    /// non-interleaved layouts give the same answer and need no unscrambling.
    public static func rms(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        format: TapAudioFormat
    ) -> Float? {
        var sum: Double = 0
        var count = 0
        for buffer in buffers {
            guard let base = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            if format.isFloat {
                let floats = base.assumingMemoryBound(to: Float.self)
                for i in 0..<n {
                    let v = Double(floats[i])
                    sum += v * v
                }
            } else {
                let shorts = base.assumingMemoryBound(to: Int16.self)
                let scale = 1.0 / 32768.0
                for i in 0..<n {
                    let v = Double(shorts[i]) * scale
                    sum += v * v
                }
            }
            count += n
        }
        guard count > 0 else { return nil }
        return Float((sum / Double(count)).squareRoot())
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
    private var _isCapturing = false
    private var _format: TapAudioFormat?
    private var _lastPeak: Float = 0
    private var smoother: TapSmoother
    private var timer: DispatchSourceTimer?

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0

    /// Destroy leftover "Sonar auto-pause" aggregate devices from previous runs.
    ///
    /// Only ever public (non-private) aggregates are touched. The current
    /// aggregate is private, which means it belongs to this process alone and
    /// is reaped by coreaudiod when the process exits, so it can never be a
    /// leftover. Earlier builds created a *published* aggregate, and those do
    /// survive a crash or a force quit and pile up in Audio MIDI Setup.
    ///
    /// Destroying a live device by name is how this used to sabotage itself:
    /// the detector builds its aggregate on its own queue, so a sweep running
    /// concurrently on another thread would match the device that had *just*
    /// been created, tear it out from under a running IOProc, and leave the
    /// tap silently starved with a start that can no longer be stopped.
    public static func purgeStaleAggregates() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr
        else { return }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr
        else { return }

        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(
                id, &nameAddr, 0, nil, &nameSize, &name
            ) == noErr, let value = name?.takeRetainedValue() as String? else {
                continue
            }
            guard value.trimmingCharacters(in: .whitespaces) == aggregateName else { continue }
            guard !isPrivateAggregate(id) else { continue }
            _ = AudioHardwareDestroyAggregateDevice(id)
        }
    }

    /// `private` flag from the aggregate's composition dictionary. There is no
    /// property selector for it, so the composition is the only way to tell a
    /// leftover from a device this process is actively using.
    private static func isPrivateAggregate(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else {
            return false
        }
        var composition: CFDictionary?
        let read = withUnsafeMutablePointer(to: &composition) { pointer in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
        }
        guard read == noErr, let dict = composition as? [String: Any] else { return false }
        switch dict[kAudioAggregateDeviceIsPrivateKey] {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let number as Int: return number != 0
        default: return false
        }
    }

    /// Name used for both the tap and its aggregate device, so the
    /// startup sweep can recognise its own leftovers.
    private static let aggregateName = "Sonar auto-pause"

    private var ioProc: AudioDeviceIOProcID?
    /// How many times the IOProc has actually delivered buffers. A tap can
    /// start cleanly and still deliver nothing, so this is the only honest
    /// proof the capture path works.
    private var ioProcCallbacks: Int = 0
    /// Monotonic timestamp of the most recent buffer. Recorded for *every*
    /// buffer, not just the first: a "have we ever captured" flag that is only
    /// set once decays into a lie the moment the tap starts, and a
    /// once-only timestamp makes the freshness check report "stopped" within a
    /// second while audio is still streaming.
    private var lastBufferNanos: UInt64 = 0
    private let callbackLock = NSLock()
    private var listenersInstalled = false
    private var sleepObservers: [NSObjectProtocol] = []
    private var running = false
    /// `running` is confined to the detector queue; this is the lock-protected
    /// copy other threads (the app host) are allowed to read.
    private let runningLock = NSLock()
    private var _isRunning = false
    private var lastTargets: TapTargets?
    private var lastBuildAt = Date.distantPast
    private var rebuildScheduled = false
    /// True while the HAL teardown of a previous tap is still in flight. A
    /// rebuild must not start before it finishes or the two would race over the
    /// same device ids.
    private var tearingDown = false
    private var rebuildPending = false
    /// Backoff for rebuilding a tap that could not be built, so a user who has
    /// just granted the permission in System Settings gets a working tap
    /// without having to restart Sonar. TCC flips live, but a tap that failed
    /// once stays failed until something asks it to try again.
    private var retryDelay: TimeInterval = 5
    private var retryScheduled = false
    /// Capture-health reporting state (tap-queue confined).
    private var wasCapturing = false
    private var lastHealthReport = Date.distantPast
    /// Serialises the blocking HAL teardown calls off the tap queue.
    private let teardownQueue = DispatchQueue(label: "sonar.tap-detector.teardown")
    /// The IOProc's own queue, and it must never be the queue the detector does
    /// its work on.
    ///
    /// This was the reason the tap never delivered audio even with a
    /// correctly built aggregate: the IOProc block is *dispatched* to this
    /// queue, so while the build sat in `confirmAudioIsFlowing` waiting for
    /// buffers to arrive, the queue was busy running that wait and the buffers
    /// could not be delivered. The confirmation was waiting for the very
    /// callbacks it was preventing, so it could only ever time out and report
    /// "no audio" on a tap that was working perfectly. Verified live on
    /// macOS 27: with a dedicated queue the same build delivers ~90 buffers/s.
    private let ioQueue = DispatchQueue(label: "sonar.tap-detector.io")
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

    /// True while the detector is meant to be running. Callers use this to tell
    /// "apply new settings" apart from "start the capture", because doing both
    /// at once used to build the tap twice and race the stale-device sweep
    /// against the aggregate it had just created.
    public var isRunning: Bool {
        runningLock.lock()
        defer { runningLock.unlock() }
        return _isRunning
    }

    /// Called on an arbitrary queue whenever status changes.
    public var onStatusChange: (@Sendable (TapStatus) -> Void)?

    /// Called on the detector's own queue for one-off build/teardown facts worth
    /// putting in the log (the stream format the HAL settled on, an aggregate
    /// that never came alive). Per-block RMS is deliberately NOT reported here;
    /// the engine reads `latestSignal` for that.
    public var onDiagnostic: (@Sendable (String) -> Void)?

    public init(config: TapConfig = TapConfig()) {
        self.config = config
        self.smoother = TapSmoother(config: config)
        installSystemListeners()
    }

    deinit {
        removeSystemListeners()
        timer?.cancel()
        // Release the HAL objects, but never wait on them: a wedged
        // AudioDeviceStop would otherwise hang the app on quit, and a private
        // aggregate plus a private tap belong to this process, so coreaudiod
        // reaps them at exit regardless.
        let proc = ioProc
        let aggregate = aggregateID
        let tap = tapID
        guard proc != nil || aggregate != 0 || tap != 0 else { return }
        teardownQueue.async {
            Self.releaseHAL(proc: proc, aggregate: aggregate, tap: tap)
        }
    }

    private static func releaseHAL(
        proc: AudioDeviceIOProcID?,
        aggregate: AudioObjectID,
        tap: AudioObjectID
    ) {
        if let proc, aggregate != 0 {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != 0 {
            AudioHardwareDestroyProcessTap(tap)
        }
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

    /// True once the IOProc has delivered a real buffer *recently*.
    ///
    /// This — not the tap merely existing, and not the status being `.active`
    /// — is the only honest proof that the capture path works. A tap can be
    /// created, attached and started and still deliver nothing (that was the
    /// zero-stream aggregate bug), and it can deliver a few buffers and then go
    /// quiet forever (that is what a revoked permission looks like). Sticky
    /// "yes, it captured once" would keep the engine trusting a dead tap, so
    /// the answer decays: no buffer for a second means not capturing.
    public var isCapturing: Bool {
        callbackLock.lock()
        let last = lastBufferNanos
        let anyBuffers = ioProcCallbacks > 0
        callbackLock.unlock()
        guard anyBuffers, last > 0 else { return false }
        let age = Double(DispatchTime.now().uptimeNanoseconds &- last) / 1_000_000_000
        return age < Self.captureFreshness
    }

    /// How long a buffer keeps proving the tap alive. Comfortably longer than
    /// the ~11 ms buffer period, short enough that a tap which goes silent is
    /// reported within a second instead of at the next app restart.
    private static let captureFreshness: TimeInterval = 1.0

    /// The sample format read back from the aggregate's input stream, or nil
    /// when the tap has not been built or the format is unsupported.
    public var format: TapAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return _format
    }

    /// Loudest sample seen since the current tap was built. Unlike RMS this
    /// does not average away short transients, so it is what proves sound is
    /// actually arriving rather than just zeros.
    public var lastPeak: Float {
        lock.lock()
        defer { lock.unlock() }
        return _lastPeak
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.publishRunning()
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
            self.publishRunning()
            self.rebuildScheduled = false
            self.retryScheduled = false
            self.lastTargets = nil
            self.tearDownTap()
        }
        setStatus(.idle)
    }

    private func publishRunning() {
        runningLock.lock()
        _isRunning = running
        runningLock.unlock()
    }

    // MARK: - Tap construction (documented Apple flow)

    /// Rebuild unless debounced away. Process/device notifications only
    /// rebuild when the resolved targets actually changed — our own
    /// aggregate appearing/disappearing fires device notifications that
    /// must not loop.
    private func rebuildIfNeeded(reason: String, force: Bool = false) {
        guard running else { return }
        // Never build on top of a device that is still being torn down: the
        // ids can be recycled by the HAL and the two would interleave.
        if tearingDown {
            rebuildPending = true
            onDiagnostic?("rebuild deferred (\(reason)): teardown in flight")
            return
        }
        let wanted = resolveTapTargets()
        if !force, wanted == lastTargets {
            onDiagnostic?("rebuild skipped (\(reason)): targets unchanged")
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
            retryDelay = 5
        } catch {
            onDiagnostic?("build failed (\(reason)): \(error)")
            setStatus(.unavailable(reason: "\(reason): \(error)"))
            // A failed build has usually already started an async teardown, so
            // ask for the rebuild to be re-run once that teardown lands instead
            // of building on top of a device the HAL is still destroying.
            if tearingDown { rebuildPending = true }
            scheduleRetry()
        }
    }

    /// Retry a tap that could not be built, with backoff. Without this, granting
    /// the permission in System Settings changes nothing until Sonar is
    /// relaunched, because the one build that failed is the only one that ever
    /// runs.
    private func scheduleRetry() {
        guard running, !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 1.5)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            guard self.running else { return }
            if case .unavailable = self.status {
                self.rebuildIfNeeded(reason: "retry after unavailable", force: true)
            }
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
        /// What the exclusions actually resolved to, for the log. A tap that
        /// excludes something it should not goes completely silent rather than
        /// failing, so this has to be visible.
        var excludedSummary: String
    }

    private func resolveTapTargets() -> TapTargets {
        let objectIDs = processObjectIDsByBundle()
        switch config.filter.mode {
        case .allExcept:
            var excluded = Set<AudioObjectID>()
            var notes: [String] = []
            let skip = config.filter.bundleIDs.union(PollRules.excludedBundleIDs)
            for (objectID, bundleID, pid) in objectIDs {
                let rpid = ResponsibleProcess.pid(for: pid)
                let rbundle = NSRunningApplication(processIdentifier: rpid)?.bundleIdentifier ?? bundleID
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
                if pid == getpid() || rpid == getpid() {
                    excluded.insert(objectID)
                    notes.append("self(\(objectID))")
                    continue
                }
                if skip.contains(bundleID) || skip.contains(rbundle) {
                    excluded.insert(objectID)
                    notes.append("\(rbundle.isEmpty ? bundleID : rbundle)(\(objectID))")
                    continue
                }
                if PollRules.excludedNames.contains(name) {
                    excluded.insert(objectID)
                    notes.append("daemon \(name)(\(objectID))")
                    continue
                }
                // A process object with no bundle id and no live app behind it
                // is a leftover from a process that has already exited. Excluding
                // it is pointless and, worse, feeding the HAL a stale object id
                // can silence the whole tap, so leave it out.
                if bundleID.isEmpty, NSRunningApplication(processIdentifier: pid) == nil {
                    notes.append("skip-stale(\(objectID))")
                    continue
                }
            }
            return TapTargets(
                excludedObjectIDs: excluded.sorted(),
                includedObjectIDs: [],
                exclusive: true,
                excludedSummary: notes.joined(separator: ", ")
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
            return TapTargets(
                excludedObjectIDs: [],
                includedObjectIDs: included.sorted(),
                exclusive: false,
                excludedSummary: "watched-only: \(included.count) process(es)"
            )
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
        /// The aggregate came up but has no input stream, so the IOProc would
        /// never be called. Reported separately from a permissions problem
        /// because no amount of toggling System Settings fixes it.
        case noInputStream(streamBits: UInt32)
        case unsupportedFormat(String)
        /// Started, but no buffers ever arrived. Almost always consent: the
        /// grant can be given while Sonar is running, so this has to be
        /// retryable rather than terminal.
        case starved(String)
        case ioProc(OSStatus)
        case start(OSStatus)

        var description: String {
            switch self {
            case .noTargets: return "no matching processes to tap"
            case .create(let st): return "AudioHardwareCreateProcessTap failed (\(st))"
            case .uidMissing: return "tap UID unreadable"
            case .aggregate(let st): return "aggregate creation failed (\(st))"
            case .noInputStream(let bits):
                return "aggregate has no input stream (streams=0x\(String(bits, radix: 16)))"
            case .unsupportedFormat(let detail):
                return "tap stream format not supported (\(detail))"
            case .starved(let detail):
                return "tap started but delivered no buffers (format: \(detail))"
            case .ioProc(let st): return "IO proc creation failed (\(st))"
            case .start(let st): return "device start failed (\(st))"
            }
        }
    }

    /// The format the aggregate's input stream is running, or a precise failure.
    /// This is also the tripwire for the zero-stream aggregate: that bug let the
    /// tap look healthy while delivering nothing, so the check has to happen
    /// before the IOProc is started, not after a silent 3 s wait.
    private func readInputFormat(of aggregate: AudioObjectID) throws -> TapAudioFormat {
        let streams = propertyUInt32(aggregate, kAudioDevicePropertyStreams) ?? 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, &asbd) == noErr else {
            throw TapError.noInputStream(streamBits: streams)
        }
        guard let format = TapAudioFormat(asbd) else {
            throw TapError.unsupportedFormat(
                "id=0x\(String(asbd.mFormatID, radix: 16)) flags=0x\(String(asbd.mFormatFlags, radix: 16)) "
                    + "bits=\(asbd.mBitsPerChannel) ch=\(asbd.mChannelsPerFrame)"
            )
        }
        return format
    }

    private func propertyUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
            ? value : nil
    }

    private func buildTap(targets: TapTargets) throws {
        onDiagnostic?("targets: \(targets.excludedSummary)")
        let description: CATapDescription
        if targets.includedObjectIDs.isEmpty, targets.exclusive {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: targets.excludedObjectIDs)
        } else if !targets.includedObjectIDs.isEmpty {
            description = CATapDescription(stereoMixdownOfProcesses: targets.includedObjectIDs)
        } else {
            throw TapError.noTargets
        }
        description.name = Self.aggregateName
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

        // The aggregate is where a tap becomes readable audio, and both the
        // privacy flag and the tap list have to be supplied at CREATION time.
        //
        // Verified live on macOS 27 (2026-09-28, tap-probe): an aggregate
        // created with only a name and UID reports
        // kAudioDevicePropertyStreams == 0, exposes no input stream, and
        // AudioDeviceStart answers 'nope' (0x6E6F7065) — the tap is then
        // created and "running" while delivering not a single buffer, so
        // loudness detection silently never fires. Creating the aggregate with
        // the tap list present as an array of {uid, drift} sub-tap
        // dictionaries, and marked private, is what gives it a real 48 kHz
        // float32 input stream. That single change is the difference between
        // "tap active" in the log and actually measuring the room.
        //
        // Private also means it never appears in Audio MIDI Setup and is reaped
        // by coreaudiod when the process exits.
        //
        // The UID is per-aggregate, per Apple (their sample uses
        // UUID().uuidString). A fixed UID means a crashed or killed run leaves
        // a stale aggregate registered system-wide and every later
        // AudioHardwareCreateAggregateDevice then fails with 'nope', so the
        // tap would never recover.
        let aggregate: CFDictionary = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: 0]
            ] as CFArray,
        ] as CFDictionary
        var agg = AudioObjectID(0)
        st = AudioHardwareCreateAggregateDevice(aggregate, &agg)
        guard st == noErr else {
            tearDownTap()
            throw TapError.aggregate(st)
        }
        aggregateID = agg

        // Read the format the HAL actually settled on instead of assuming
        // Float32 stereo, and fail loudly (and specifically) when the aggregate
        // has no input stream at all - the failure mode above, which otherwise
        // looks like a permissions problem and sends users to System Settings
        // for a permission they already granted.
        let streamFormat = try readInputFormat(of: agg)
        lock.lock()
        _format = streamFormat
        lock.unlock()
        onDiagnostic?(
            "tap format: \(streamFormat.sampleRate)Hz \(streamFormat.channels)ch "
                + "\(streamFormat.isFloat ? "float" : "int")\(streamFormat.bitsPerChannel)"
                + (streamFormat.isNonInterleaved ? " non-interleaved" : " interleaved")
        )

        var proc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { [weak self] _, inInputData, _, _, _ in
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
        if !waitForAggregateReady(agg) {
            onDiagnostic?("aggregate never reported alive; attempting to start anyway")
        }

        st = startWithRetry(agg, proc)
        guard st == noErr else {
            tearDownTap()
            throw TapError.start(st)
        }
        // Do not report "active" until buffers have actually arrived. A tap
        // that is running but starved is indistinguishable from a working tap
        // if you trust the status alone, and that is exactly the lie the
        // engine used to show in the UI.
        guard confirmAudioIsFlowing() else {
            let detail = format.map(Self.describe) ?? "unknown"
            throw TapError.starved(detail)
        }
        setStatus(.active(rms: 0))
    }

    private static func describe(_ format: TapAudioFormat) -> String {
        "\(format.sampleRate)Hz \(format.channels)ch \(format.isFloat ? "f32" : "i16")"
    }

    /// A tap can start cleanly and still never deliver a buffer. Left alone
    /// that is the worst case: the UI claims loudness detection is on while it
    /// measures nothing, and every decision silently falls back to polling.
    /// So confirm buffers arrive shortly after starting and report it as a
    /// build failure, which tears down, hands detection back to poll, and
    /// schedules a retry for when the user grants the permission.
    @discardableResult
    private func confirmAudioIsFlowing(wait: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if hasSeenBuffers() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        tearDownTap()
        return false
    }

    private func hasSeenBuffers() -> Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return ioProcCallbacks > 0
    }

    /// Poll the aggregate until it reports alive. Bounded so a wedged HAL
    /// cannot stall the engine. The result is advisory: some configurations
    /// start fine without ever setting the flag, so the caller's bounded start
    /// retry has the final say rather than a timeout being treated as fatal.
    private func waitForAggregateReady(
        _ aggregate: AudioObjectID,
        timeout: TimeInterval = 3.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if aggregateIsAlive(aggregate) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
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
        // Take ownership of the object ids and clear our state FIRST, so a
        // wedged HAL call can never be observed or repeated by the rest of the
        // detector, and so a rebuild cannot be handed a half-dead device.
        let proc = ioProc
        let aggregate = aggregateID
        let tap = tapID
        ioProc = nil
        aggregateID = 0
        tapID = 0
        callbackLock.lock()
        ioProcCallbacks = 0
        lastBufferNanos = 0
        callbackLock.unlock()
        lock.lock()
        _isCapturing = false
        _format = nil
        _lastPeak = 0
        lock.unlock()

        guard proc != nil || aggregate != 0 || tap != 0 else { return }

        // The teardown itself runs off the tap queue, and it has to: a tap that
        // never produced buffers leaves AudioDeviceStop wedged inside coreaudiod
        // (observed live, macOS 27), and doing that inline froze the detector
        // permanently - no rebuild, no recovery, ever. Serialised on its own
        // queue and never waited on, so the tap can come back.
        tearingDown = true
        teardownQueue.async { [weak self] in
            Self.releaseHAL(proc: proc, aggregate: aggregate, tap: tap)
            guard let self else { return }
            self.queue.async {
                self.tearingDown = false
                if self.rebuildPending {
                    self.rebuildPending = false
                    self.rebuildIfNeeded(reason: "after teardown")
                }
            }
        }
    }

    // MARK: - Metering

    /// Runs on a realtime thread: only a counter, the RMS, and the peak, then
    /// straight back out. Everything else (smoothing, publishing) hops to the
    /// detector's own queue, because a realtime callback must not take a lock
    /// another thread can hold.
    private func handleAudioBlock(_ inInputData: UnsafePointer<AudioBufferList>) {
        let format = self.format
        callbackLock.lock()
        ioProcCallbacks += 1
        lastBufferNanos = DispatchTime.now().uptimeNanoseconds
        let first = ioProcCallbacks == 1
        callbackLock.unlock()

        // Until the format is known there is nothing meaningful to measure;
        // counting the buffer is still enough to prove capture works.
        guard let format else {
            if first { markCapturing(peak: 0) }
            return
        }
        let measured = TapMeter.rms(
            UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData)),
            format: format
        )
        guard let rms = measured else {
            // Zero-byte buffers mean the device is running but starved. Count
            // it as a callback so the tap is not declared dead, but do not
            // report silence as a measurement.
            if first { markCapturing(peak: 0) }
            return
        }
        if first { markCapturing(peak: rms) }
        queue.async { [weak self] in self?.ingest(rms: rms) }
    }

    private func markCapturing(peak: Float) {
        lock.lock()
        _isCapturing = true
        _lastPeak = max(_lastPeak, peak)
        lock.unlock()
    }

    private func ingest(rms: Float) {
        let active = smoother.sample(rms: rms, at: Date())
        publish(active: active, rms: rms)
    }

    private func publish(active: Bool, rms: Float) {
        lock.lock()
        _latest = AudioSignal(isActive: active, rms: rms)
        _lastPeak = max(_lastPeak, rms)
        // Keep the RMS in the status for diagnostics, but do NOT notify on it.
        // This runs on every audio block (~90/s); notifying here used to
        // re-announce "tap ready" through the engine on every single buffer,
        // which floods the bounded log and wakes the UI 90 times a second.
        if case .active = _status { _status = .active(rms: rms) }
        lock.unlock()
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
            self.reportCaptureHealth()
        }
        t.resume()
        timer = t
    }

    /// Report the transition into and out of "receiving buffers", plus a slow
    /// heartbeat.
    ///
    /// A tap that quietly stops delivering is the failure mode that costs the
    /// user the most: the engine silently falls back to poll, which cannot tell
    /// silence from sound, and nothing on screen says why the resume got late.
    /// This is the only place that can see it happen.
    private func reportCaptureHealth() {
        let capturing = isCapturing
        callbackLock.lock()
        let lastBuffer = lastBufferNanos
        callbackLock.unlock()
        let age: TimeInterval? = lastBuffer > 0
            ? Double(DispatchTime.now().uptimeNanoseconds &- lastBuffer) / 1_000_000_000
            : nil
        lock.lock()
        let peak = _lastPeak
        let rms = _latest.rms ?? 0
        lock.unlock()
        if capturing != wasCapturing {
            wasCapturing = capturing
            onDiagnostic?(
                capturing
                    ? "capturing buffers (rms \(String(format: "%.4f", rms)), peak \(String(format: "%.4f", peak)))"
                    : "stopped receiving buffers (last one \(age.map { String(format: "%.1fs", $0) } ?? "never") ago)"
            )
        }
        let now = Date()
        if now.timeIntervalSince(lastHealthReport) > 30 {
            lastHealthReport = now
            let aggregate = aggregateID
            let alive = aggregate != 0 ? (propertyUInt32(aggregate, kAudioDevicePropertyDeviceIsAlive) ?? 0) : 0
            let running = aggregate != 0
                ? (propertyUInt32(aggregate, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) : 0
            onDiagnostic?(
                "heartbeat: capturing=\(capturing) bufferAge=\(age.map { String(format: "%.1fs", $0) } ?? "-") "
                    + "rms=\(String(format: "%.4f", rms)) peak=\(String(format: "%.4f", peak)) "
                    + "aggregate=\(aggregate) alive=\(alive) running=\(running) "
                    + "proc=\(ioProc == nil ? "nil" : "live") status=\(status)"
            )
        }
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
