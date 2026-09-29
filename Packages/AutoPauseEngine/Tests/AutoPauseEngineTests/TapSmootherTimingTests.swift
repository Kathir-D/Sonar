import Foundation
import Testing
@testable import AutoPauseEngine

/// `TapSmoother` is the tap's own active/gap state machine, and it is the only
/// place where an RMS level becomes a boolean. Its arithmetic is exact
/// (`>=` for the threshold and the dwell, `>` for the gap reset), so these
/// tests use injected timestamps at binary-exact offsets rather than a real
/// clock.
///
/// The distinction it exists to draw: a dip in the signal shorter than
/// `gapTolerance` must not end an episode. Without it, the engine's 0.1 s tick
/// straddling a syllable boundary would drop Spotify for a few hundred
/// milliseconds and then re-duck it, which is audible and worse than not
/// reacting at all.

private let t0 = Date(timeIntervalSince1970: 2_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Below the default 0.02 threshold.
private let silence: Float = 0
/// Comfortably above the default 0.02 threshold.
private let loud: Float = 0.5

/// The default config, with named overrides for the two durations that the
/// tests vary.
private func smoother(
    threshold: Float = 0.02,
    activeDuration: TimeInterval = 1.0,
    gapTolerance: TimeInterval = 0.75
) -> TapSmoother {
    TapSmoother(
        config: TapConfig(
            threshold: threshold, activeDuration: activeDuration, gapTolerance: gapTolerance))
}

// MARK: - Threshold comparison

@Test func smootherCountsASampleExactlyAtTheThresholdAsLoud() {
    // `>=` not `>`: a signal sitting exactly on the slider value must count,
    // otherwise raising the threshold by one notch silently does nothing.
    // Separate smoothers, because a below-threshold sample *inside* the gap
    // tolerance is absorbed rather than treated as quiet (see the gap tests).
    var atThreshold = smoother(activeDuration: 0)
    #expect(atThreshold.sample(rms: 0.02, at: t0) == true)

    var justBelow = smoother(activeDuration: 0)
    #expect(justBelow.sample(rms: 0.0199, at: t0) == false)
}

@Test func smootherAppliesEachPresetsThresholdToRealLevels() {
    // The presets ship two thresholds (0.01 and 0.02). Both have to separate a
    // real room from digital silence, and both have to stay far enough below a
    // normal listening level to fire on a quiet video.
    for preset in AutoPausePreset.allCases {
        var noise = smoother(threshold: preset.threshold, activeDuration: 0)
        let hearsSilence = noise.sample(rms: 0, at: t0)
        #expect(hearsSilence == false, "\(preset.rawValue) treats digital silence as loud")
        var quietSound = smoother(threshold: preset.threshold, activeDuration: 0)
        let hearsQuiet = quietSound.sample(rms: 0.02, at: t0)
        #expect(hearsQuiet, "\(preset.rawValue) cannot hear a quiet sound")
        var music = smoother(threshold: preset.threshold, activeDuration: 0)
        let hearsMusic = music.sample(rms: 0.3, at: t0)
        #expect(hearsMusic, "\(preset.rawValue) cannot hear music")
    }
}

@Test func smootherZeroThresholdTreatsDigitalSilenceAsLoud() {
    // Documented footgun for a UI slider: threshold 0 means "always loud",
    // because -0.0 >= 0.0. The smoother must at least be self-consistent
    // (loud, then "quiet" is impossible because there is no below-0 sample
    // other than the reevaluate sentinel).
    var zero = smoother(threshold: 0, activeDuration: 0)
    #expect(zero.sample(rms: 0, at: t0) == true)
    // The reevaluate sentinel is negative, so a 0 threshold still decays.
    #expect(zero.reevaluate(at: at(10.0)) == false)
}

@Test func aNegativeThresholdIsAlsoAlwaysLoud() {
    // Same footgun one notch further, and reachable if the UI ever subtracts
    // from the threshold instead of clamping.
    var negative = smoother(threshold: -0.5, activeDuration: 0)
    #expect(negative.sample(rms: 0, at: t0) == true)
}

@Test func smootherActiveDurationIsInclusiveAtItsBoundary() {
    var a = smoother()
    #expect(a.sample(rms: loud, at: t0) == false)
    #expect(a.sample(rms: loud, at: at(0.875)) == false)
    #expect(a.sample(rms: loud, at: at(1.0)) == true)
}

@Test func smootherActiveDurationIsMeasuredFromTheFirstLoudSampleNotTheLast() {
    // The dwell is a sustained-loudness requirement, so it starts when the
    // sound starts. A long silence before the first sample must not count.
    var a = smoother()
    #expect(a.sample(rms: loud, at: at(300.0)) == false)
    #expect(a.sample(rms: loud, at: at(300.875)) == false)
    #expect(a.sample(rms: loud, at: at(301.0)) == true)
}

@Test func smootherZeroActiveDurationActivatesOnTheFirstLoudSample() {
    var a = smoother(activeDuration: 0)
    #expect(a.sample(rms: loud, at: t0) == true)
}

@Test func theInstantPresetsActiveDurationActivatesWithinOneEngineTick() {
    // "Instant" promises the configured value is the felt latency. The engine
    // ticks at 0.1 s, so a 0.1 s dwell has to fire on the second tick at the
    // latest - not on the third.
    var a = smoother(activeDuration: AutoPausePreset.instant.activeDuration)
    #expect(a.sample(rms: loud, at: t0) == false)
    #expect(a.sample(rms: loud, at: at(0.1)) == true)
}

// MARK: - Gap tolerance

@Test func smootherGapToleranceIsInclusiveAtItsBoundary() {
    // A dip of exactly gapTolerance still counts as the same burst; one
    // eighth longer ends it. The asymmetry (`>` for the reset, `<=` for the
    // guard) is what makes the boundary inclusive.
    var a = smoother(activeDuration: 0)
    #expect(a.sample(rms: loud, at: t0) == true)
    #expect(a.sample(rms: silence, at: at(0.75)) == true)
    #expect(a.sample(rms: loud, at: at(0.875)) == true)

    var gapTooLong = smoother(activeDuration: 0)
    #expect(gapTooLong.sample(rms: loud, at: t0) == true)
    #expect(gapTooLong.sample(rms: silence, at: at(0.875)) == false)
    // And the streak owes the full activeDuration again.
    #expect(gapTooLong.sample(rms: loud, at: at(1.0)) == true)
}

@Test func aShortGapDoesNotRefundTheDwellAlreadyServed() {
    // The two rules interact: a dip inside the tolerance keeps the episode
    // alive, and the dwell it already served still counts. If a gap restarted
    // the dwell, a sound with a pause in it would never trigger.
    var a = smoother()
    #expect(a.sample(rms: loud, at: t0) == false)
    #expect(a.sample(rms: loud, at: at(0.5)) == false)
    #expect(a.sample(rms: silence, at: at(0.625)) == false, "inside the gap: still the same burst")
    #expect(a.sample(rms: loud, at: at(1.0)) == true, "the dwell was served before the dip")
}

@Test func aGapLongerThanTheToleranceRefundsTheWholeDwell() {
    // The inverse, and the one that matters for a transient: a single loud
    // blip that is over by the next tick must not count as an episode.
    var a = smoother()
    #expect(a.sample(rms: loud, at: t0) == false)
    #expect(a.sample(rms: silence, at: at(0.875)) == false)
    #expect(a.sample(rms: loud, at: at(1.0)) == false, "the dwell was refunded by the gap")
    #expect(a.sample(rms: loud, at: at(2.0)) == true)
}

@Test func smootherReevaluateWithinTheGapKeepsTheBurstAlive() {
    // The quiet-check timer runs at quietCheckInterval (0.1 s) whether or not
    // audio arrives, so most "quiet samples" are actually reevaluate ticks.
    var a = smoother(activeDuration: 0)
    #expect(a.sample(rms: loud, at: t0) == true)
    for i in 1...6 { #expect(a.reevaluate(at: at(0.125 * Double(i))) == true) }
    // Past the gap it decays even though no new audio ever arrived.
    #expect(a.reevaluate(at: at(1.0)) == false)
}

@Test func smootherReevaluateNeverInventsLoudness() {
    // reevaluate feeds a negative RMS, so it must be unable to start a streak
    // on a tap that has never seen sound. This is the state a tap sits in
    // between starting and the first real buffer arriving.
    var a = smoother()
    #expect(a.reevaluate(at: t0) == false)
    #expect(a.reevaluate(at: at(60.0)) == false)
}

@Test func smootherReevaluateOnAFreshSmootherStaysInactive() {
    var a = smoother()
    for i in 0...40 { #expect(a.reevaluate(at: at(0.25 * Double(i))) == false) }
}

@Test func aZeroGapToleranceStillActivatesOnConsecutiveLoudSamples() {
    // gapTolerance 0 means "no dip is forgiven", which for a continuous signal
    // means every sample must be loud. Two loud samples one tick apart are
    // still one streak.
    var a = smoother(gapTolerance: 0)
    #expect(a.sample(rms: loud, at: t0) == false)
    #expect(a.sample(rms: loud, at: at(0.125)) == false)
    #expect(a.sample(rms: loud, at: at(1.0)) == true)
    // One silent tick at the same timestamp ends it immediately.
    var b = smoother(gapTolerance: 0)
    #expect(b.sample(rms: loud, at: t0) == false)
    #expect(b.sample(rms: silence, at: at(0.125)) == false)
    #expect(b.sample(rms: loud, at: at(1.0)) == false)
}

// MARK: - An episode, start to finish

@Test func aWholeEpisodeAtTheEngineTickRate() {
    // 1 s of dwell at a 0.1 s tick, a 0.4 s dip, then 3 s of quiet: the
    // smoother must stay active across the dip and fall exactly gapTolerance
    // after the last loud sample.
    var a = smoother()
    var activations: [TimeInterval] = []
    for i in 0...80 {
        let now = at(0.1 * Double(i))
        let t = 0.1 * Double(i)
        let rms: Float = (t < 1.0 || (t >= 1.4 && t < 6.0)) ? loud : silence
        if a.sample(rms: rms, at: now) { activations.append(t) }
    }
    // Loud from t=0, so the dwell is met at t=1.0 and stays met. The dip
    // (t=1.0...1.3) is 0.4 s, inside the 0.75 s gap, so it does not end the
    // burst. The last loud sample is t=5.9, and the gap expires 0.75 s later,
    // i.e. the first inactive sample is t=6.7 and the last active one t=6.6.
    #expect(abs((activations.first ?? -1) - 1.0) < 1e-9, "activated at \(activations.first ?? -1)")
    #expect(abs((activations.last ?? -1) - 6.6) < 1e-9, "deactivated after \(activations.last ?? -1)")
    #expect(activations.count == 57, "\(activations.count) active samples: \(activations)")
}

@Test func theSmootherDecaysOnItsOwnWithNoAudioAtAllArriving() {
    // The quiet-check timer is the only thing that can end an episode when the
    // other app simply stops, so decay must not depend on another buffer.
    var a = smoother(activeDuration: 0)
    #expect(a.sample(rms: loud, at: t0) == true)
    #expect(a.reevaluate(at: at(0.75)) == true)
    #expect(a.reevaluate(at: at(0.875)) == false)
}

// MARK: - Config is live (the detector writes it from its own queue)

@Test func smootherPicksUpAThresholdChangeWithoutRebuilding() {
    // `TapDetector.config.didSet` assigns `smoother.config` in place, so a
    // slider change takes effect without restarting the tap. If the smoother
    // cached its threshold instead, a raised threshold would not silence an
    // already-loud signal until the next rebuild.
    var a = smoother(activeDuration: 0)
    #expect(a.sample(rms: 0.05, at: t0) == true)
    a.config.threshold = 0.5
    // Sampled well past the gap, so the old burst is properly discarded and
    // the new threshold is what decides.
    #expect(a.sample(rms: 0.05, at: at(1.0)) == false)
    #expect(a.sample(rms: 0.75, at: at(1.125)) == true)
}

@Test func smootherPicksUpAnActiveDurationChange() {
    var a = smoother(activeDuration: 5.0)
    #expect(a.sample(rms: loud, at: t0) == false)
    a.config.activeDuration = 0.5
    #expect(a.sample(rms: loud, at: at(0.5)) == true)
}

@Test func smootherPicksUpAGapToleranceChange() {
    var a = smoother(activeDuration: 0, gapTolerance: 0.75)
    #expect(a.sample(rms: loud, at: t0) == true)
    a.config.gapTolerance = 0.125
    // Well past the new gap: the burst ends.
    #expect(a.sample(rms: silence, at: at(0.25)) == false)
    // A new loud sample restarts it at t=0.25, and a dip of exactly
    // gapTolerance after that is still inside (the boundary is inclusive), so
    // a quarter of a second later it is still active.
    #expect(a.sample(rms: loud, at: at(0.25)) == true)
    #expect(a.sample(rms: silence, at: at(0.375)) == true)
    // An eighth later it is over.
    #expect(a.sample(rms: silence, at: at(0.5)) == false)
}

// MARK: - Config defaults

@Test func tapConfigDefaultsMatchTheSpec() {
    let config = TapConfig()
    #expect(config.activeDuration == 1.0)
    #expect(config.gapTolerance == 0.75)
    #expect(config.quietCheckInterval == 0.1)
    #expect(config.threshold == 0.02)
}

@Test func tapConfigFilterStartsAsAllExceptWithNoRules() {
    // A fresh TapConfig must not silently restrict what counts as external
    // audio: the default has to be "everything except the hard exclusions".
    let config = TapConfig()
    #expect(config.filter.mode == .allExcept)
    #expect(config.filter.bundleIDs.isEmpty)
}

@Test func tapConfigCarriesTheFilterIntoTheSmoother() {
    // TapSmoother only owns the RMS/gap math; the filter is applied when the
    // tap targets are resolved. Asserting the value round-trips documents
    // that the thresholding path never rewrites the user's source rules.
    let filter = SourceFilter(mode: .watchedOnly, bundleIDs: ["com.google.Chrome"])
    let config = TapConfig(threshold: 0.5, activeDuration: 2.0, gapTolerance: 0.5, filter: filter)
    let a = TapSmoother(config: config)
    #expect(a.config.filter == filter)
    #expect(a.config.threshold == 0.5)
    #expect(a.config.activeDuration == 2.0)
    #expect(a.config.gapTolerance == 0.5)
}

@Test func tapConfigIsEquatableSoTheDetectorCanSkipRebuilds() {
    // The tap compares the resolved config to decide whether a settings change
    // needs a full rebuild; an unequal-identical config would restart the tap
    // on every save.
    #expect(TapConfig() == TapConfig())
    var changed = TapConfig()
    changed.threshold = 0.5
    #expect(TapConfig() != changed)
    var otherFilter = TapConfig()
    otherFilter.filter = SourceFilter(mode: .watchedOnly, bundleIDs: ["x"])
    #expect(TapConfig() != otherFilter)
}

@Test func tapStatusIsEquatableBecauseTheEngineSwitchesOnIt() {
    // `AutoPauseController` pattern-matches on the status, and the diagnostics
    // pane prints the reason, so the raw values matter as much as the shape.
    #expect(TapStatus.idle != .starting)
    #expect(TapStatus.active(rms: 0) != .active(rms: 0.5))
    #expect(TapStatus.unavailable(reason: "a") != .unavailable(reason: "b"))
    #expect(TapStatus.unavailable(reason: "x") == .unavailable(reason: "x"))
}
