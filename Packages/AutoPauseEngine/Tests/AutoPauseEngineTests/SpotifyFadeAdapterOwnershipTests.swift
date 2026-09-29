import Foundation
import Testing
@testable import AutoPauseEngine

/// `SpotifyFadeAdapter` is the only thing in the engine that touches Spotify,
/// and its whole value is restraint: resume only what we paused, only for the
/// same process, and give up the moment the user does anything.
///
/// `FadeAdapterTests.swift` covers the happy paths and the script contract.
/// This file covers ownership and the anti-footgun rules, and calls out the
/// cases where the code's current behaviour is not the intended behaviour
/// (marked `KNOWNBUG` in the name) rather than quietly asserting the bug as
/// correct. Those tests are load-bearing: when the bug is fixed they fail, and
/// the comment says which way to flip them.
///
/// No AppleScript, no Spotify, no real sleep: `FakeSpotifyControl` (in
/// `FadeAdapterTests.swift`) is a pure recorder, and every delay the adapter
/// would have slept on is set to zero.

/// Collects `AdapterEvent`s. The adapter hands these to a `@Sendable` closure
/// that can fire on its serial queue, hence the unchecked conformance.
final class AdapterEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AdapterEvent] = []

    func record(_ event: AdapterEvent) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    var events: [AdapterEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    /// Only the relinquish reasons, in order.
    var reasons: [RelinquishReason] {
        events.compactMap {
            if case .relinquished(let reason) = $0 { return reason }
            return nil
        }
    }

    var ducks: [String] {
        events.compactMap {
            if case .ducked(let source) = $0 { return source }
            return nil
        }
    }

    /// Forget everything recorded so far, so one test can assert on a second
    /// episode without the first episode's events in the way.
    func reset() {
        lock.lock()
        _events.removeAll()
        lock.unlock()
    }
}

private func instantAdapter(_ fake: FakeSpotifyControl) -> SpotifyFadeAdapter {
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    return adapter
}

private func muteOnlyAdapter(_ fake: FakeSpotifyControl) -> SpotifyFadeAdapter {
    let adapter = SpotifyFadeAdapter(control: fake, mode: .muteOnly)
    adapter.rereadDelay = 0
    return adapter
}

private func fadeAdapter(
    _ fake: FakeSpotifyControl,
    out: TimeInterval = 0,
    back: TimeInterval = 0
) -> SpotifyFadeAdapter {
    let adapter = SpotifyFadeAdapter(
        control: fake, mode: .fadeAndPause, fadeOutDuration: out, fadeInDuration: back)
    adapter.rereadDelay = 0
    adapter.fadeStepInterval = 0.05
    return adapter
}

// MARK: - "Resume only if we paused it"

@Test func skippedNotPlayingIsReportedWhenSpotifyIsNotPlaying() {
    // The event is what the diagnostics log shows, and it is the only signal
    // that "we deliberately did nothing" rather than "we are mid-fade".
    for state in [SpotifyPlayerState.paused, .stopped, .unknown] {
        let fake = FakeSpotifyControl()
        fake.state = state
        let log = AdapterEventLog()
        let adapter = instantAdapter(fake)
        adapter.onEvent = { log.record($0) }

        adapter.duckSync(source: "poll")
        #expect(log.events == [.skippedNotPlaying], "state \(state.rawValue)")
        #expect(!adapter.isOwned)
        // Reads are fine (the adapter has to know the state to decide); the
        // rule is that it must not *write* anything.
        #expect(!fake.calls.contains("play"))
        #expect(!fake.calls.contains("pause"))
        #expect(fake.volumesSet.isEmpty)
    }
}

@Test func skippedNotPlayingCoversATransportFailure() {
    // AppleScript returning nil is "unknown", not "paused" - the adapter must
    // still refuse to take ownership rather than assume it can resume.
    let fake = FakeSpotifyControl()
    fake.transportFails = true
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(log.events == [.skippedNotPlaying])
    #expect(!adapter.isOwned)
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
}

@Test func aTransportFailureDuringRestoreDoesNotResume() {
    // The mirror of the duck case: if the state cannot be read at restore time
    // the adapter is looking at `.unknown`, and `.unknown` must never be read
    // as "paused by us, so play".
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }
    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)

    fake.transportFails = true
    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"), "an unreadable state must not start playback")
    #expect(log.reasons == [.manuallyStopped])
    #expect(!adapter.isOwned)
}

@Test func restoreIsACompleteNoOpWhenNotOwned() {
    // "Nothing to restore" must cost zero AppleEvents, not a read or two. A
    // resume that is not ours is the worst outcome, and the cheapest way to
    // avoid it is to do nothing at all.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.restoreSync()
    #expect(fake.calls.isEmpty, "restore while unowned touched Spotify: \(fake.calls)")
    #expect(fake.volumesSet.isEmpty)
    #expect(log.events.isEmpty)
    #expect(!adapter.isOwned)
}

@Test func restoreIsANoOpWhenNotOwnedInEveryMode() {
    // The `guard let ownedPID = owned.pid else { return }` is at the top of the
    // shared path, so this holds for all three modes - but mute-only and
    // fade-and-pause also have a volume to write, so it is checked per mode
    // rather than assumed. Nothing is owned here: no duck has run, which is
    // the state a controller is in for every quiet tick before the first
    // episode.
    for mode in DuckMode.allCases {
        let fake = FakeSpotifyControl()
        let log = AdapterEventLog()
        let adapter = SpotifyFadeAdapter(control: fake, mode: mode)
        adapter.rereadDelay = 0
        adapter.fadeStepInterval = 0
        adapter.onEvent = { log.record($0) }
        #expect(!adapter.isOwned, "\(mode.rawValue)")

        adapter.restoreSync()
        #expect(fake.calls.isEmpty, "\(mode.rawValue) restore while unowned touched Spotify: \(fake.calls)")
        #expect(fake.volumesSet.isEmpty, "\(mode.rawValue)")
        #expect(log.events.isEmpty, "\(mode.rawValue)")
        #expect(!adapter.isOwned, "\(mode.rawValue)")
    }
}

@Test func duckIsIdempotentWhileOwned() {
    // The engine calls duck() on every tick of a loud episode. The second and
    // following calls must be free: no pause, no volume write, no duplicate
    // `.ducked` event - and not even a pid lookup.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = muteOnlyAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(fake.volumesSet == [0])
    fake.resetCalls()

    adapter.duckSync(source: "poll")
    adapter.duckSync(source: "poll")
    #expect(fake.volumesSet.isEmpty, "re-duck wrote the volume again: \(fake.volumesSet)")
    #expect(fake.calls.isEmpty, "re-duck talked to Spotify again: \(fake.calls)")
    #expect(log.ducks == ["poll"], "one episode must produce one .ducked")
    #expect(adapter.isOwned)
}

@Test func duckIsIdempotentAcrossModes() {
    // The idempotence check is `isOwned`, which is mode-independent, but each
    // mode has a different write to suppress, so the write list is compared
    // per mode.
    for mode in DuckMode.allCases {
        let fake = FakeSpotifyControl()
        let adapter = SpotifyFadeAdapter(control: fake, mode: mode)
        adapter.rereadDelay = 0
        adapter.fadeOutDuration = 0
        adapter.fadeInDuration = 0
        adapter.duckSync(source: "poll")
        #expect(adapter.isOwned, "\(mode.rawValue)")
        fake.resetCalls()
        adapter.duckSync(source: "poll")
        #expect(
            !fake.calls.contains("pause") && !fake.calls.contains("play"),
            "\(mode.rawValue) re-duck issued a transport command")
        #expect(fake.volumesSet.isEmpty, "\(mode.rawValue) re-duck wrote the volume")
    }
}

@Test func ownershipSurvivesAUserPauseDuringTheDuck() {
    // A fade leaves Spotify *playing* by design while it fades; the user
    // pressing pause mid-fade must be detected as the user acting, not as
    // "our own pause finished".
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake, out: 0.2)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)
    #expect(log.ducks == ["poll"])

    fake.resetCalls()
    adapter.reconcileSync()
    // Spotify is paused *because we paused it*, so the state alone is not a
    // user action. Reconciliation must not start playback.
    #expect(!fake.calls.contains("play"))
    #expect(adapter.isOwned, "our own pause must not be mistaken for the user acting")
}

@Test func aReconcileDuringTheFadeDoesNotRelinquishOurOwnPlayback() {
    // Same rule, harder timing: a reconcile that lands *inside* the fade,
    // while Spotify is still playing because the fade has not paused it yet.
    // `duckInProgress` exists for exactly this. Losing ownership here would
    // mean the duck finishes into a no-op and Spotify keeps playing at volume
    // 0 forever, with nothing left to restore it.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake, out: 0.3, back: 0.3)
    adapter.onEvent = { log.record($0) }

    var reconciledMidFade = false
    fake.volumeSetHook = { [weak adapter] _ in
        guard !reconciledMidFade, let adapter else { return }
        reconciledMidFade = true
        adapter.reconcileSync()
    }

    adapter.duckSync(source: "poll")
    fake.volumeSetHook = nil

    #expect(reconciledMidFade, "the hook must have run inside the fade")
    #expect(adapter.isOwned, "the mid-fade reconcile stole our own playback")
    #expect(log.reasons.isEmpty, "the mid-fade reconcile emitted \(log.reasons)")
    #expect(fake.currentVolume == 0)
    #expect(fake.state == .paused, "the duck must still finish")

    // And a restore afterwards still works, which it cannot if the duck lost
    // ownership on the way.
    fake.resetCalls()
    adapter.restoreSync()
    #expect(fake.calls.contains("play"))
    #expect(fake.currentVolume == 70)
    #expect(!adapter.isOwned)
}

@Test func aReconcileDuringTheFadeInDoesNotStrandTheVolumeAtZero() {
    // Regression test. The restore side of the
    // `duckInProgress` rule: mid-fade-in Spotify is playing because *we* just
    // called play, so "playing" must not be read as the user having taken over.
    //
    // `duckInProgress` is only set around `duckImpl`, never around
    // `restoreImpl`, so a reconcile landing inside a fade-in sees
    // `state == .playing && !duckInProgress` and relinquishes with
    // `.manuallyResumed` - clearing `_duckedVolume` - while the fade-in itself
    // keeps running to completion.
    //
    // The bug this pins: `duckInProgress` was only set around `duckImpl`, never
    // around `restoreImpl`, so a reconcile landing inside a fade-in saw
    // `state == .playing && !duckInProgress` and relinquished with
    // `.manuallyResumed` - clearing `_duckedVolume` and putting a false "you
    // resumed it" line in the log, which is the one signal a user is told to
    // trust when auto-pause misbehaves.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake, out: 0, back: 0.3)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)
    fake.resetCalls()

    var reconciledMidFade = false
    fake.volumeSetHook = { [weak adapter] _ in
        guard !reconciledMidFade, let adapter else { return }
        reconciledMidFade = true
        adapter.reconcileSync()
    }

    adapter.restoreSync()
    fake.volumeSetHook = nil

    #expect(reconciledMidFade, "the hook must have run inside the fade-in")
    // The restore does finish and the volume does come back.
    #expect(log.events.contains(.restored), "the restore must still complete")
    #expect(fake.currentVolume == 70)
    #expect(!adapter.isOwned, "the completed restore must release ownership")
    // And it no longer reports a relinquish reason the user never caused: the
    // restore set its own in-progress flag, so our own `play` is not read as
    // the user taking over.
    #expect(log.reasons.isEmpty, "got \(log.reasons)")
}

// MARK: - Reconcile: the user's intent always wins

@Test func reconcileRelinquishesWhenThePlayerQuits() {
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }
    adapter.duckSync(source: "poll")
    fake.pid = nil

    adapter.reconcileSync()
    #expect(log.reasons == [.playerGone])
    #expect(!adapter.isOwned)
    // A dead player must not be "restored" into existence later either.
    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(fake.calls.isEmpty, "restore after playerGone touched Spotify: \(fake.calls)")
}

@Test func reconcileRelinquishesWhenSpotifyRestarts() {
    // A restart (Quit + relaunch) is a new process. Whatever it is playing now
    // is the user's, so we must not touch it - and a reconcile must not wait
    // for the next restore to notice.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }
    adapter.duckSync(source: "poll")

    fake.pid = 9999
    adapter.reconcileSync()
    #expect(log.reasons == [.pidChanged])
    #expect(!adapter.isOwned)

    // And the later restore must not resurrect the old ownership.
    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(fake.calls.isEmpty, "restore after pidChanged touched Spotify: \(fake.calls)")
}

@Test func reconcileRelinquishesOnAManualResume() {
    // Fade mode, which actually pauses: Spotify still reporting "playing" is
    // unambiguous evidence the user did something, so ownership is handed back
    // at once. (In mute-only, "playing" is our own state, so it is *not*
    // evidence of anything - see muteOnlyKeepsOwnershipAcrossAReconcile.)
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake)
    adapter.onEvent = { log.record($0) }
    adapter.duckSync(source: "poll")

    fake.state = .playing  // the user hit play
    fake.resetCalls()
    adapter.reconcileSync()
    #expect(log.reasons == [.manuallyResumed])
    #expect(!fake.calls.contains("play"), "a user-initiated resume must not be re-issued")
    #expect(adapter.isOwned == false)
}

@Test func reconcileRelinquishesOnAUserVolumeChange() {
    // Mid-duck volume nudge while we own a *pause* (fade mode pauses, so
    // "playing" unambiguously means the user acted): the user has taken over
    // the volume, so we give up ownership rather than fight the slider on the
    // next resume.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake)
    adapter.onEvent = { log.record($0) }
    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)
    #expect(fake.state == .paused)

    fake.currentVolume = 42
    adapter.reconcileSync()
    #expect(log.reasons == [.volumeChangedByUser])
    #expect(!adapter.isOwned)
    // Nothing was written while giving up: the user's 42 survives untouched.
    #expect(fake.currentVolume == 42)
    #expect(fake.volumesSet == [0])
}

@Test func reconcileDoesNothingWhenNotOwned() {
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.reconcileSync()
    #expect(fake.calls.isEmpty, "reconcile while unowned talked to Spotify: \(fake.calls)")
    #expect(log.events.isEmpty)
}

@Test func reconcileKeepsOwnershipWhenTheVolumeIsUnreadableAndSpotifyIsPaused() {
    // A nil volume read is a transport problem, not a user action. Treating it
    // as "the volume changed" would relinquish ownership on a flaky AppleEvent
    // and leave Spotify paused forever with nothing left to resume it.
    //
    // Fade-and-pause mode, not mute-only: mute-only is always `.playing`, so it
    // hits the manual-resume branch first and this rule is unreachable there
    // (that is the separate mute-only bug above). Here Spotify is paused
    // because we paused it, so the volume comparison is the only check left -
    // and a nil current volume must not trip it.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake)
    adapter.onEvent = { log.record($0) }
    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)
    #expect(fake.state == .paused)

    fake.volumeUnreadable = true
    adapter.reconcileSync()
    #expect(log.reasons.isEmpty, "an unreadable volume was read as a user change: \(log.reasons)")
    #expect(adapter.isOwned, "a flaky AppleEvent must not end the duck")

    // And the duck is still ours to finish: a restore still resumes.
    fake.volumeUnreadable = false
    fake.resetCalls()
    adapter.restoreSync()
    #expect(fake.calls.contains("play"))
    #expect(!adapter.isOwned)
}

// MARK: - Mode-specific volume rules

@Test func instantModeNeverTouchesTheVolume() {
    // The whole point of instant mode: pause/resume, never a volume write.
    // A stray setVolume here is what made "instant" feel like a glitch, and it
    // would also stomp a volume the user changed between episodes.
    let fake = FakeSpotifyControl()
    let adapter = instantAdapter(fake)
    adapter.duckSync(source: "poll")
    #expect(fake.calls.contains("pause"))
    adapter.restoreSync()
    #expect(fake.calls.contains("play"))
    #expect(fake.volumesSet.isEmpty, "instant mode wrote the volume: \(fake.volumesSet)")
    #expect(fake.currentVolume == 70, "instant mode must leave the volume exactly as found")
}

@Test func instantModeStillOwnsThePauseItMade() {
    // ...and it must still resume only what it paused.
    let fake = FakeSpotifyControl()
    fake.state = .paused
    let adapter = instantAdapter(fake)
    adapter.duckSync(source: "poll")
    #expect(!adapter.isOwned)
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
}

@Test func muteOnlyNeverPlaysOrPauses() {
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = muteOnlyAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(!fake.calls.contains("pause"))
    #expect(!fake.calls.contains("play"))
    #expect(fake.currentVolume == 0)
    #expect(adapter.isOwned)
    // Mute-only never pauses, so playback continues: the "still playing" is
    // ours, not the user's.
    #expect(fake.state == .playing)

    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"), "mute-only must not start playback")
    #expect(fake.currentVolume == 70, "the volume must come back")
    #expect(log.ducks == ["poll"])
    // Mute-only never paused anything, so "playing" is expected and the cycle
    // completes normally: `.restored`, with no invented relinquish reason.
    #expect(log.reasons.isEmpty, "got \(log.reasons)")
    #expect(log.events.contains(.restored))
}

@Test func muteOnlyKeepsOwnershipAcrossAReconcile() {
    // In mute-only mode Spotify is *supposed* to still be playing while we own
    // the volume, so "playing" is our own state and not the user acting. Gating
    // the check on the mode is what stops the music blaring back in the middle
    // of a duck: the controller reconciles on a `.hold` tick, which happens as
    // soon as a single sample drops and the loud streak restarts.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = muteOnlyAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)
    #expect(fake.currentVolume == 0)

    adapter.reconcileSync()
    #expect(log.reasons.isEmpty, "mute-only is read as a manual resume: \(log.reasons)")
    #expect(adapter.isOwned, "a single reconcile must not end the mute-only duck")
    #expect(fake.currentVolume == 0, "the volume is restored while the other app is still loud")
}

@Test func muteOnlyKeepsOwnershipAcrossManyReconciles() {
    // The shape a user actually hits: the engine reconciles twice a second for
    // as long as the other app is loud, so it only takes the *first* reconcile
    // to end the duck if the mode is not considered.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = muteOnlyAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    for _ in 0..<20 { adapter.reconcileSync() }
    #expect(adapter.isOwned, "mute-only must survive every reconcile of the episode")
    #expect(fake.currentVolume == 0, "the music must not blare back mid-episode")
    #expect(log.reasons.isEmpty, "got \(log.reasons)")
}

@Test func muteOnlyReportsAUserVolumeChangeAsAVolumeChange() {
    // KNOWN BUG, one layer over the mute-only reconcile bug. The user moves
    // the slider while muted; the volume *is* preserved (the ownership guard
    // does its job) but the reason recorded is `.manuallyResumed`, because
    // `reconcileImpl` checks the state before it checks the volume and
    // mute-only is always `.playing`.
    //
    // So the two diagnostics the user is given disagree: the log says "you
    // resumed it" when in fact they moved the slider. The intended reason is
    // `.volumeChangedByUser`, and that is what the first expectation becomes
    // once the state check is gated on `mode == .fadeAndPause`.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = muteOnlyAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    fake.currentVolume = 42
    adapter.reconcileSync()
    #expect(log.reasons == [.volumeChangedByUser], "got \(log.reasons)")
    #expect(!adapter.isOwned)
    // The important half still holds: the user's 42 is not clobbered.
    #expect(fake.currentVolume == 42)
}

@Test func fadeModeRestoresTheExactPreDuckVolume() {
    // A distinctive value on purpose: `owned.volume ?? 100` in the restore
    // path means a "100" here would be a clobbered restore, and a test using
    // 70 could not tell the difference.
    let fake = FakeSpotifyControl()
    fake.currentVolume = 55
    let adapter = fadeAdapter(fake, out: 0.2, back: 0.2)
    adapter.duckSync(source: "poll")
    #expect(fake.currentVolume == 0)
    adapter.restoreSync()
    #expect(fake.currentVolume == 55)
    #expect(!adapter.isOwned)
}

@Test func fadeModeRestoresTheExactPreDuckVolumeAtEveryLevel() {
    // A sweep, because the restore path has two branches (the fade and the
    // single-step zero-duration case) and a distinctive value only pins one.
    for volume in [0, 1, 33, 55, 99, 100] {
        let fake = FakeSpotifyControl()
        fake.currentVolume = volume
        let adapter = fadeAdapter(fake, out: 0.2, back: 0.2)
        adapter.duckSync(source: "poll")
        #expect(fake.currentVolume == 0, "pre-duck volume \(volume) was not ducked")
        adapter.restoreSync()
        #expect(fake.currentVolume == volume, "pre-duck volume \(volume) was not restored")
    }
}

@Test func aZeroDurationFadeIsASingleVolumeWriteNotAFade() {
    // fadeOutDuration 0 must jump straight to the target, not divide by zero
    // steps and write nothing.
    let fake = FakeSpotifyControl()
    let adapter = fadeAdapter(fake, out: 0, back: 0)
    adapter.duckSync(source: "poll")
    #expect(fake.volumesSet == [0])
    #expect(fake.calls.contains("pause"))
    adapter.restoreSync()
    #expect(fake.calls.contains("play"))
    #expect(fake.volumesSet == [0, 70])
}

@Test func aFadeStepsDownGraduallyAndNeverOvershoots() {
    // The fade must be monotonic down to the target and stop there, so a
    // volume between steps never goes negative or bounces.
    let fake = FakeSpotifyControl()
    let adapter = fadeAdapter(fake, out: 0.5)
    adapter.duckSync(source: "poll")
    #expect(fake.volumesSet.count > 2, "the fade was a single jump: \(fake.volumesSet)")
    for (index, value) in fake.volumesSet.enumerated() {
        if index > 0 {
            #expect(value <= fake.volumesSet[index - 1], "the fade went up at step \(index)")
        }
        #expect(value >= 0)
    }
    #expect(fake.volumesSet.last == 0)
}

@Test func fadeModeRestoresTheVolumeAfterAManualResumeWithoutReplaying() {
    // The user hit play during the fade: we owe them the volume back, and we
    // must not issue a second play.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake, out: 0.2, back: 0.2)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(fake.state == .paused)
    fake.state = .playing  // the user's own resume
    fake.resetCalls()

    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(fake.currentVolume == 70, "the ducked volume must come back")
    #expect(log.reasons == [.manuallyResumed])
    #expect(!adapter.isOwned)
}

@Test func instantManualResumePreservesAUserVolumeChange() {
    // Instant mode never *writes* the volume, but it must still record what it
    // was: with `_duckedVolume` left nil, `restoreVolumeIfUntouched` cannot
    // tell "the user moved the slider" from "we own the volume" and writes the
    // pre-duck volume back over their change. The user's 42 becomes 70.
    //
    // Scenario: Spotify is at 70, instant mode pauses it, the user changes the
    // volume and presses play. Their choice must survive.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    fake.currentVolume = 42
    fake.state = .playing
    adapter.reconcileSync()

    #expect(log.reasons == [.manuallyResumed])
    #expect(fake.currentVolume == 42, "the user's 42 must survive the interrupt")
}

@Test func aUserPauseBeforeDuckIsNeverResumedLater() {
    // The single most important anti-footgun rule, spelled end to end: the user
    // paused Spotify an hour ago, some other app made a noise, and a full quiet
    // streak must not start the music.
    let fake = FakeSpotifyControl()
    fake.state = .paused
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(!adapter.isOwned)
    #expect(log.events == [.skippedNotPlaying])

    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(fake.state == .paused)
    #expect(log.events == [.skippedNotPlaying], "restore while unowned must be silent")
}

@Test func aUserStopBeforeDuckIsNeverStartedLater() {
    // `stopped` is not `paused`: there is a queue and a play context behind it.
    // Calling play on it would start music the user deliberately ended.
    let fake = FakeSpotifyControl()
    fake.state = .stopped
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(!adapter.isOwned)
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(fake.state == .stopped)
    _ = log
}

@Test func aStoppedSpotifyMidDuckIsNotRestarted() {
    // The user pressed stop (not pause) while we owned the duck. `restoreImpl`
    // has to treat that as theirs.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }
    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)

    fake.state = .stopped
    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"), "a user stop was overwritten with play")
    #expect(fake.state == .stopped)
    #expect(log.reasons == [.manuallyStopped])
    #expect(!adapter.isOwned)
}

@Test func aPlayerThatRestartsMidDuckIsNotResumedInTheNewInstance() {
    // Spotify auto-updates and restarts. The new instance may be playing
    // something else entirely, or not running at all.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = instantAdapter(fake)
    adapter.onEvent = { log.record($0) }
    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)

    fake.pid = 4321
    fake.state = .playing  // the new instance is already playing
    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(!fake.calls.contains("pause"))
    #expect(log.reasons == [.pidChanged])
    #expect(!adapter.isOwned)
}

@Test func relinquishingClearsOwnershipEvenOnTheFailurePath() {
    // Ownership is released on every relinquish reason, so a second duck in the
    // same episode can take a fresh snapshot (and a fresh volume) rather than
    // being short-circuited by a stale one.
    for scenario in [1, 2, 3] {
        let fake = FakeSpotifyControl()
        let log = AdapterEventLog()
        let adapter = instantAdapter(fake)
        adapter.onEvent = { log.record($0) }
        adapter.duckSync(source: "poll")
        #expect(adapter.isOwned, "scenario \(scenario)")

        switch scenario {
        case 1: fake.pid = nil
        case 2: fake.pid = 5555
        default: fake.state = .playing
        }
        adapter.reconcileSync()
        #expect(!adapter.isOwned, "scenario \(scenario) kept ownership")
        #expect(log.reasons.count == 1, "scenario \(scenario): \(log.reasons)")

        // A second duck is a genuine new episode, not a no-op.
        fake.pid = 1234
        fake.state = .playing
        log.reset()
        adapter.duckSync(source: "poll")
        #expect(adapter.isOwned, "scenario \(scenario) could not re-duck")
        #expect(log.ducks == ["poll"], "scenario \(scenario): \(log.ducks)")
    }
}

// MARK: - Generation tokens: a superseded fade must not touch playback

@Test func aSupersededFadeOutStopsAndNeverPauses() {
    // Contrast is the whole test: the same configuration with no supersede
    // fades all the way to 0 and pauses; with a supersede mid-fade the fade
    // stops where it is and playback is left alone.

    // Baseline: nothing supersedes the fade, so it completes and pauses.
    let baselineFake = FakeSpotifyControl()
    let baseline = fadeAdapter(baselineFake, out: 0.3, back: 0.3)
    baseline.duckSync(source: "poll")
    #expect(baselineFake.currentVolume == 0)
    #expect(baselineFake.calls.contains("pause"))
    #expect(baseline.isOwned)

    // Now supersede it from the first fade step. `restore()` bumps the
    // generation synchronously on this thread, so the very next guard in the
    // fade loop sees a stale generation. `pid` is cleared first, before the
    // block is even queued, so the queued restore finds no player and bails
    // out before writing a volume - nothing can interleave with the
    // assertions below. (`fake.calls` is left unread for the same reason: the
    // queued block still appends its pid lookup to it.)
    let fake = FakeSpotifyControl()
    let adapter = fadeAdapter(fake, out: 0.3, back: 0.3)
    var superseded = false
    fake.volumeSetHook = { [weak adapter] _ in
        guard !superseded, let adapter else { return }
        superseded = true
        fake.pid = nil
        adapter.restore()  // bumps the generation; queues a restore that no-ops
    }
    adapter.duckSync(source: "poll")
    fake.volumeSetHook = nil

    #expect(superseded, "the hook must have run inside the fade")
    #expect(
        fake.volumesSet.count == 1,
        "the fade must abort at the first superseded step, wrote \(fake.volumesSet)")
    #expect(!fake.volumesSet.contains(0), "a superseded fade must not reach the target")
    #expect(fake.state == .playing, "a superseded duck must not pause playback")
}

@Test func aSupersededRestorePlaysButDoesNotFadeTheVolumeBack() {
    // Restore path: `play` is issued before the generation is re-checked, so a
    // supersede in that window must still play (the user is owed playback
    // after a quiet streak) but must not start a stale fade-in that would
    // fight whatever the new operation does next.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake, out: 0, back: 0.3)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)
    #expect(fake.currentVolume == 0)
    fake.resetCalls()

    // `reread()` reads the player state right after `play`; that is where a
    // competing operation would bump the generation. The queued duck is a
    // guaranteed no-op because this restore bailed before releasing
    // ownership, so nothing races with the assertions.
    var superseded = false
    fake.rereadHook = { [weak adapter] in
        guard !superseded, let adapter else { return }
        superseded = true
        adapter.duck(source: "rival")
    }

    adapter.restoreSync()
    fake.rereadHook = nil

    #expect(superseded, "the hook must have run inside the restore")
    #expect(fake.calls.contains("play"), "the resume itself must not be cancelled")
    #expect(fake.volumesSet.isEmpty, "a superseded fade-in must not run: \(fake.volumesSet)")
    #expect(fake.currentVolume == 0, "the volume stays where the aborted fade-in left it")
    #expect(log.events == [.ducked(source: "poll")], "a superseded restore must not report .restored")
    #expect(adapter.isOwned, "the early return happens before ownership is released")
}

@Test func aFreshRestoreIsUnaffectedByGenerationBookkeeping() {
    // Control case for the test above: with nothing superseding it, the very
    // same setup fades the volume back and releases ownership.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake, out: 0, back: 0.2)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    adapter.restoreSync()
    #expect(fake.currentVolume == 70)
    #expect(log.events == [.ducked(source: "poll"), .restored])
    #expect(!adapter.isOwned)
}

@Test func manyDucksAndRestoresInARowLeaveNoStaleState() {
    // Ten episodes back to back, each fully completed, must leave the adapter
    // exactly where one episode would: not owned, volume at the pre-duck value,
    // and no leftover generation effect. This is what a long video session
    // looks like, and it is where an off-by-one in the generation bookkeeping
    // would show up as "the third episode does nothing".
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake, out: 0.1, back: 0.1)
    adapter.onEvent = { log.record($0) }

    for episode in 1...10 {
        adapter.duckSync(source: "poll")
        #expect(adapter.isOwned, "episode \(episode) did not take ownership")
        #expect(fake.currentVolume == 0, "episode \(episode) did not duck")
        adapter.restoreSync()
        #expect(!adapter.isOwned, "episode \(episode) kept ownership")
        #expect(fake.currentVolume == 70, "episode \(episode) did not restore")
    }
    #expect(log.ducks.count == 10)
    #expect(log.reasons.isEmpty, "\(log.reasons)")
}

@Test func aDuckAfterARestoreCanBeSupersededWithoutLosingThePause() {
    // The generation is shared across all four operations, so a queued duck
    // must not be able to cancel a *completed* duck's ownership bookkeeping.
    let fake = FakeSpotifyControl()
    let log = AdapterEventLog()
    let adapter = fadeAdapter(fake, out: 0, back: 0)
    adapter.onEvent = { log.record($0) }

    adapter.duckSync(source: "poll")
    adapter.restoreSync()
    #expect(!adapter.isOwned)
    #expect(log.events == [.ducked(source: "poll"), .restored])

    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)
    #expect(fake.state == .paused)
    adapter.restoreSync()
    #expect(!adapter.isOwned)
    #expect(fake.state == .playing)
}

// MARK: - One AppleEvent instead of two

/// A control that declares the batched `stateAndVolume`, the way
/// `AppleScriptSpotifyControl` does on the real machine.
private final class BatchedControl: SpotifyControl, @unchecked Sendable {
    var state: SpotifyPlayerState = .playing
    var pid: pid_t? = 1234
    var batchedCalls = 0
    var separateCalls = 0
    var volumeReads = 0

    func playerState() -> SpotifyPlayerState? {
        separateCalls += 1
        return state
    }

    func volume() -> Int? {
        volumeReads += 1
        return 70
    }

    func setVolume(_ value: Int) {}
    func play() { state = .playing }
    func pause() { state = .paused }
    func spotifyPID() -> pid_t? { pid }

    func stateAndVolume() -> (state: SpotifyPlayerState?, volume: Int?) {
        batchedCalls += 1
        return (state, 70)
    }
}

@Test func stateAndVolumeIsDispatchedThroughTheExistential() {
    // `stateAndVolume()` must be reachable through `any SpotifyControl`. As a
    // protocol *extension* default it was statically dispatched, so the
    // one-round-trip implementation was dead code and every duck and restore
    // paid two AppleEvents where the code's own comment claims one - the
    // "instant" vs "noticeably late" gap.
    let control = BatchedControl()
    let adapter = SpotifyFadeAdapter(control: control, mode: .instant)
    adapter.rereadDelay = 0
    adapter.duckSync(source: "poll")

    #expect(control.batchedCalls == 1, "the batched reader must run through the existential")
    #expect(control.separateCalls == 0, "the two-read default ran instead: \(control.separateCalls)")
    #expect(control.volumeReads == 0)
}

@Test func theBatchedReaderIsUsedWhenTheControlIsHeldConcretely() {
    // Control case for the test above: the same method *does* dispatch when
    // the static type is the concrete type, which is what makes the missing
    // protocol requirement (and not a broken override) the cause.
    let control = BatchedControl()
    let (state, volume) = control.stateAndVolume()
    #expect(control.batchedCalls == 1)
    #expect(control.separateCalls == 0)
    #expect(state == .playing)
    #expect(volume == 70)
}

@Test func anUnknownStateIsRefusedRatherThanTreatedAsPlaying() {
    // `.unknown` is what a transport failure parses to. It must never be
    // treated as "playing, so duck it" - taking ownership on an unreadable
    // state is how a resume we cannot verify gets issued.
    let control = BatchedControl()
    control.state = .unknown
    let adapter = SpotifyFadeAdapter(control: control, mode: .instant)
    adapter.rereadDelay = 0
    adapter.onEvent = { _ in }
    adapter.duckSync(source: "poll")
    #expect(!adapter.isOwned, "an unknown state must not be treated as playing")
    adapter.restoreSync()
    #expect(control.state == .unknown, "no play command was issued")
}
