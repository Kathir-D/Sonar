import Foundation
import Testing
@testable import AutoPauseEngine

/// `AutoPauseController` is the engine's tick loop, and `tick()` is public and
/// synchronous precisely so it can be driven with no clock, no Core Audio and
/// no Spotify. `poll:` is a `RefreshingDetector` so the scan can be replaced
/// with a scripted signal; the adapter is driven through `FakeSpotifyControl`.
///
/// Two things are pinned here:
/// - the tick's own mechanics (one event per episode, disabled behaviour,
///   re-arming after stop), and
/// - that poll is refreshed every tick even when it is not the deciding
///     detector, because the diagnostics list depends on it.
///
/// The detector *preference* (tap vs poll) lives in
/// `ControllerDetectorPreferenceTests.swift`.

/// A poll detector that returns a scripted signal and counts refreshes, so the
/// controller can be ticked synchronously with no Core Audio and no clock
/// injection.
final class RecordingPoll: RefreshingDetector, @unchecked Sendable {
    let name = "recording-poll"
    var filter = SourceFilter()
    var signal = AudioSignal(isActive: false, rms: nil)
    var latestSignal: AudioSignal? { signal }
    private let lock = NSLock()
    private var _refreshCount = 0
    private var _startCount = 0
    private var _stopCount = 0

    var refreshCount: Int { lock.lock(); defer { lock.unlock() }; return _refreshCount }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

    func start() { lock.lock(); _startCount += 1; lock.unlock() }
    func stop() { lock.lock(); _stopCount += 1; lock.unlock() }
    func refresh() -> AudioSignal {
        lock.lock(); _refreshCount += 1; lock.unlock()
        return signal
    }
}

final class EngineEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [EngineEvent] = []

    func record(_ event: EngineEvent) {
        lock.lock(); _events.append(event); lock.unlock()
    }

    var events: [EngineEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    var candidates: [String] {
        events.compactMap { if case .candidate(let s) = $0 { return s } else { return nil } }
    }
    var tapReasons: [String] {
        events.compactMap { if case .tapUnavailable(let r) = $0 { return r } else { return nil } }
    }
}

/// Poll-only controller with zero dwell times, so every tick is a decision.
private func scriptedController(
    _ log: EngineEventLog,
    poll: RecordingPoll = RecordingPoll()
) -> AutoPauseController {
    let adapter = SpotifyFadeAdapter(control: FakeSpotifyControl(), mode: .instant)
    adapter.rereadDelay = 0
    let controller = AutoPauseController(poll: poll, tap: nil, adapter: adapter)
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.onEvent = { log.record($0) }
    return controller
}

// MARK: - One log line per episode, not one per tick

@Test func controllerAnnouncesACandidateOncePerEpisode() {
    // The diagnostics log is read by users. A 10 Hz "Candidate (poll)" line
    // per second of a video is unusable, so the event is transition-only.
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)

    for _ in 0..<10 { controller.tick() }
    #expect(log.candidates == ["poll"], "got \(log.candidates)")

    // The adapter is still driven every tick, it just no-ops internally.
    #expect(controller.adapter.isOwned)
}

@Test func controllerAnnouncesANewCandidateAfterTheNextQuietEpisode() {
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)

    controller.tick()
    poll.signal = AudioSignal(isActive: false, rms: nil)
    controller.tick()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    controller.tick()
    controller.tick()

    #expect(log.candidates == ["poll", "poll"], "got \(log.candidates)")
    #expect(log.events.contains(.restored), "the quiet episode must restore before the next duck")
}

@Test func manyEpisodesInARowProduceOneCandidateLineEach() {
    // A long evening of a browser making noise: the log has to stay readable,
    // and each episode has to re-announce (otherwise the second video is
    // invisible in the log and support cannot tell it happened).
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)

    for episode in 1...5 {
        poll.signal = AudioSignal(isActive: true, rms: nil)
        for _ in 0..<3 { controller.tick() }
        poll.signal = AudioSignal(isActive: false, rms: nil)
        controller.tick()
        #expect(log.candidates.count == episode, "episode \(episode): \(log.candidates)")
    }
    // One restore per episode, and no reason to relinquish: nothing the user
    // did, so the engine keeps ownership across the whole run.
    #expect(log.events.filter { $0 == .restored }.count == 5)
}

// MARK: - Adapter events reach the same log

@Test func controllerForwardsAdapterEventsAlongsideItsOwn() {
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)

    controller.tick()
    #expect(log.events == [.candidate(source: "poll"), .ducked(source: "poll")])

    poll.signal = AudioSignal(isActive: false, rms: nil)
    controller.tick()
    #expect(log.events.last == .restored)
}

@Test func controllerForwardsARelinquishReasonFromTheAdapter() {
    // The relinquish reasons are the most useful thing in a support log: they
    // say who won. A reason that never reached the engine's log would leave the
    // user with a pause they could not explain.
    let fake = FakeSpotifyControl()
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = AutoPauseController(poll: poll, tap: nil, adapter: adapter)
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.reconcileInterval = 0
    controller.onEvent = { log.record($0) }

    controller.tick()
    #expect(controller.adapter.isOwned)
    // The controller only reconciles on a `.hold` tick (a `.candidate` tick
    // drives the duck instead), so the loud streak has to be spent for the
    // reconcile branch to be reachable. A fresh long-dwell fusion is the
    // cheapest way to force that deterministically.
    controller.fusion = FusionState(activeDuration: 60, quietDuration: 60)
    // The user hits play behind our back.
    fake.state = .playing
    controller.tick()
    #expect(log.events.contains(EngineEvent.relinquished(.manuallyResumed)), "got \(log.events)")
    #expect(!controller.adapter.isOwned)
}

@Test func controllerForwardsSkippedNotPlaying() {
    let fake = FakeSpotifyControl()
    fake.state = .paused
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = AutoPauseController(poll: poll, tap: nil, adapter: adapter)
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.onEvent = { log.record($0) }

    controller.tick()
    #expect(log.events == [.candidate(source: "poll"), .skippedNotPlaying])
    #expect(!controller.adapter.isOwned)
}

@Test func controllerDoesNotResumeWhenItNeverPaused() {
    // Quiet from the start: fusion says "resume", the adapter must not. A
    // resume we never earned starts music the user paused an hour ago.
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)

    for _ in 0..<3 { controller.tick() }
    #expect(log.events.isEmpty, "got \(log.events)")
    #expect(!controller.adapter.isOwned)
}

// MARK: - Tick mechanics

@Test func controllerSkipsEverythingWhileDisabled() {
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)
    controller.enabled = false

    controller.tick()
    #expect(poll.refreshCount == 0, "a disabled engine must not run Core Audio scans")
    #expect(log.events.isEmpty)

    // Re-enabling takes effect on the next tick, with no restart.
    controller.enabled = true
    controller.tick()
    #expect(poll.refreshCount == 1)
}

@Test func aDisabledEngineDoesNotReconcileEither() {
    // Reconcile costs AppleEvents. A disabled engine must be completely inert,
    // or disabling auto-pause would keep spending round trips against Spotify.
    let fake = FakeSpotifyControl()
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let controller = AutoPauseController(poll: poll, tap: nil, adapter: adapter)
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.reconcileInterval = 0
    controller.onEvent = { _ in }

    controller.tick()
    #expect(controller.adapter.isOwned)
    fake.resetCalls()
    controller.enabled = false
    for _ in 0..<5 { controller.tick() }
    #expect(fake.calls.isEmpty, "a disabled engine still talked to Spotify: \(fake.calls)")
}

@Test func controllerRefreshesPollOnEveryTick() {
    // Poll is refreshed unconditionally because it feeds the diagnostics UI
    // ("watching: Chrome") even when the tap is the one making decisions.
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)
    controller.reconcileInterval = 0

    for _ in 0..<5 { controller.tick() }
    #expect(poll.refreshCount == 5)
    #expect(poll.startCount == 0, "ticking must not start the detector")
}

@Test func tickingNeverStartsOrStopsTheDetectors() {
    // `start()` / `stop()` are lifecycle, not tick work. A tick that called
    // either would rebuild the tap 10 times a second.
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)
    for _ in 0..<10 { controller.tick() }
    #expect(poll.startCount == 0)
    #expect(poll.stopCount == 0)
}

@Test func controllerStopReArmsTheCandidateAnnouncement() {
    // Disable/enable and sleep/wake both go through stop(). If the
    // "announced" latch survived, the second episode of the night would
    // produce no log line at all and would look like auto-pause never fired.
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)

    controller.tick()
    #expect(log.candidates == ["poll"])

    controller.stop()
    #expect(poll.stopCount == 1)

    controller.tick()
    #expect(log.candidates == ["poll", "poll"], "stop() must re-arm the announcement")
}

@Test func controllerStopClearsTheFusionStreaks() {
    // Otherwise a tap that has been silent for an hour would resume Spotify
    // the instant it started again: the quiet streak would already be far
    // longer than quietDuration.
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)
    controller.fusion = FusionState(activeDuration: 10, quietDuration: 10)

    controller.tick()
    #expect(controller.fusion.loudStreakStart != nil)

    poll.signal = AudioSignal(isActive: false, rms: nil)
    controller.tick()
    #expect(controller.fusion.quietStreakStart != nil)

    controller.stop()
    #expect(controller.fusion.loudStreakStart == nil)
    #expect(controller.fusion.quietStreakStart == nil)
    #expect(poll.stopCount == 1)
}

@Test func controllerStopIsSafeWithoutAnyPriorTick() {
    // `stop()` is called from `deinit`-adjacent teardown paths and on sleep,
    // including when the engine never ran.
    let poll = RecordingPoll()
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)
    controller.stop()
    controller.stop()
    #expect(poll.stopCount == 2)
    #expect(log.events.isEmpty)
}

@Test func controllerSendsTheFirstDuckThroughWithTheSourceLabel() {
    // The source string ends up in the log and is the only way to tell from a
    // support log which detector fired.
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)

    controller.tick()
    #expect(log.events.first == .candidate(source: "poll"))
    #expect(log.events.contains(.ducked(source: "poll")))
}

@Test func theSourceLabelReachesBothTheEngineAndTheAdapterLogs() {
    // One episode, one label, on both events. A mismatch here is what makes a
    // support log contradictory ("Candidate (poll)" then "Ducked (tap)").
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let log = EngineEventLog()
    let controller = scriptedController(log, poll: poll)
    controller.tick()
    let candidates = log.candidates
    let ducks = log.events.compactMap { event -> String? in
        if case .ducked(let source) = event { return source }
        return nil
    }
    #expect(candidates == ducks)
}

// MARK: - Reconcile throttling

@Test func reconcileIsThrottledToTheConfiguredInterval() {
    // Reconcile costs an AppleEvent round trip, and it used to run on every
    // 10 Hz tick, which starved the fusion evaluation: measured with
    // quietDuration = 1 s, the resume actually took ~5.3 s. A long interval
    // makes the throttle observable with a fixed number of ticks.
    let fake = FakeSpotifyControl()
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let controller = AutoPauseController(poll: poll, tap: nil, adapter: adapter)
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.reconcileInterval = 60  // effectively "once per episode"
    controller.onEvent = { _ in }

    controller.tick()
    #expect(adapter.isOwned)
    fake.resetCalls()

    for _ in 0..<50 { controller.tick() }
    #expect(fake.calls.filter { $0 == "pid" }.count <= 1, "reconcile was not throttled")
}

@Test func reconcileIsAllowedAgainOnceTheIntervalHasElapsed() {
    // The other half of the throttle: a zero interval must reconcile on every
    // eligible tick, or "detecting a manual resume does not need 10 Hz" would
    // become "detecting it never happens".
    let fake = FakeSpotifyControl()
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let controller = AutoPauseController(poll: poll, tap: nil, adapter: adapter)
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.reconcileInterval = 0
    controller.onEvent = { _ in }

    controller.tick()
    #expect(adapter.isOwned)
    // `.hold` is the only decision that reconciles, so spend the loud streak
    // first - otherwise the second tick is another `.candidate` and reconcile
    // is never reached, which would make this test pass for the wrong reason.
    controller.fusion = FusionState(activeDuration: 60, quietDuration: 60)
    // The user hits play: an unthrottled reconcile must notice on the next tick.
    fake.state = .playing
    controller.tick()
    #expect(!adapter.isOwned)
}

@Test func reconcileStaysOffWhenNotOwned() {
    // Nothing to reconcile: there is no ownership to give up, and the pid
    // lookup is the first thing reconcile does, so this is the cheapest
    // assertion that the ownership guard comes first.
    let fake = FakeSpotifyControl()
    let log = EngineEventLog()
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    // The adapter logs to its own channel, which the controller forwards onto
    // the engine log; capturing the engine side is what the test reads.
    adapter.onEvent = { _ in }
    let controller = AutoPauseController(poll: RecordingPoll(), tap: nil, adapter: adapter)
    controller.onEvent = { log.record($0) }
    controller.reconcileInterval = 0

    for _ in 0..<20 { controller.tick() }
    #expect(fake.calls.filter { $0 == "pid" }.isEmpty)
    #expect(log.events.isEmpty)
}
