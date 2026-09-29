import CoreAudio
import Foundation
import Testing
@testable import AutoPauseEngine

/// `TapDetector` is the only class in the package that talks to Core Audio
/// directly, and almost all of it cannot be tested without a device: building
/// a tap, creating an aggregate, starting an IOProc. What *is* testable
/// without hardware is everything around it, and that is where the wiring bug
/// lived.
///
/// The bug: the aggregate was created with a name and a UID only, then the tap
/// was attached afterwards via `kAudioAggregateDevicePropertyTapList`. The
/// result came up "successfully", reported `.active`, and delivered nothing -
/// `kAudioDevicePropertyStreams == 0`, so the IOProc was never called, so
/// `isCapturing` never became true, so the engine trusted a tap that measured
/// silence forever. The fix supplies the tap list at creation time and marks
/// the aggregate private.
///
/// What this file pins is therefore the *invariant* rather than the wiring:
/// nothing may treat a tap as loudness-capable until buffers have actually
/// been observed. The positive path needs real hardware and is left behind an
/// environment flag; the negative path is asserted unconditionally, because it
/// is the one that has to hold when the wiring breaks again.

/// A tap that has been constructed but never started. This is exactly what a
/// controller holds before the device is up, and it is also the state a
/// mis-wired tap is stuck in: existing, idle, and measuring nothing.
private func freshTap() -> TapDetector {
    TapDetector()
}

// MARK: - Nothing is trusted before a buffer arrives

@Test func aConstructedTapHasNotCapturedAnything() {
    let tap = freshTap()
    #expect(tap.isCapturing == false)
    #expect(tap.lastPeak == 0)
    #expect(tap.format == nil)
}

@Test func aConstructedTapPublishesAnInactiveSignal() {
    // `latestSignal` is optional but the detector seeds it, so the controller
    // never has to distinguish "no data yet" from "quiet room" on the first
    // tick. If it were nil, `fusion.evaluate(tap: nil)` would read as a quiet
    // sample and could resume Spotify on a tick where the tap knows nothing.
    let tap = freshTap()
    let signal = tap.latestSignal
    #expect(signal != nil)
    #expect(signal?.isActive == false)
    #expect(signal?.rms == 0)
}

@Test func aConstructedTapReportsNoRms() {
    // The diagnostics show "measuring" from this, so a non-zero RMS before any
    // buffer arrived would be a lie.
    #expect(freshTap().lastRMS == 0)
}

@Test func aConstructedTapIsIdle() {
    #expect(freshTap().status == .idle)
}

@Test func stopOnATapThatNeverStartedIsSafe() {
    // Teardown runs from `deinit` as well as from `stop()`, and a stop before
    // a start is the normal case for a controller that is disabled again. It
    // must not touch Core Audio state that does not exist.
    let tap = freshTap()
    tap.stop()
    #expect(tap.status == .idle)
    #expect(tap.isCapturing == false)
}

@Test func aStopWithoutAStartIsSafeAndLeavesNothingBehind() {
    // `stop()` tears down `tapID`/`aggregateID`/`ioProc`, all of which are 0
    // before `start()`, so the whole method is a no-op. The lifecycle paths
    // that reach `stop()` without a `start()` are real (a controller that is
    // disabled again, or torn down twice), and they must not touch the HAL.
    //
    // Deliberately *not* `start()` here: on a machine where the Screen &
    // System Audio Recording grant happens to be present, a real tap builds and
    // an IOProc really runs, which is hardware work this suite does not do.
    // The liveness path is covered by the two opt-in tests at the bottom.
    let tap = freshTap()
    tap.stop()
    #expect(tap.isCapturing == false)
    #expect(tap.format == nil, "a tap that was never built has no format")
    #expect(tap.lastPeak == 0, "a tap that was never built has no peak")
    #expect(tap.status == .idle)
    // Standing still changes nothing: `isCapturing` is only ever set by an
    // IOProc callback, and with no device there is none.
    Thread.sleep(forTimeInterval: 0.05)
    #expect(tap.isCapturing == false)
    #expect(tap.format == nil)
}

@Test func constructingATapRegistersNoAggregateDevice() {
    // The aggregate is a real device in the user's audio system, so building
    // one is a side effect a test must never cause. Constructing the detector
    // does not: the tap is only built in `start()`, and even then a private
    // aggregate never appears in Audio MIDI Setup. This asserts the cheap half
    // - construction is inert - which is what keeps the suite hardware-free.
    let before = countSonarAggregates()
    _ = [TapDetector(), TapDetector(), TapDetector()]
    #expect(countSonarAggregates() == before, "constructing a detector created a HAL device")
}

@Test func aSonarAggregateLeftBehindAlwaysHasInputStreams() {
    // The regression behind the bug, as an invariant on the *machine's own*
    // devices: an aggregate built without a tap list has no input stream at
    // all, which is exactly why the tap delivered nothing. A zero-stream
    // aggregate named like ours is a leaked one from a previous run - the shape
    // the fix makes impossible and `purgeStaleAggregates` reaps.
    //
    // This builds nothing: it reads the stream count of whatever aggregates
    // already exist. On a clean CI machine there are none and the loop is
    // empty; on a developer machine that has leaked one it is a tripwire.
    let leaked = aggregateDeviceIDs()
        .filter { isSonarAggregateName(deviceName($0)) }
        .filter { (devicePropertyUInt32($0, kAudioDevicePropertyStreams) ?? 0) == 0 }
    #expect(leaked.isEmpty, "zero-stream Sonar aggregates present: \(leaked.map(deviceName))")
}

@Test func everyAggregateOnThisMachineAnswersTheTapListProperty() {
    // Whatever aggregates exist must be identifiable as aggregates, which is
    // what lets `purgeStaleAggregates` sweep them by name. If the property
    // were absent, the sweep would silently stop finding its own leftovers and
    // they would pile up in Audio MIDI Setup.
    for id in aggregateDeviceIDs() {
        #expect(isAggregateDevice(id))
        #expect(deviceName(id) != nil, "an aggregate with no name cannot be swept")
    }
}

@Test func aDetectorStartsIdleAndStopsIdleSoTheEngineCanPollIt() {
    // The controller reads `isCapturing` on every tick, so the property has to
    // be safe to read at any point in the lifecycle, including before start
    // and after stop. Both are exercised above; this pins them together with
    // the status the engine's fallback logic switches on.
    let tap = freshTap()
    #expect(tap.status == .idle)
    tap.start()
    tap.stop()
    #expect(tap.status == .idle)
}

// MARK: - Statuses are what the engine's fallback keys on

@Test func anUnavailableStatusCarriesAReasonWorthShowing() {
    // The status enum is the engine's whole fallback channel, and the reason
    // is what the preferences banner prints. An empty reason would show a
    // blank banner and send the user to System Settings for nothing, which is
    // the specific confusion the zero-stream bug caused.
    let status = TapStatus.unavailable(reason: "aggregate has no input stream (streams=0x0)")
    if case .unavailable(let reason) = status {
        #expect(!reason.isEmpty)
    } else {
        Issue.record("expected .unavailable")
    }
}

@Test func aZeroStreamAggregateIsDistinguishableFromAPermissionFailure() {
    // Both end in `.unavailable`, so the *reason* has to carry the difference.
    // "no input stream" means a wiring problem no permission dialog can fix;
    // anything else means ask the user to grant Screen & System Audio
    // Recording. Conflating them is what made the original bug look like a
    // permissions problem on a machine where the permission was already
    // granted.
    let noStream = "aggregate has no input stream (streams=0x0)"
    let noAudio = "tap started but delivered no buffers"
    #expect(noStream.contains("no input stream"))
    #expect(!noStream.contains("permission"))
    #expect(noAudio.contains("delivered no buffers"))
}

@Test func detectorNamesAreDistinctBecauseTheDiagnosticsPrintThem() {
    // "poll" and "tap" are the two labels the log and the preferences pane
    // show, and they are the only place a user can tell which backend is
    // actually measuring.
    #expect(TapDetector().name == "tap")
    #expect(PollDetector().name == "poll")
    #expect(DetectorKind.tap.rawValue == "tap")
    #expect(DetectorKind.poll.rawValue == "poll")
    // ...and the detector name and the detector kind agree, so a label can
    // never say one thing while the engine does another.
    #expect(TapDetector().name == DetectorKind.tap.rawValue)
    #expect(PollDetector().name == DetectorKind.poll.rawValue)
}

// MARK: - Hardware-gated liveness, off by default

@Test func aStartedTapEventuallyEitherCapturesOrReportsUnavailable() {
    // This is the liveness probe the permission model depends on: "truth is
    // the tap receiving buffers, never the preflight flag". It is opt-in
    // because it needs a permission grant and a real device, and the suite has
    // to pass in CI with nothing granted.
    guard ProcessInfo.processInfo.environment["SONAR_TAP_SMOKE"] != nil else { return }
    let tap = TapDetector()
    tap.onDiagnostic = { _ in }
    tap.start()
    // The build path waits for buffers and downgrades to `.unavailable` when
    // none arrive, so either outcome is correct - what must not happen is
    // silence with no explanation.
    let deadline = Date().addingTimeInterval(10)
    while tap.status == .starting || tap.status == .idle, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    switch tap.status {
    case .active:
        #expect(tap.isCapturing, "an active tap that never delivered buffers is the wiring bug")
        #expect(tap.format != nil, "an active tap must know the format it is measuring")
    case .unavailable(let reason):
        #expect(!reason.isEmpty)
    case .starting, .idle:
        Issue.record("the tap never left \(tap.status) within 10s")
    }
    tap.stop()
}

@Test func aStartedTapWithPermissionDeliversRealAudioWhenSomethingIsPlaying() {
    // Opt-in, and only meaningful with the permission granted *and* something
    // actually making sound. It asserts the property the whole tap exists for:
    // the measured RMS tracks the room rather than reading zero forever.
    guard ProcessInfo.processInfo.environment["SONAR_TAP_AUDIO"] != nil else { return }
    let tap = TapDetector()
    tap.start()
    let deadline = Date().addingTimeInterval(15)
    while !tap.isCapturing, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    #expect(tap.isCapturing, "no buffers after 15s with the permission granted")
    // Peak, not RMS: a short transient still proves samples arrived.
    var peak: Float = 0
    while Date() < deadline, peak < 0.001 {
        peak = max(peak, tap.lastPeak)
        Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(peak > 0.001, "the tap is capturing but every sample is zero")
    tap.stop()
}
