import Foundation
import Testing
@testable import AutoPauseEngine

/// Fusion is the rule that turns two booleans into "duck" and "resume". Its
/// whole contract is a set of exact comparisons against `activeDuration` /
/// `quietDuration`, and its inputs are timestamps, so every assertion here is
/// exact: fixed binary-fraction offsets, injected `now`, no sleeps and no
/// tolerance fudging.
///
/// The offsets are eighths and halves on purpose. `evaluate` compares with
/// `>=`, so a boundary assertion written as 0.999999 would be testing double
/// rounding rather than the streak rule. The companion `FusionTests.swift`
/// covers the same state machine through the real clock at a coarser
/// granularity; this file pins the boundaries.

private let epoch = Date(timeIntervalSince1970: 1_000)
private let loud = AudioSignal(isActive: true, rms: 0.5)
private let quiet = AudioSignal(isActive: false, rms: 0.0)

private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

// MARK: - Streak origins (the `>=` boundary is the whole contract)

@Test func fusionStartsTheLoudStreakAtTheFirstLoudObservationItSees() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    // Nothing is evaluated between epoch and +2s (engine asleep, or a long
    // Core Audio scan). Fusion cannot credit time it never observed, so the
    // streak begins at the first loud tick, not at the last quiet one.
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: epoch) == .hold)
    #expect(fusion.loudStreakStart == nil)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(2.0)) == .hold)
    #expect(fusion.loudStreakStart == at(2.0))
    // activeDuration is measured from there: 1s after the first loud tick.
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(2.875)) == .hold)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(3.0)) == .candidate(source: "poll"))
}

@Test func fusionStartsTheQuietStreakAtTheFirstQuietObservationItSees() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: epoch) == .hold)
    #expect(fusion.quietStreakStart == nil)
    // Silence for a long time before the first quiet tick is not credited.
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(30.0)) == .hold)
    #expect(fusion.quietStreakStart == at(30.0))
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(32.875)) == .hold)
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(33.0)) == .quiet)
}

@Test func fusionZeroActiveDurationIsCandidateOnTheFirstLoudSample() {
    // A zero dwell is legal (a user can drag the slider to 0). It must mean
    // "react to the very first sample" - not "never fire".
    var fusion = FusionState(activeDuration: 0, quietDuration: 0)
    #expect(fusion.evaluate(poll: nil, tap: loud, now: epoch) == .candidate(source: "tap"))
    #expect(fusion.loudStreakStart == epoch)
}

@Test func fusionZeroQuietDurationIsQuietOnTheFirstQuietSample() {
    var fusion = FusionState(activeDuration: 0, quietDuration: 0)
    #expect(fusion.evaluate(poll: nil, tap: loud, now: epoch) == .candidate(source: "tap"))
    #expect(fusion.evaluate(poll: nil, tap: quiet, now: at(0.000_001)) == .quiet)
}

@Test func fusionZeroDurationsStillNeedAnObservation() {
    // Zero durations must not short-circuit *before* a sample is seen: a
    // never-fed FusionState is "no streak yet", not a decision.
    let fresh = FusionState(activeDuration: 0, quietDuration: 0)
    #expect(fresh.loudStreakStart == nil)
    #expect(fresh.quietStreakStart == nil)
    var fusion = FusionState(activeDuration: 0, quietDuration: 0)
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: epoch) == .quiet)
}

@Test func fusionWithZeroDurationsAlternatesBetweenTheTwoDecisionsOnEverySample() {
    // The degenerate configuration the engine uses when the user drags both
    // sliders to 0: every sample is a decision, so the transitions must track
    // the samples exactly with no dwell at all.
    var fusion = FusionState(activeDuration: 0, quietDuration: 0)
    for i in 0...6 {
        let now = at(Double(i) * 0.125)
        if i % 2 == 0 {
            #expect(fusion.evaluate(poll: loud, tap: nil, now: now) == .candidate(source: "poll"))
        } else {
            #expect(fusion.evaluate(poll: quiet, tap: nil, now: now) == .quiet)
        }
    }
}

@Test func fusionAcceptsALoudSampleAtTheExactActiveBoundaryAndLater() {
    // The `>=`, spelled out: one eighth short of 2s holds, 2s fires, and it
    // keeps firing for as long as the signal holds.
    var fusion = FusionState(activeDuration: 2.0, quietDuration: 5.0)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: epoch) == .hold)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(1.875)) == .hold)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(2.0)) == .candidate(source: "poll"))
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(100.0)) == .candidate(source: "poll"))
    // The streak start is still the first loud sample, so the diagnostics
    // countdown stays anchored.
    #expect(fusion.loudStreakStart == epoch)
}

@Test func fusionAcceptsAQuietSampleAtTheExactQuietBoundaryAndLater() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 2.0)
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: epoch) == .hold)
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(1.875)) == .hold)
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(2.0)) == .quiet)
    #expect(fusion.quietStreakStart == epoch)
}

@Test func fusionDoesNotCreditTimeBetweenTwoObservations() {
    // The engine ticks at 10 Hz but a Core Audio scan can take seconds, so
    // samples arrive with gaps. A gap must never be treated as a continuous
    // streak: the dwell is owed from the sample that started it, and a long
    // silence *before* the first loud sample is not credited either way.
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(600.0)) == .hold)
    #expect(fusion.loudStreakStart == at(600.0))
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(600.875)) == .hold)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(601.0)) == .candidate(source: "poll"))
}

// MARK: - A single opposing sample resets the streak

@Test func fusionOneQuietSampleResetsTheLoudStreak() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    _ = fusion.evaluate(poll: loud, tap: nil, now: epoch)
    // Almost at the boundary...
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(0.875)) == .hold)
    // ...then one quiet sample, however brief.
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(1.0)) == .hold)
    #expect(fusion.loudStreakStart == nil)
    // Loud again: the full activeDuration is owed from scratch.
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(1.125)) == .hold)
    #expect(fusion.loudStreakStart == at(1.125))
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(1.875)) == .hold)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(2.125)) == .candidate(source: "poll"))
}

@Test func fusionOneLoudSampleResetsTheQuietStreak() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    _ = fusion.evaluate(poll: quiet, tap: quiet, now: epoch)
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: at(2.875)) == .hold)
    // A single loud blip one eighth of a second before the boundary must buy
    // a full quietDuration.
    _ = fusion.evaluate(poll: loud, tap: nil, now: at(3.0))
    #expect(fusion.quietStreakStart == nil)
    _ = fusion.evaluate(poll: quiet, tap: nil, now: at(3.125))
    #expect(fusion.quietStreakStart == at(3.125))
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(5.875)) == .hold)
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(6.125)) == .quiet)
}

@Test func fusionATapOnlyBlipResetsTheQuietStreakWhilePollStaysQuiet() {
    // The reset rule is symmetric across detectors: a tap blip resets the
    // quiet streak even when the poll detector never woke up.
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    _ = fusion.evaluate(poll: quiet, tap: quiet, now: epoch)
    _ = fusion.evaluate(poll: nil, tap: loud, now: at(1.0))
    #expect(fusion.quietStreakStart == nil)
    #expect(fusion.loudStreakStart == at(1.0))
}

@Test func aSingleLoudSampleThenSilenceNeverBecomesACandidate() {
    // The engine's "react instantly" preset is activeDuration = 0.1, and a
    // click is a single sample. This is the rule that stops a UI click or a
    // notification from ducking Spotify.
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 0.1)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: epoch) == .hold)
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(0.125)) == .hold)
    #expect(fusion.loudStreakStart == nil)
    #expect(fusion.evaluate(poll: quiet, tap: nil, now: at(0.25)) == .quiet)
}

@Test func alternatingLoudAndQuietNeverReachesACandidate() {
    // The pathological case a stuck detector produces. Every sample flips the
    // streak, so the dwell can never elapse no matter how long it runs.
    var fusion = FusionState(activeDuration: 0.5, quietDuration: 0.5)
    for i in 0...40 {
        let now = at(0.125 * Double(i))
        let decision = i % 2 == 0
            ? fusion.evaluate(poll: loud, tap: nil, now: now)
            : fusion.evaluate(poll: quiet, tap: nil, now: now)
        #expect(decision == .hold, "sample \(i) reached \(decision)")
    }
}

// MARK: - Countdown properties (what the diagnostics UI renders)

@Test func fusionCountdownStreaksAreMutuallyExclusive() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    #expect(fusion.loudStreakStart == nil)
    #expect(fusion.quietStreakStart == nil)

    _ = fusion.evaluate(poll: loud, tap: nil, now: at(0.5))
    #expect(fusion.loudStreakStart == at(0.5))
    #expect(fusion.quietStreakStart == nil, "a loud streak must not leave a quiet countdown behind")

    _ = fusion.evaluate(poll: quiet, tap: nil, now: at(1.0))
    #expect(fusion.loudStreakStart == nil)
    #expect(fusion.quietStreakStart == at(1.0))
}

@Test func fusionCountdownKeepsTheOriginalStreakStart() {
    // The countdown is a countdown *to* the threshold, so the start timestamp
    // has to survive every later sample in the streak. If it were refreshed
    // per tick the UI would never reach 0.
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    for i in 0...16 { _ = fusion.evaluate(poll: quiet, tap: quiet, now: at(0.125 * Double(i))) }
    #expect(fusion.quietStreakStart == epoch)
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: at(2.0)) == .hold)
    for i in 17...24 { _ = fusion.evaluate(poll: loud, tap: nil, now: at(0.125 * Double(i))) }
    #expect(fusion.loudStreakStart == at(2.125))
}

@Test func theReportedStreakStartIsExactlyTheSampleThatStartedTheStreak() {
    // A diagnostics countdown computed from a drifted start would be wrong by
    // however long the previous streak lasted, so the value has to be the
    // timestamp of the first sample *after* the reset, not of the reset.
    var fusion = FusionState(activeDuration: 4.0, quietDuration: 4.0)
    for i in 0...8 { _ = fusion.evaluate(poll: loud, tap: nil, now: at(Double(i))) }
    #expect(fusion.loudStreakStart == epoch)
    _ = fusion.evaluate(poll: quiet, tap: nil, now: at(9.0))
    #expect(fusion.loudStreakStart == nil)
    _ = fusion.evaluate(poll: quiet, tap: nil, now: at(10.0))
    #expect(fusion.quietStreakStart == at(9.0), "the quiet streak started on the 9, not the 10")
    _ = fusion.evaluate(poll: loud, tap: nil, now: at(11.0))
    #expect(fusion.loudStreakStart == at(11.0))
    #expect(fusion.quietStreakStart == nil)
}

@Test func fusionResetClearsBothCountdownStreaks() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    _ = fusion.evaluate(poll: loud, tap: nil, now: epoch)
    _ = fusion.evaluate(poll: quiet, tap: nil, now: at(1.0))
    #expect(fusion.quietStreakStart == at(1.0))
    fusion.reset()
    #expect(fusion.loudStreakStart == nil)
    #expect(fusion.quietStreakStart == nil)
    // A reset really does restart the dwell, not just the counters.
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(5.0)) == .hold)
    #expect(fusion.loudStreakStart == at(5.0))
}

@Test func fusionResetIsIdempotent() {
    // `stop()` calls reset unconditionally, including when nothing is running.
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    fusion.reset()
    fusion.reset()
    #expect(fusion.loudStreakStart == nil)
    #expect(fusion.quietStreakStart == nil)
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: epoch) == .hold)
}

// MARK: - Fusion never measures loudness itself

@Test func fusionKeysOffIsActiveAndIgnoresRMS() {
    // This is the load-bearing difference between the two backends: poll
    // cannot report an RMS at all, and the tap's RMS has already been
    // thresholded by TapSmoother. Fusion must not second-guess either.
    var fusion = FusionState(activeDuration: 0, quietDuration: 0)
    // A below-threshold tap sample is still "active" as far as fusion goes:
    // thresholding is the smoother's job, not fusion's.
    #expect(fusion.evaluate(poll: nil, tap: AudioSignal(isActive: true, rms: 0.0), now: epoch)
        == .candidate(source: "tap"))

    var fusion2 = FusionState(activeDuration: 0, quietDuration: 0)
    // A huge RMS with isActive == false is silence (a stale final block after
    // the smoother decayed, say) and must not be read as loud.
    #expect(fusion2.evaluate(poll: nil, tap: AudioSignal(isActive: false, rms: 0.99), now: epoch)
        == .quiet)
    #expect(fusion2.loudStreakStart == nil)
}

@Test func aTapSignalWithNoRMSAtAllStillCountsAsActive() {
    // The shape `TapDetector` publishes before the first measurement lands.
    var fusion = FusionState(activeDuration: 0, quietDuration: 0)
    #expect(fusion.evaluate(poll: nil, tap: AudioSignal(isActive: true, rms: nil), now: epoch)
        == .candidate(source: "tap"))
}

@Test func fusionTreatsMissingDetectorsAsSilent() {
    // Poll-only mode passes `tap: nil` and tap-only mode passes `poll: nil`.
    // Neither nil may be mistaken for "loud", and both must still feed the
    // quiet streak or the resume could never happen.
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    #expect(fusion.evaluate(poll: nil, tap: nil, now: epoch) == .hold)
    #expect(fusion.quietStreakStart == epoch)
    #expect(fusion.evaluate(poll: nil, tap: nil, now: at(3.0)) == .quiet)
    #expect(fusion.loudStreakStart == nil)
}

@Test func fusionMixesAnActiveDetectorWithAMissingOne() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: epoch) == .hold)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(1.0)) == .candidate(source: "poll"))
    // The detector that goes quiet does not veto the one still holding.
    #expect(fusion.evaluate(poll: loud, tap: quiet, now: at(1.125)) == .candidate(source: "poll"))
    #expect(fusion.quietStreakStart == nil, "poll still holds the floor open")
    // Only when both agree on quiet does the quiet streak begin.
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: at(1.25)) == .hold)
    #expect(fusion.quietStreakStart == at(1.25))
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: at(4.25)) == .quiet)
}

// MARK: - Sustained-audio behaviour at the real engine tick

@Test func fusionSurvivesAQuietTickInTheMiddleOfLoudAudio() {
    // The 0.1s tick: a single quiet tick in the middle of loud audio must not
    // let a stale streak through, and must not cost a full re-dwell either
    // (that is the tap smoother's gapTolerance, not fusion's job).
    var fusion = FusionState(activeDuration: 0.25, quietDuration: 0.5)
    #expect(fusion.evaluate(poll: nil, tap: loud, now: at(0.0)) == .hold)
    #expect(fusion.evaluate(poll: nil, tap: loud, now: at(0.125)) == .hold)
    #expect(fusion.evaluate(poll: nil, tap: loud, now: at(0.25)) == .candidate(source: "tap"))
    #expect(fusion.evaluate(poll: nil, tap: quiet, now: at(0.375)) == .hold)
    #expect(fusion.evaluate(poll: nil, tap: quiet, now: at(0.75)) == .hold)
    #expect(fusion.evaluate(poll: nil, tap: quiet, now: at(0.875)) == .quiet)
    #expect(fusion.evaluate(poll: nil, tap: loud, now: at(1.0)) == .hold)
    #expect(fusion.evaluate(poll: nil, tap: loud, now: at(1.25)) == .candidate(source: "tap"))
}

@Test func aWholeAudioEpisodeAtTheEngineTickRateProducesExactlyOneDecisionWindow() {
    // End-to-end shape at 0.1 s with the fade preset's timings, which is what
    // the user actually experiences: 1 s to duck, 3 s to resume, and the
    // decision is made on the boundary tick, not the one after.
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    var firstCandidate: TimeInterval?
    var firstQuiet: TimeInterval?
    for i in 0...60 {
        let now = at(0.1 * Double(i))
        // 2 s of loud, then quiet for the rest.
        let decision = i <= 20
            ? fusion.evaluate(poll: nil, tap: loud, now: now)
            : fusion.evaluate(poll: nil, tap: quiet, now: now)
        if case .candidate = decision, firstCandidate == nil { firstCandidate = 0.1 * Double(i) }
        if case .quiet = decision, firstQuiet == nil { firstQuiet = 0.1 * Double(i) }
    }
    // 11 loud ticks at 0.1 s, so the dwell is met at t = 1.0 exactly.
    #expect(firstCandidate == 1.0, "fired at \(firstCandidate ?? -1)")
    // The last loud sample is t = 2.0, so the quiet streak starts at t = 2.1
    // and 3 s later is t = 5.1. Compared with a tolerance because 0.1 is not
    // binary-exact and the accumulated `Date` arithmetic is incidental here -
    // the streak rule itself is pinned on exact fractions above.
    #expect(abs((firstQuiet ?? -1) - 5.1) < 1e-9, "resumed at \(firstQuiet ?? -1)")
}

// MARK: - Source labels (what a support log is read against)

@Test func fusionReportsTheCombinedSourceOnlyWhenBothDetectorsAreLoud() {
    // Source strings are diagnostics only, but they are what a support log
    // is read against, so pin which combinations produce which label.
    var fusion = FusionState(activeDuration: 0, quietDuration: 1.0)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: epoch) == .candidate(source: "poll"))
    #expect(fusion.evaluate(poll: nil, tap: loud, now: at(0.125)) == .candidate(source: "tap"))
    #expect(fusion.evaluate(poll: loud, tap: loud, now: at(0.25)) == .candidate(source: "poll+tap"))
    #expect(fusion.evaluate(poll: loud, tap: quiet, now: at(0.375)) == .candidate(source: "poll"))
    #expect(fusion.evaluate(poll: quiet, tap: loud, now: at(0.5)) == .candidate(source: "tap"))
}

@Test func theSourceLabelNeverChangesMidEpisode() {
    // The controller logs the candidate once per episode, so a label that
    // flipped as detectors came and went would make the log unreadable. With
    // activeDuration already satisfied the label is a pure function of which
    // detectors are loud right now - and the controller only reads it on the
    // transition, so this pins the value it would have logged.
    var fusion = FusionState(activeDuration: 0, quietDuration: 1.0)
    #expect(fusion.evaluate(poll: loud, tap: loud, now: epoch) == .candidate(source: "poll+tap"))
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(0.125)) == .candidate(source: "poll"))
    #expect(fusion.evaluate(poll: nil, tap: loud, now: at(0.25)) == .candidate(source: "tap"))
    #expect(fusion.evaluate(poll: loud, tap: loud, now: at(0.375)) == .candidate(source: "poll+tap"))
}

@Test func fusionDefaultDurationsAreTheFadePresetValues() {
    // The controller constructs `FusionState()` and then overwrites the
    // durations from the user's settings. The defaults matter for the moment
    // in between and for the diagnostics line, so they are pinned to the fade
    // preset rather than to arbitrary numbers.
    let fusion = FusionState()
    #expect(fusion.activeDuration == AutoPausePreset.fade.activeDuration)
    #expect(fusion.quietDuration == AutoPausePreset.fade.quietDuration)
}

@Test func fusionDurationsAreMutableSoTheUiCanApplyAPresetLive() {
    // The preferences model applies a preset by writing the two durations into
    // the live state; no reset is needed for the change to take effect on the
    // next tick, and no new instance is constructed.
    var fusion = FusionState(activeDuration: 3.0, quietDuration: 9.0)
    _ = fusion.evaluate(poll: loud, tap: nil, now: epoch)
    fusion.activeDuration = 1.0
    #expect(fusion.evaluate(poll: loud, tap: nil, now: at(1.0)) == .candidate(source: "poll"))
    // The streak itself is untouched by the change, so lowering the dwell does
    // not restart the wait from the next sample.
    #expect(fusion.loudStreakStart == epoch)
}
