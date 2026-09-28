import Foundation
import Testing
@testable import AutoPauseEngine

private let loud = AudioSignal(isActive: true, rms: 0.5)
private let quiet = AudioSignal(isActive: false, rms: 0.0)

@Test func fusionNeedsSustainedLoudness() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    let t0 = Date()
    #expect(fusion.evaluate(poll: loud, tap: nil, now: t0) == .hold)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: t0.addingTimeInterval(0.9)) == .hold)
    #expect(fusion.evaluate(poll: loud, tap: nil, now: t0.addingTimeInterval(1.0)) == .candidate(source: "poll"))
}

@Test func fusionEitherDetectorLoudIsCandidate() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    let t0 = Date()
    _ = fusion.evaluate(poll: nil, tap: loud, now: t0)
    #expect(fusion.evaluate(poll: nil, tap: loud, now: t0.addingTimeInterval(1.0)) == .candidate(source: "tap"))
}

@Test func fusionReportsBothLoud() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    let t0 = Date()
    _ = fusion.evaluate(poll: loud, tap: loud, now: t0)
    #expect(fusion.evaluate(poll: loud, tap: loud, now: t0.addingTimeInterval(1.0)) == .candidate(source: "poll+tap"))
}

@Test func fusionLoudResetsQuietStreak() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    let t0 = Date()
    _ = fusion.evaluate(poll: quiet, tap: quiet, now: t0)
    _ = fusion.evaluate(poll: quiet, tap: quiet, now: t0.addingTimeInterval(2.0))
    // Blip of loudness resets the quiet streak entirely: the streak restarts
    // at the first quiet sample after the blip (t+4.0), not at the blip.
    _ = fusion.evaluate(poll: loud, tap: nil, now: t0.addingTimeInterval(2.5))
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: t0.addingTimeInterval(4.0)) == .hold)
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: t0.addingTimeInterval(6.9)) == .hold)
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: t0.addingTimeInterval(7.0)) == .quiet)
}

@Test func fusionQuietNeedsFullDuration() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    let t0 = Date()
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: t0) == .hold)
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: t0.addingTimeInterval(2.9)) == .hold)
    #expect(fusion.evaluate(poll: quiet, tap: quiet, now: t0.addingTimeInterval(3.0)) == .quiet)
}

@Test func fusionResetClearsStreaks() {
    var fusion = FusionState(activeDuration: 1.0, quietDuration: 3.0)
    let t0 = Date()
    _ = fusion.evaluate(poll: loud, tap: nil, now: t0)
    fusion.reset()
    #expect(fusion.evaluate(poll: loud, tap: nil, now: t0.addingTimeInterval(5.0)) == .hold)
}
