// Clean-room implementation from Apple documentation only - no FlowSound code:
// - https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
// - https://developer.apple.com/documentation/coreaudio/catapdescription
// - CoreAudio SDK headers (AudioHardwareTapping.h, CATapDescription.h)
//
// Design: CATapDescription scoped by process object IDs (bundle IDs are
// resolved to object IDs first, because CATapDescription.bundleIDs needs
// macOS 26 and Sonar targets macOS 15) -> AudioHardwareCreateProcessTap ->
// a PRIVATE aggregate device that carries the tap from the moment it is
// created -> an IO proc on the aggregate -> RMS per audio block.
//
// Two things about that are not obvious and were both learned the hard way on
// 2026-09-28 (macOS 27.0, SDK 27.0). Full account in
// docs/HOW-AUTOPAUSE-WORKS.md; the short version:
//
// 1. The tap list must be supplied to AudioHardwareCreateAggregateDevice at
//    CREATION, as an array of {kAudioSubTapUIDKey, kAudioSubTapDriftCompensationKey}
//    dictionaries, and the aggregate must be marked private. An aggregate
//    created with only a name and UID - with the tap attached afterwards via
//    kAudioAggregateDevicePropertyTapList - has kAudioDevicePropertyStreams == 0,
//    exposes no input stream, and AudioDeviceStart answers 'nope' (0x6E6F7065).
//    It looks healthy and never delivers a buffer. Private also keeps it out
//    of Audio MIDI Setup and lets coreaudiod reap it when the process exits.
//
// 2. The IO proc needs its OWN queue. AudioDeviceCreateIOProcIDWithBlock
//    dispatches the callback to the queue it is given, so registering it on
//    the queue that builds the tap deadlocks: the build waits for buffers
//    while blocking the delivery of them, and can only ever time out.
//
// Verified live after the above: ~90 buffers/s, 48 kHz float32 stereo
// interleaved, tracking real loudness (rms 0.03-0.33, peak 0.75 with a browser
// playing audio). If buffers do not arrive the detector reports .unavailable
// with the reason, and the engine falls back to process polling - which cannot
// distinguish silence from sound, and the pane says so.
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
    /// Returns each leftover device it destroyed, so the caller can report it.
    /// Sweeping by name is inherently a little dangerous - it is how the
    /// detector used to destroy its own live aggregate - so a sweep says what
    /// it removed rather than doing it silently.
    /// A leftover aggregate the start-up sweep destroyed, and the result.
    public typealias SweptAggregate = (id: AudioObjectID, status: OSStatus)

    @discardableResult
    public static func purgeStaleAggregates() -> [SweptAggregate] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var swept: [SweptAggregate] = []
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr
        else { return swept }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr
        else { return swept }

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
            let status = AudioHardwareDestroyAggregateDevice(id)
            swept.append((id: id, status: status))
        }
        return swept
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
    /// The device list as last seen by a notification, and the ids in it that
    /// belong to this detector. Both are how a device change is told apart from
    /// the aggregate appearing and disappearing on its own; see
    /// `deviceListChanged()`.
    private var knownDeviceIDs: Set<AudioObjectID> = []
    /// The aggregate currently running plus the one just released. The released
    /// one has to stay in the set for as long as it takes coreaudiod to actually
    /// destroy it, which is on another queue and can be slow.
    private var ownedDeviceIDs: Set<AudioObjectID> = []
    private var lastTargets: TapTargets?
    /// When the tap that is running now was built and still owes us proof that
    /// it carries sound, and the output it is bound to. Opened by every
    /// successful build, closed by `reportCaptureHealth`.
    private var verifyStartedAt: Date?
    private var verifyDeviceUID: String?
    /// A silent verdict has already been logged for this silent stretch, so the
    /// next rebuild does not say it again. Cleared the moment the tap measures
    /// anything.
    private var loggedSilence = false
    /// How long a new tap has to show a non-zero sample before it is called
    /// silent. Long enough to cover a rebuild landing between two songs, and
    /// short enough that a tap reading zeros all day is caught within seconds
    /// of it being built.
    private static let verifyWindow: TimeInterval = 5.0
    /// Below this a tap is delivering zeros, not a quiet room: the loudest thing
    /// any of this measures is 0…1, and a genuine silence reads as exactly 0.
    private static let audibleFloor: Float = 0.0005
    private var lastBuildAt = Date.distantPast
    private var rebuildScheduled = false
    /// True while the HAL teardown of a previous tap is still in flight. A
    /// rebuild must not start before it finishes or the two would race over the
    /// same device ids.
    private var tearingDown = false
    /// When the in-flight teardown started, so a *wedged* one can be given up
    /// on. See `teardownWatchdog`.
    private var teardownStartedAt: Date?
    private var rebuildPending = false
    /// True while a build is in progress, so the engine can tell "the tap is
    /// between builds and knows nothing" apart from "the tap is not available".
    /// The two look identical from outside - `isCapturing` is false either way -
    /// and conflating them is what let poll decide mid-rebuild.
    private var _isRebuilding = false
    /// Backoff for rebuilding a tap that could not be built, so a user who has
    /// just granted the permission in System Settings gets a working tap
    /// without having to restart Sonar. TCC flips live, but a tap that failed
    /// once stays failed until something asks it to try again.
    private var retryDelay: TimeInterval = 5
    private var retryScheduled = false
    /// How many times the *timer* has retried a build. Bounded, because each
    /// attempt is expensive - a full process enumeration, an aggregate, up to 3 s
    /// waiting for it to come alive and up to 2 s waiting for buffers - and
    /// because retrying forever turns a permanently denied permission into a
    /// multi-second blocking cycle every 30 s for as long as Sonar is open.
    ///
    /// Sized so the bound is not something a user can hit by accident: the delay
    /// saturates at 30 s, so this is a bit over an hour of trying. That is far
    /// longer than "opened System Settings, granted it, came back", and the
    /// retries are the *only* thing that ever triggers the system prompt, so
    /// they cannot simply be given up on earlier. Waking and changing the rules
    /// both rebuild regardless, and a successful build resets the count.
    private var retryAttempts = 0
    private static let retryAttemptLimit = 120
    /// Capture-health reporting state (tap-queue confined).
    private var wasCapturing = false
    private var lastHealthReport = Date.distantPast
    /// Deliberately slow: transitions are logged the moment they happen, so
    /// this heartbeat only exists to show a long quiet stretch is healthy.
    private static let healthReportInterval: TimeInterval = 60
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
                self.rebuildIfNeeded(reason: .config)
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

    /// True while a build is in progress.
    ///
    /// `isCapturing` is false for the whole of a rebuild, and so is the status
    /// worth trusting - but the two mean different things to the engine. "Not
    /// capturing" during a rebuild is a gap in what we know; "not capturing"
    /// after a failed build is a fact about the machine, and the engine has to
    /// hand the vote to poll in the second case and hold its hands in the first.
    public var isRebuilding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRebuilding
    }

    private func setRebuilding(_ value: Bool) {
        lock.lock()
        _isRebuilding = value
        lock.unlock()
    }

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
            self.rebuildIfNeeded(reason: .start, force: true)
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

    /// What a notification wants a rebuild for. The reason is part of the
    /// decision, not just the log line: a device change cannot be answered out
    /// of the cached resolution, so it gets its own case rather than being
    /// folded into a `reason:` string.
    enum RebuildReason: String, Sendable, Equatable {
        case start
        case config
        /// A device appeared, disappeared or reconfigured.
        case deviceChange
        /// The set of audio processes changed.
        case processChange
        case wake
        case afterTeardown
        case retry
    }

    /// What a notification resolves to before any HAL work happens. Pure, so
    /// "can this be skipped?" is answerable in a test on a machine with no
    /// audio hardware at all.
    enum RebuildPlan: Equatable {
        /// Nothing to do, carrying the line for the log.
        case skip(reason: String)
        /// Too soon after the last build: coalesce into one scheduled rebuild.
        case debounce
        case build
    }

    /// Decide what a notification does, given what it resolves to.
    ///
    /// The rule that matters: a *device change* is never answered by comparing
    /// against `last`. `last` was resolved against the device that has just gone
    /// away, and a tap left bound to a replaced output delivers buffers full of
    /// zeros - alive, healthy, `isCapturing` true, RMS permanently 0.0000, so it
    /// wins every vote in the engine and Auto-Pause silently never pauses. A
    /// log full of "rebuild skipped (device change): targets unchanged" next to
    /// a live-but-silent tap is not a coincidence, it is the whole bug.
    ///
    /// The comparison is kept for the notifications it is valid for: process
    /// churn, where the same ids really do mean the same thing, and the
    /// aggregate we build ourselves, which is not a device change at all (see
    /// `deviceListChanged()`).
    static func plan(
        reason: RebuildReason,
        last: TapTargets?,
        resolved: TapTargets,
        force: Bool,
        sinceLastBuild: TimeInterval?,
        debounce: TimeInterval
    ) -> RebuildPlan {
        func tooSoon() -> Bool {
            guard let sinceLastBuild, !force else { return false }
            return sinceLastBuild < debounce
        }
        switch reason {
        case .deviceChange:
            return tooSoon() ? .debounce : .build
        case .config, .processChange, .afterTeardown:
            if let last, last == resolved, !force { return .skip(reason: "targets unchanged") }
            return tooSoon() ? .debounce : .build
        case .start, .wake, .retry:
            return tooSoon() ? .debounce : .build
        }
    }

    /// Rebuild unless debounced away. Process notifications only rebuild when
    /// the resolved targets actually changed; a device change always does, and
    /// `plan(reason:...)` says why.
    private func rebuildIfNeeded(reason: RebuildReason, force: Bool = false) {
        guard running else { return }
        // Never build on top of a device that is still being torn down: the
        // ids can be recycled by the HAL and the two would interleave.
        if tearingDown {
            // ...unless the teardown is never going to finish. `tearDownTap`
            // runs its HAL calls on a queue nobody waits on, precisely because
            // `AudioDeviceStop` on a tap that never produced buffers wedges
            // inside coreaudiod (observed live, macOS 27). The price of that
            // decision is that the completion which clears `tearingDown` may
            // never run - and the only thing that consumed `rebuildPending` was
            // that same completion, so a suspend during a wedged stop left the
            // tap dead for the rest of the session with no log line at all.
            // Auto-Pause then silently ran poll-only, which cannot tell silence
            // from sound, so the resume could stop happening entirely.
            //
            // A leaked aggregate is a far smaller problem than a permanently
            // dead detector, and it is private, so coreaudiod reaps it at exit.
            if Date().timeIntervalSince(teardownStartedAt ?? .distantPast)
                > Self.teardownWatchdog
            {
                onDiagnostic?(
                    "teardown still in flight after \(Int(Self.teardownWatchdog))s (\(reason.rawValue)): building anyway"
                )
                tearingDown = false
                teardownStartedAt = nil
            } else {
                rebuildPending = true
                onDiagnostic?("rebuild deferred (\(reason.rawValue)): teardown in flight")
                return
            }
        }
        let wanted = resolveTapTargets()
        let plan = Self.plan(
            reason: reason,
            last: lastTargets,
            resolved: wanted,
            force: force,
            sinceLastBuild: Date().timeIntervalSince(lastBuildAt),
            debounce: rebuildDebounce
        )
        switch plan {
        case .skip(let why):
            onDiagnostic?("rebuild skipped (\(reason.rawValue)): \(why)")
            return
        case .debounce:
            guard !rebuildScheduled else { return }
            rebuildScheduled = true
            let coalesced = reason
            queue.asyncAfter(deadline: .now() + rebuildDebounce) { [weak self] in
                guard let self else { return }
                self.rebuildScheduled = false
                // Forced, and keeping the reason it was coalesced under so the
                // log still says what the build was *for*. Not forced because
                // by the time the delay is up the notification that asked has
                // already been answered, and its "targets unchanged" answer no
                // longer describes anything: waiting for another notification to
                // arrive is how a device change gets dropped entirely.
                self.rebuildIfNeeded(reason: coalesced, force: true)
            }
            return
        case .build:
            break
        }
        lastBuildAt = Date()
        lastTargets = wanted
        // Whatever is running now is about to be replaced, so whatever verified
        // it no longer describes anything. Say so, and let the engine ask for
        // proof again once the new tap starts delivering: a "verified once, at
        // launch" line is exactly what let a tap that went silent on a device
        // change keep its clean bill of health for the rest of the session.
        setStatus(.starting)
        tearDownTap()
        setRebuilding(true)
        defer { setRebuilding(false) }
        do {
            try buildTap(targets: wanted)
            retryDelay = 5
            retryAttempts = 0
        } catch {
            onDiagnostic?("build failed (\(reason.rawValue)): \(error)")
            setStatus(.unavailable(reason: "\(reason.rawValue): \(error)"))
            // A failed build has usually already started an async teardown, so
            // ask for the rebuild to be re-run once that teardown lands instead
            // of building on top of a device the HAL is still destroying.
            if tearingDown { rebuildPending = true }
            scheduleRetry()
        }
    }

    /// How long a teardown may stay in flight before a rebuild stops waiting for
    /// it. Comfortably longer than a teardown that is going to finish - three
    /// HAL calls, none of them blocking on the app - and short enough that a
    /// wedged one costs one build attempt instead of the rest of the session.
    private static let teardownWatchdog: TimeInterval = 5.0

    /// Retry a tap that could not be built, with backoff. Without this, granting
    /// the permission in System Settings changes nothing until Sonar is
    /// relaunched, because the one build that failed is the only one that ever
    /// runs.
    private func scheduleRetry() {
        guard running, !retryScheduled else { return }
        guard retryAttempts < Self.retryAttemptLimit else {
            // Not a permanent decision: waking, a rules change, and a
            // successful build all reset the count, so this only stops an idle
            // app from rebuilding a tap it cannot have.
            onDiagnostic?(
                "tap unavailable; giving up on automatic retries for now "
                    + "(sleep/wake or a rules change will try again)"
            )
            return
        }
        retryAttempts += 1
        retryScheduled = true
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 1.5)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            guard self.running else { return }
            if case .unavailable = self.status {
                self.rebuildIfNeeded(reason: .retry, force: true)
            }
        }
    }

    /// What the tap should capture, resolved from bundle rules to Core Audio
    /// process object IDs (bundleIDs property needs macOS 26; object IDs
    /// work on macOS 15).
    struct TapTargets: Equatable {
        /// Empty object list + exclusive == global tap minus exclusions.
        var excludedObjectIDs: [AudioObjectID]
        /// Non-empty == mixdown of exactly these processes.
        var includedObjectIDs: [AudioObjectID]
        var exclusive: Bool
        /// The output this tap is bound to. Part of the identity on purpose: the
        /// tap's `deviceUID` comes from the *current* default output, so
        /// without this a device change resolved to the same process list, hit
        /// the "targets unchanged" early return, and left the tap measuring an
        /// output that no longer existed. Plugging in AirPods therefore turned
        /// loudness detection off with nothing in the log and nothing on screen.
        var outputDeviceUID: String?
        /// What the exclusions actually resolved to, for the log. A tap that
        /// excludes something it should not goes completely silent rather than
        /// failing, so this has to be visible.
        var excludedSummary: String

        /// Identity is what changes *what the tap captures*, and only that.
        ///
        /// Hand-written rather than synthesized because `excludedSummary` is a
        /// log line, not a target. It was part of the identity until this was
        /// noticed in the field: coreaudiod hands out process object IDs for
        /// processes that no longer exist and then reuses them, so a
        /// `skip-stale(131)` note appeared and vanished every few seconds — and
        /// because that note was in the string, the tap was torn down and
        /// rebuilt from scratch every few seconds, with the engine holding every
        /// decision for the second or two each rebuild took. The object IDs were
        /// identical throughout; only the sentence describing them had changed.
        static func == (lhs: TapTargets, rhs: TapTargets) -> Bool {
            lhs.excludedObjectIDs == rhs.excludedObjectIDs
                && lhs.includedObjectIDs == rhs.includedObjectIDs
                && lhs.exclusive == rhs.exclusive
                && lhs.outputDeviceUID == rhs.outputDeviceUID
        }
    }

    private func resolveTapTargets() -> TapTargets {
        let outputDeviceUID = defaultOutputDeviceUID()
        let objectIDs = processObjectIDsByBundle()
        switch config.filter.mode {
        case .allExcept:
            var excluded = Set<AudioObjectID>()
            var notes: [String] = []
            let skip = config.filter.bundleIDs.union(PollRules.excludedBundleIDs)
            for (objectID, bundleID, pid) in objectIDs {
                let rpid = ResponsibleProcess.pid(for: pid)
                let rbundle = NSRunningApplication(processIdentifier: rpid)?.bundleIdentifier ?? bundleID
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
                if config.filter.ignoresAppleSystemSounds,
                    let path = AppleSystemSounds.executablePath(of: pid),
                    AppleSystemSounds.isSystemSoundPlayer(executablePath: path)
                {
                    excluded.insert(objectID)
                    notes.append("system-sound \((path as NSString).lastPathComponent)(\(objectID))")
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
                outputDeviceUID: outputDeviceUID,
                excludedSummary: notes.joined(separator: ", ")
            )
        case .watchedOnly:
            var included = Set<AudioObjectID>()
            for (objectID, bundleID, pid) in objectIDs {
                let rpid = ResponsibleProcess.pid(for: pid)
                let rbundle = NSRunningApplication(processIdentifier: rpid)?.bundleIdentifier ?? bundleID
                guard config.filter.bundleIDs.contains(bundleID) || config.filter.bundleIDs.contains(rbundle)
                else { continue }
                if config.filter.ignoresAppleSystemSounds,
                    let path = AppleSystemSounds.executablePath(of: pid),
                    AppleSystemSounds.isSystemSoundPlayer(executablePath: path)
                {
                    continue
                }
                included.insert(objectID)
            }
            return TapTargets(
                excludedObjectIDs: [],
                includedObjectIDs: included.sorted(),
                exclusive: false,
                outputDeviceUID: outputDeviceUID,
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
        /// There is no default output to tap. Distinct from everything else,
        /// because unlike a permissions problem it is transient and self-healing:
        /// the next rebuild, which a device notification will trigger, finds the
        /// device the user just plugged in.
        case noOutputDevice
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
            case .noOutputDevice:
                return "no default output device to tap (mute one in System Settings > Sound, or connect an output)"
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
        //
        // Which is exactly why this is a hard error rather than a fallback: a
        // tap with no device UID is the *worst* outcome available, because it
        // comes up healthy. Buffers arrive, so `isCapturing` is true and the
        // engine hands it every decision, and every sample is zero - so the tap
        // wins every vote and reports the room permanently quiet, and Auto-Pause
        // silently does nothing with no error anywhere. Refusing to build turns
        // that into a visible reason, and the next rebuild tries again.
        guard let deviceUID = defaultOutputDeviceUID() else {
            throw TapError.noOutputDevice
        }
        description.deviceUID = deviceUID
        description.stream = 0
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
        // So the notification this very call triggers is recognisable as ours.
        // The tap id goes in too: whether a process tap registers in the device
        // list is not something to bet a rebuild loop on. An id that never
        // turns up is pruned on the next diff.
        ownedDeviceIDs.insert(tapID)
        ownedDeviceIDs.insert(agg)

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
        //
        // Read the format *before* the confirmation: it tears the tap down on
        // failure, which clears the format, so asking afterwards always
        // answered "unknown" on the one error message whose whole job is to
        // name the format it was measuring.
        let measuredFormat = format
        guard confirmAudioIsFlowing() else {
            let detail = measuredFormat.map(Self.describe) ?? "unknown"
            throw TapError.starved(detail)
        }
        setStatus(.active(rms: 0))
        // `confirmAudioIsFlowing` only proves buffers *arrive*. A tap bound to an
        // output that has been swapped out delivers them full of zeros, which
        // passes that check and then never once crosses the threshold - so the
        // verdict that matters is re-established here, on every build, and the
        // measured level goes in the log as the proof. See `reportCaptureHealth`.
        beginVerification(of: deviceUID)
    }

    /// Open the window in which a freshly built tap has to prove it carries
    /// sound, not just buffers. Cleared by the verdict, or by the teardown that
    /// replaced the tap it was about.
    private func beginVerification(of deviceUID: String) {
        verifyStartedAt = Date()
        verifyDeviceUID = deviceUID
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
        // As in AudioDetector: the CoreAudio getter writes untyped bytes, so
        // pass the value's memory instead of casting a CFString to a pointer.
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<CFString>.size) { raw in
                AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, raw)
            }
        }
        guard status == noErr else { return nil }
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
        _format = nil
        _lastPeak = 0
        lock.unlock()
        // The tap that is going away cannot be the one a fresh verification is
        // about, and the new build opens its own.
        verifyStartedAt = nil
        verifyDeviceUID = nil

        guard proc != nil || aggregate != 0 || tap != 0 else { return }

        // The teardown itself runs off the tap queue, and it has to: a tap that
        // never produced buffers leaves AudioDeviceStop wedged inside coreaudiod
        // (observed live, macOS 27), and doing that inline froze the detector
        // permanently - no rebuild, no recovery, ever. Serialised on its own
        // queue and never waited on, so the tap can come back.
        //
        // The id is remembered first: the removal notification is posted from
        // `releaseHAL` below, and if it were not in `ownedDeviceIDs` by then it
        // would read as the user unplugging something.
        if aggregate != 0 { ownedDeviceIDs.insert(aggregate) }
        if tap != 0 { ownedDeviceIDs.insert(tap) }
        tearingDown = true
        teardownStartedAt = Date()
        teardownQueue.async { [weak self] in
            Self.releaseHAL(proc: proc, aggregate: aggregate, tap: tap)
            guard let self else { return }
            self.queue.async {
                self.tearingDown = false
                self.teardownStartedAt = nil
                if self.rebuildPending {
                    self.rebuildPending = false
                    self.rebuildIfNeeded(reason: .afterTeardown)
                }
            }
        }
    }

    // MARK: - Metering

    /// Runs on the IOProc's own queue: a counter, the RMS, and the peak, then
    /// straight back out. Everything else (smoothing, publishing) hops to the
    /// detector's own queue, because that work must not happen here.
    ///
    /// Two locks are still taken per buffer - `callbackLock` and the field
    /// `lock` behind `format` - and every holder of either keeps them for
    /// microseconds, so in practice they never contend. It is still the one
    /// thing here that could glitch the output the tap aggregate is clocking,
    /// if a future change ever grows to hold `lock` across something slow. A
    /// lock-free path (an atomic buffer counter plus a format snapshot taken at
    /// build time) is the real fix and is deliberately not attempted here.
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
        // Deliberately does NOT store a sticky "we are capturing" flag: the
        // public `isCapturing` derives the answer from how recently a buffer
        // arrived, because a flag set once stays true after the tap goes
        // silent - which is how a dead tap keeps winning the engine's vote.
        lock.lock()
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
        if let started = verifyStartedAt, now.timeIntervalSince(started) >= Self.verifyWindow {
            verifyStartedAt = nil
            let output = verifyDeviceUID ?? "unknown output"
            verifyDeviceUID = nil
            if !capturing {
                // Cannot happen through `buildTap` (it waits for buffers), so
                // this is a tap that died after passing its build check. Named
                // here because the engine will quietly hand the vote to poll.
                onDiagnostic?(
                    "tap verification failed: no buffers \(String(format: "%.0fs", now.timeIntervalSince(started))) "
                        + "after a rebuild (output \(output))"
                )
                loggedSilence = false
            } else if peak > Self.audibleFloor {
                // The line the smoke script and the README look for, now
                // repeated once per build with the measured level in it, so
                // "detection is working" is a number in the log rather than a
                // memory carried over from launch.
                loggedSilence = false
                onDiagnostic?(
                    "tap verified: RMS \(String(format: "%.4f", rms)) peak \(String(format: "%.4f", peak)) "
                        + "after this build (output \(output))"
                )
            } else if !loggedSilence {
                // Every sample is zero, which is only a *fault* if something
                // other than Spotify was making sound: Spotify is excluded from
                // the tap on purpose (it is the thing being ducked), so a room
                // where only Spotify is playing correctly measures 0.0000. The
                // line therefore states the measurement and the condition rather
                // than declaring a failure, and it is logged once per silent
                // stretch instead of once per rebuild — the rebuilds are frequent
                // and the bounded log is not.
                loggedSilence = true
                onDiagnostic?(
                    "tap measuring silence: rms \(String(format: "%.4f", rms)) peak \(String(format: "%.4f", peak)) "
                        + "for \(Int(Self.verifyWindow))s after this build (output \(output)) — "
                        + "expected while nothing but Spotify is playing"
                )
            }
        }
        if now.timeIntervalSince(lastHealthReport) > Self.healthReportInterval {
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

    /// A device-list notification, sorted into "the user changed the hardware"
    /// and "coreaudiod is telling us about our own aggregate".
    ///
    /// Building an aggregate adds a device and releasing one removes it, and
    /// both post this notification — so the naive reading of every one of them
    /// as a device change rebuilds the tap forever. The old code avoided that
    /// by comparing resolved targets, which is what made a *real* device change
    /// get skipped: the comparison was against a resolution made for the device
    /// that had just gone away.
    ///
    /// So the two cases are separated by the only thing that actually
    /// distinguishes them, which is *which* device changed. A diff of the device
    /// list that contains nothing but ids this detector created or is about to
    /// destroy is our own bookkeeping; anything else is the user's hardware and
    /// gets a rebuild. No timers, no guessing, no way for a real change to be
    /// mistaken for our own.
    private func deviceListChanged() {
        let current = Self.deviceIDs()
        let changed = current.symmetricDifference(knownDeviceIDs)
        knownDeviceIDs = current
        guard running else {
            ownedDeviceIDs.formIntersection(current)
            return
        }
        let foreign = changed.subtracting(ownedDeviceIDs)
        // Forget ids that no longer exist, so "ours" cannot accumulate forever
        // and eventually swallow a real change.
        ownedDeviceIDs.formIntersection(current)
        guard !changed.isEmpty else { return }
        guard !foreign.isEmpty else {
            onDiagnostic?("device change ignored: our own aggregate only")
            return
        }
        onDiagnostic?(
            "device change: \(foreign.count) device(s) changed, re-resolving targets"
        )
        rebuildIfNeeded(reason: .deviceChange)
    }

    /// Every device the HAL currently knows about.
    private static func deviceIDs() -> Set<AudioObjectID> {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return Set(ids)
    }

    private func installSystemListeners() {
        queue.async { [weak self] in
            guard let self, !self.listenersInstalled else { return }
            self.listenersInstalled = true
            // Seeded before the listener is attached, so the first notification
            // is diffed against reality rather than against an empty set (which
            // would look like every device on the machine just appeared).
            self.knownDeviceIDs = Self.deviceIDs()
            let sys = AudioObjectID(kAudioObjectSystemObject)
            var dev = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(sys, &dev, self.queue) { [weak self] _, _ in
                guard let self else { return }
                self.queue.async { self.deviceListChanged() }
            }
            var procs = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(sys, &procs, self.queue) { [weak self] _, _ in
                guard let self else { return }
                self.queue.async { self.rebuildIfNeeded(reason: .processChange) }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.tearDownTap() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.rebuildIfNeeded(reason: .wake, force: true) }
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
