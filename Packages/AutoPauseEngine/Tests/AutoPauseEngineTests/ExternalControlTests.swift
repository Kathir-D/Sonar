import Foundation
import Testing
@testable import AutoPauseEngine

/// Another process driving Spotify behind Sonar's back: trak, a shell
/// `osascript`, a media key. To the adapter all of them look the same - the
/// player state or volume it reads no longer matches what it left - so these
/// tests change `FakeSpotifyControl` between engine calls, which is exactly
/// what an outside AppleScript does to the real player.
///
/// The README promises that a manual pause or volume change releases
/// ownership. Most of these tests confirm it. The ones named `DEVIATION` pin
/// what the code does today where that promise does not hold; they assert
/// current behaviour, not the intended one, so a change to the adapter shows
/// up here as a deliberate flip rather than a silent drift.

private func adapter(_ fake: FakeSpotifyControl, _ mode: DuckMode, fade: TimeInterval = 0) -> SpotifyFadeAdapter {
    let adapter = SpotifyFadeAdapter(
        control: fake, mode: mode, fadeOutDuration: fade, fadeInDuration: fade)
    adapter.rereadDelay = 0
    adapter.fadeStepInterval = 0.05
    return adapter
}

// MARK: - Through the engine tick

/// A controller that ducks on its first tick, then holds (so every later tick
/// is a reconcile), the same shape `controllerForwardsARelinquishReasonFromTheAdapter`
/// uses.
private func duckedController(
    _ fake: FakeSpotifyControl,
    _ log: EngineEventLog,
    mode: DuckMode = .instant
) -> (AutoPauseController, RecordingPoll) {
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let controller = AutoPauseController(poll: poll, tap: nil, adapter: adapter(fake, mode))
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.reconcileInterval = 0
    controller.onEvent = { log.record($0) }
    controller.tick()
    controller.fusion = FusionState(activeDuration: 60, quietDuration: 60)
    return (controller, poll)
}

@Test func anExternalVolumeChangeWhileDuckedReleasesOwnershipOnTheNextTick() {
    let fake = FakeSpotifyControl()
    let log = EngineEventLog()
    let (controller, poll) = duckedController(fake, log)
    #expect(controller.adapter.isOwned)

    fake.currentVolume = 35  // osascript -e 'tell application "Spotify" to set sound volume to 35'
    controller.tick()
    #expect(log.events.contains(.relinquished(.volumeChangedByUser)), "got \(log.events)")
    #expect(!controller.adapter.isOwned)

    // The room goes quiet: Sonar must leave both the pause and the 35 alone.
    poll.signal = AudioSignal(isActive: false, rms: nil)
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    fake.resetCalls()
    controller.tick()
    #expect(!fake.calls.contains("play"), "resumed after the user took over: \(fake.calls)")
    #expect(fake.volumesSet.isEmpty)
    #expect(fake.currentVolume == 35)
    #expect(fake.state == .paused)
}

@Test func anExternalPlayWhileDuckedReleasesOwnershipOnTheNextTick() {
    let fake = FakeSpotifyControl()
    let log = EngineEventLog()
    let (controller, _) = duckedController(fake, log)

    fake.state = .playing  // tell application "Spotify" to play
    fake.resetCalls()
    controller.tick()
    #expect(log.events.contains(.relinquished(.manuallyResumed)), "got \(log.events)")
    #expect(!controller.adapter.isOwned)
    #expect(!fake.calls.contains("pause"), "Sonar fought the outside play")
}

@Test func anExternalPauseBeforeADuckIsNeverResumed() {
    // trak pauses, then a notification chimes: Sonar must not take ownership
    // of a pause it did not make, so the following quiet starts nothing.
    let fake = FakeSpotifyControl()
    fake.state = .paused
    let log = EngineEventLog()
    let poll = RecordingPoll()
    poll.signal = AudioSignal(isActive: true, rms: nil)
    let controller = AutoPauseController(poll: poll, tap: nil, adapter: adapter(fake, .fadeAndPause))
    controller.fusion = FusionState(activeDuration: 0, quietDuration: 0)
    controller.onEvent = { log.record($0) }

    controller.tick()
    poll.signal = AudioSignal(isActive: false, rms: nil)
    controller.tick()
    #expect(!controller.adapter.isOwned)
    #expect(!fake.calls.contains("play"))
    #expect(fake.volumesSet.isEmpty)
}

// MARK: - Adapter rules, per mode

@Test func anExternalVolumeChangeWhileDuckedInInstantModeIsPreserved() {
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = adapter(fake, .instant)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "tap")
    fake.currentVolume = 20
    adapter.reconcileSync()
    #expect(log.reasons == [.volumeChangedByUser])
    fake.resetCalls()
    adapter.restoreSync()
    #expect(fake.calls.isEmpty, "restore after an outside volume change touched Spotify: \(fake.calls)")
    #expect(fake.currentVolume == 20)
}

@Test func anExternalVolumeChangeWhileMutedReleasesOwnership() {
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = adapter(fake, .muteOnly)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "tap")
    fake.currentVolume = 50
    adapter.reconcileSync()
    #expect(log.reasons == [.volumeChangedByUser])
    #expect(!adapter.isOwned)
    #expect(fake.currentVolume == 50)
}

// MARK: - Deviations from the documented promise

@Test func DEVIATION_anExternalPauseWhileAlreadyPausedByUsIsInvisibleAndStillResumes() {
    // Fade and Instant pause Spotify, so an outside `pause` lands on a player
    // that is already paused. Nothing observable changes - same pid, same
    // state, same volume - so ownership survives and the next quiet resumes
    // playback the other process meant to stop.
    for mode in [DuckMode.instant, .fadeAndPause] {
        let fake = FakeSpotifyControl()
        let log = AdapterEventLog()
        let adapter = adapter(fake, mode)
        adapter.onEvent = { log.record($0) }

        adapter.duckSync(source: "tap")
        fake.pause()  // tell application "Spotify" to pause
        adapter.reconcileSync()
        #expect(adapter.isOwned, "\(mode): ownership was expected to survive (undetectable)")
        #expect(log.reasons.isEmpty)

        fake.resetCalls()
        adapter.restoreSync()
        #expect(fake.calls.contains("play"), "\(mode): Sonar resumes the outside pause")
        #expect(fake.state == .playing)
    }
}

@Test func DEVIATION_anExternalPauseDuringTheFadeOutIsAbsorbedIntoOurOwnPause() {
    // Mid-fade Spotify is still playing because we have not paused it yet. An
    // outside pause in that window is read as our own in-flight change
    // (`duckInProgress`), the fade finishes, and the later restore plays.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = adapter(fake, .fadeAndPause, fade: 0.3)
    adapter.onEvent = { log.record($0) }

    var pausedMidFade = false
    fake.volumeSetHook = { [weak adapter] _ in
        guard !pausedMidFade, let adapter else { return }
        pausedMidFade = true
        fake.state = .paused
        adapter.reconcileSync()
    }
    adapter.duckSync(source: "tap")
    fake.volumeSetHook = nil

    #expect(pausedMidFade)
    #expect(adapter.isOwned)
    #expect(log.reasons.isEmpty)
    adapter.restoreSync()
    #expect(fake.state == .playing, "the outside pause is undone on quiet")
}

@Test func DEVIATION_anExternalVolumeChangeDuringTheFadeOutIsOverwritten() {
    // Same window, volume instead of pause: the fade keeps writing its own
    // ramp over the outside value, and the restore then fades back to the
    // pre-duck volume. The outside change is lost rather than preserved.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = adapter(fake, .fadeAndPause, fade: 0.3)
    adapter.onEvent = { log.record($0) }

    var changedMidFade = false
    fake.volumeSetHook = { [weak adapter] _ in
        guard !changedMidFade, let adapter else { return }
        changedMidFade = true
        fake.currentVolume = 90
        adapter.reconcileSync()
    }
    adapter.duckSync(source: "tap")
    fake.volumeSetHook = nil

    #expect(changedMidFade)
    #expect(adapter.isOwned)
    #expect(log.reasons.isEmpty)
    adapter.restoreSync()
    #expect(fake.currentVolume == 70, "the outside 90 is replaced by the pre-duck 70")
}

@Test func DEVIATION_anExternalPauseWhileMutedIsReportedAsARestoreNotARelinquish() {
    // Mute-only never pauses, so an outside pause is visible - but reconcile
    // only looks for "playing" or a volume change, so ownership is kept. The
    // restore then hands the volume back and reports `.restored`. It never
    // calls play, so the music does stay paused; only the bookkeeping differs.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = adapter(fake, .muteOnly)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "tap")
    fake.pause()
    adapter.reconcileSync()
    #expect(adapter.isOwned)
    #expect(log.reasons.isEmpty)

    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(fake.state == .paused)
    #expect(fake.currentVolume == 70)
    #expect(log.events.last == .restored)
}
