import Foundation
import Testing
@testable import AutoPauseEngine

// MARK: - RMS math (pure)

@Test func rmsOfSilenceIsZero() {
    let zeros = [Float](repeating: 0, count: 1024)
    let rms = zeros.withUnsafeBufferPointer { TapMeter.rms($0) }
    #expect(rms == 0)
}

@Test func rmsOfConstantIsAmplitude() {
    let samples = [Float](repeating: 0.5, count: 512)
    let rms = samples.withUnsafeBufferPointer { TapMeter.rms($0) }
    #expect(abs(rms - 0.5) < 0.0001)
}

@Test func rmsOfSineIsPeakOverSqrt2() {
    let n = 4096
    var samples = [Float](repeating: 0, count: n)
    for i in 0..<n { samples[i] = sin(Float(i) * 0.1) }
    let rms = samples.withUnsafeBufferPointer { TapMeter.rms($0) }
    #expect(abs(rms - Float(1 / Double(2).squareRoot())) < 0.01)
}

@Test func rmsOfEmptyIsZero() {
    let empty: [Float] = []
    let rms = empty.withUnsafeBufferPointer { TapMeter.rms($0) }
    #expect(rms == 0)
}

// MARK: - Smoother timing (spec: 1 s active / 0.75 s gap)

@Test func smootherNeedsSustainedLoudness() {
    var smoother = TapSmoother(config: TapConfig())
    let t0 = Date()
    // A single loud blip is not active yet.
    #expect(smoother.sample(rms: 0.5, at: t0) == false)
    // Still loud after 0.5 s: not yet (needs 1 s).
    #expect(smoother.sample(rms: 0.5, at: t0.addingTimeInterval(0.5)) == false)
    // Loud for 1 s: active.
    #expect(smoother.sample(rms: 0.5, at: t0.addingTimeInterval(1.0)) == true)
}

@Test func smootherIgnoresShortGaps() {
    var smoother = TapSmoother(config: TapConfig())
    let t0 = Date()
    #expect(smoother.sample(rms: 0.5, at: t0) == false)
    #expect(smoother.sample(rms: 0.5, at: t0.addingTimeInterval(1.0)) == true)
    // 0.5 s dip (below the 0.75 s gap tolerance) keeps it active once loud again.
    #expect(smoother.sample(rms: 0.0, at: t0.addingTimeInterval(1.5)) == true)
    #expect(smoother.sample(rms: 0.5, at: t0.addingTimeInterval(1.6)) == true)
}

@Test func smootherResetsAfterLongGap() {
    var smoother = TapSmoother(config: TapConfig())
    let t0 = Date()
    #expect(smoother.sample(rms: 0.5, at: t0) == false)
    #expect(smoother.sample(rms: 0.5, at: t0.addingTimeInterval(1.0)) == true)
    // Quiet for longer than the gap: inactive, streak reset.
    #expect(smoother.sample(rms: 0.0, at: t0.addingTimeInterval(2.0)) == false)
    // One fresh loud sample is not enough again.
    #expect(smoother.sample(rms: 0.5, at: t0.addingTimeInterval(2.1)) == false)
}

@Test func smootherReevaluateDetectsQuiet() {
    var smoother = TapSmoother(config: TapConfig())
    let t0 = Date()
    _ = smoother.sample(rms: 0.5, at: t0)
    _ = smoother.sample(rms: 0.5, at: t0.addingTimeInterval(1.0))
    // Quiet-check tick with no new audio: decays to inactive.
    #expect(smoother.reevaluate(at: t0.addingTimeInterval(2.0)) == false)
}

@Test func tapConfigDefaultsMatchSpec() {
    let config = TapConfig()
    #expect(config.activeDuration == 1.0)
    #expect(config.gapTolerance == 0.75)
    #expect(config.quietCheckInterval == 0.1)
}

// MARK: - Hardware smoke (opt-in: SONAR_TAP_SMOKE=1, may prompt for permission)

@Test func tapStartStopSmoke() {
    guard ProcessInfo.processInfo.environment["SONAR_TAP_SMOKE"] != nil else { return }
    let detector = TapDetector()
    #expect(detector.status == .idle)
    detector.start()
    // Creation is async; stop must always be safe.
    detector.stop()
    #expect(detector.status == .idle)
}
