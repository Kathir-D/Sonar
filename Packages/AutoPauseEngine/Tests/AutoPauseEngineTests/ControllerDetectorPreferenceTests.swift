import Foundation
import Testing
@testable import AutoPauseEngine

/// Which detector actually drives decisions is the whole point of the tap, and
/// the bug this file exists to pin is the one where a *non-functional* tap looks
/// perfectly healthy.
///
/// A tap can be created, attached and started and still never deliver a buffer
/// - that is exactly what the mis-built aggregate did (name + UID only, no tap
/// list, no `isPrivate`: zero streams, no input, `AudioDeviceStart` answering
/// 'nope'). In that state `status` is still `.active`, so a controller that
/// trusts the *status* believes it has loudness detection and never pauses,
/// because a tap with no buffers reports silence forever.
///
/// The invariant pinned here: the tap is trusted only when it has actually
/// delivered buffers (`isCapturing`). Everything else - existing, running,
/// `.active`, reporting a loud RMS - is not enough.
///
/// No Core Audio, no permission, no device: `isCapturing` is only ever true
/// after a real IOProc callback, so a `TapDetector` that was constructed but
/// never started is permanently `false`, which is the worst case by
/// construction.

private func pollOnlyController(
    _ log: EngineEventLog,
    poll: RecordingPoll = RecordingPoll()
) -> AutoPauseController {
    let controller = AutoPauseController(
        poll: poll, tap: nil, adapter: SpotifyFadeAdapter(control: FakeSpotifyControl(), mode: .instant))
    controller.adapter.rereadDelay = 0
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.onEvent = { log.record($0) }
    return controller
}

/// A controller whose tap exists but has never been started, so
/// `TapDetector.isCapturing` is false - the mis-wired-aggregate state.
private func unstartedTapController(
    _ log: EngineEventLog,
    poll: RecordingPoll = RecordingPoll()
) -> (controller: AutoPauseController, tap: TapDetector) {
    let tap = TapDetector()
    let adapter = SpotifyFadeAdapter(control: FakeSpotifyControl(), mode: .instant)
    adapter.rereadDelay = 0
    let controller = AutoPauseController(poll: poll, tap: tap, adapter: adapter)
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.onEvent = { log.record($0) }
    return (controller, tap)
}

// MARK: - Poll is the default and the fallback

@Test func aFreshControllerHasNotDecidedAnythingYet() {
    let log = EngineEventLog()
    let controller = pollOnlyController(log)
    // Before the first tick there is no evidence either way, and the honest
    // answer is poll: it is the only backend that needs no permission.
    #expect(controller.drivingDetector == .poll)
}

@Test func aControllerWithoutATapIsPollDriven() {
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = pollOnlyController(log, poll: poll)

    controller.tick()
    #expect(controller.drivingDetector == .poll)
    // ...and poll is what fusion actually saw, or this proves nothing.
    #expect(log.candidates == ["poll"], "got \(log.candidates)")
}

@Test func aControllerWithNoTapStillResumesFromPollQuiet() {
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let controller = pollOnlyController(log, poll: poll)
    poll.signal = AudioSignal(isActive: true, rms: nil)
    controller.tick()
    #expect(controller.adapter.isOwned)

    poll.signal = AudioSignal(isActive: false, rms: nil)
    controller.tick()
    #expect(log.events.contains(.restored))
    #expect(!controller.adapter.isOwned)
}

// MARK: - THE REGRESSION: a tap that exists and says .active is still not trusted

@Test func anUnstartedTapIsNotCapturing() {
    // Premise for everything below, and the property the engine reads.
    let tap = TapDetector()
    #expect(tap.isCapturing == false)
    #expect(tap.format == nil)
    #expect(tap.lastPeak == 0)
    #expect(tap.status == .idle)
}

@Test func aTapThatHasNeverDeliveredBuffersDoesNotDriveDecisions() {
    // The mis-built aggregate, hardware-free: the tap object exists, the
    // controller holds it, and `isCapturing` is false. Poll must keep driving.
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let (controller, tap) = unstartedTapController(log, poll: poll)

    controller.tick()
    #expect(tap.isCapturing == false)
    #expect(controller.drivingDetector == .poll, "a tap with no buffers took over the vote")
    #expect(log.candidates == ["poll"], "got \(log.candidates)")
}

@Test func aTapReportingActiveWithNoBuffersIsStillNotTrusted() {
    // The precise shape of the bug: `status == .active(rms:)` is what the old
    // code keyed off, and a zero-stream aggregate reaches `.active` while
    // delivering nothing. Trusting the status is what made auto-pause silently
    // stop working; only `isCapturing` may grant the vote.
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let (controller, tap) = unstartedTapController(log, poll: poll)

    // Fire the status callback the way a successful start would.
    tap.onStatusChange?(.active(rms: 0.9))

    controller.tick()
    #expect(controller.drivingDetector == .poll)
    #expect(log.events.contains(.tapReady), "the status is still reported for diagnostics")
    // The decision came from poll, not from the tap's claimed loudness.
    #expect(log.candidates == ["poll"], "got \(log.candidates)")
}

@Test func aTapThatReportsActiveKeepsLosingToPollWhileItDeliversNoBuffers() {
    // Trust is revocable, and it was never granted. If a device is unplugged or
    // the aggregate is torn down, a tap that *had* been delivering must hand
    // the vote straight back to poll rather than freeze on the last RMS it ever
    // saw. Here the tap never delivers at all, so the answer must never change
    // no matter how loudly its status claims otherwise.
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let (controller, tap) = unstartedTapController(log, poll: poll)

    controller.tick()
    #expect(controller.drivingDetector == .poll)
    // Whatever the tap reported in between, a tap that is not capturing is
    // not consulted: poll drives, and the controller says so every tick.
    tap.onStatusChange?(.active(rms: 0.5))
    for _ in 0..<5 { controller.tick() }
    #expect(controller.drivingDetector == .poll)
    #expect(poll.refreshCount == 6, "poll must keep refreshing either way")
}

// MARK: - An unavailable tap degrades to poll, loudly

@Test func anUnavailableTapReportsTheReasonAndFallsBackToPoll() {
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let (controller, tap) = unstartedTapController(log, poll: poll)

    tap.onStatusChange?(.unavailable(reason: "aggregate has no input stream (streams=0x0)"))
    controller.tick()

    #expect(log.events.contains(.tapUnavailable(reason: "aggregate has no input stream (streams=0x0)")))
    #expect(controller.drivingDetector == .poll)
    // The banner is not a dead end: poll detection still works.
    #expect(log.candidates == ["poll"], "got \(log.candidates)")
}

@Test func anUnavailableTapStaysOutOfTheVoteWhilePollKeepsWorking() {
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let (controller, tap) = unstartedTapController(log, poll: poll)
    tap.onStatusChange?(.unavailable(reason: "no permission"))

    poll.signal = AudioSignal(isActive: true, rms: nil)
    controller.tick()
    #expect(log.candidates == ["poll"])
    poll.signal = AudioSignal(isActive: false, rms: nil)
    controller.tick()
    #expect(log.events.contains(.restored))
    #expect(controller.drivingDetector == .poll)
}

@Test func theTapReportingAReadinessEventDoesNotImplyItDecidedAnything() {
    // `.tapReady` means "the tap started", and `.tapVerified` means "buffers
    // arrived". They are diagnostics. Neither may make the controller duck
    // Spotify on its own: without a decision there is no `.ducked` event.
    let log = EngineEventLog()
    let (controller, tap) = unstartedTapController(log)

    tap.onStatusChange?(.starting)
    controller.tick()
    #expect(log.events.isEmpty, "got \(log.events)")

    tap.onStatusChange?(.active(rms: 0.7))
    controller.tick()
    #expect(log.candidates.isEmpty, "a live-looking tap with no buffers must not duck")
    #expect(!controller.adapter.isOwned)
}

// MARK: - Polling is unconditional

@Test func pollIsRefreshedEvenWhenItIsNotTheDecidingDetector() {
    // The diagnostics pane lists the currently-playing sources, so poll runs
    // every tick regardless of who decides. If this ever regressed, the
    // "watching:" list would freeze the moment the tap came online.
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let (controller, _) = unstartedTapController(log, poll: poll)
    for _ in 0..<4 { controller.tick() }
    #expect(poll.refreshCount == 4)
}

@Test func drivingDetectorIsStableAcrossRepeatedTicks() {
    // It is read by the UI to render a persistent label, so it must not flap
    // on consecutive ticks of the same state.
    let log = EngineEventLog()
    let (controller, _) = unstartedTapController(log)
    var seen: Set<DetectorKind> = []
    for _ in 0..<10 {
        controller.tick()
        seen.insert(controller.drivingDetector)
    }
    #expect(seen == [.poll])
}

@Test func stopResetsTheDetectorToTheSafeDefault() {
    // After stop() the engine has no evidence for either backend, so the
    // reported kind must be the permission-free one rather than a stale claim.
    let log = EngineEventLog()
    let (controller, _) = unstartedTapController(log)
    controller.tick()
    controller.stop()
    #expect(controller.drivingDetector == .poll)
    // ...and the streaks are cleared so the next episode re-dwells.
    #expect(controller.fusion.loudStreakStart == nil)
    #expect(controller.fusion.quietStreakStart == nil)
}

// MARK: - The .tap path, pending a test seam

// The positive case - "a tap that IS delivering buffers reports .tap and
// decides alone" - cannot be reached without hardware: `TapDetector` is a
// `final class`, `isCapturing` is a read-only computed property over private
// state, and only a real IOProc callback sets it. There is no seam to inject a
// capturing tap, and `AutoPauseController.tap` is typed as the concrete
// `TapDetector?` rather than a protocol.
//
// The minimal patch that unlocks it is in the report: extract
// `protocol TapSignalSource: HybridDetector { var isCapturing: Bool { get } }`,
// have `TapDetector` conform, and type `AutoPauseController.tap` as
// `any TapSignalSource?`. Then this body compiles unchanged:
//
//     final class CapturingTap: TapSignalSource { ... }
//
// It is left behind `#if TAP_FAKES` so it does not break the build, and so
// enabling it is a one-line change plus the patch.
#if TAP_FAKES
    final class CapturingTap: HybridDetector, @unchecked Sendable {
        let name = "tap"
        var isCapturing = true
        var signal = AudioSignal(isActive: true, rms: 0.5)
        var latestSignal: AudioSignal? { signal }
        func start() {}
        func stop() {}
    }

    @Test func aCapturingTapIsReportedAsTheDrivingDetectorAndDecidesAlone() {
        let poll = RecordingPoll()
        poll.signal = AudioSignal(isActive: true, rms: nil)
        let log = EngineEventLog()
        let tap = CapturingTap()
        let adapter = SpotifyFadeAdapter(control: FakeSpotifyControl(), mode: .instant)
        adapter.rereadDelay = 0
        let controller = AutoPauseController(poll: poll, tap: tap, adapter: adapter)
        controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
        controller.onEvent = { log.record($0) }

        controller.tick()
        #expect(controller.drivingDetector == .tap)
        #expect(log.events.contains(.tapVerified))
        // The source is the tap, which means fusion was fed the tap alone: a
        // poll+tap label here would mean poll was still voting.
        #expect(log.candidates == ["tap"], "got \(log.candidates)")

        // And the tap is trusted even while poll says nothing at all, which is
        // the measured real-world case: a browser playing audio reports "not
        // running output" while the tap clearly hears it.
        poll.signal = AudioSignal(isActive: false, rms: nil)
        tap.signal = AudioSignal(isActive: true, rms: 0.5)
        controller.tick()
        #expect(log.candidates == ["tap"], "poll overruled a live tap: \(log.candidates)")

        // Silence from the tap resumes, even while poll still claims activity.
        tap.signal = AudioSignal(isActive: false, rms: 0)
        controller.tick()
        #expect(log.events.contains(.restored))
    }

    @Test func aCapturingTapThatGoesQuietCannotBeOverruledByPoll() {
        // The inverse error: poll can only say "is holding the output", so
        // letting it outvote the tap is what made a paused browser tab hold
        // Spotify paused for minutes.
        let poll = RecordingPoll()
        poll.signal = AudioSignal(isActive: true, rms: nil)
        let log = EngineEventLog()
        let tap = CapturingTap()
        let adapter = SpotifyFadeAdapter(control: FakeSpotifyControl(), mode: .instant)
        adapter.rereadDelay = 0
        let controller = AutoPauseController(poll: poll, tap: tap, adapter: adapter)
        controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
        controller.onEvent = { log.record($0) }

        controller.tick()
        #expect(log.events.contains(.ducked(source: "tap")))

        tap.signal = AudioSignal(isActive: false, rms: 0)
        controller.tick()
        #expect(log.events.contains(.restored), "poll kept the resume blocked")
    }
#endif
