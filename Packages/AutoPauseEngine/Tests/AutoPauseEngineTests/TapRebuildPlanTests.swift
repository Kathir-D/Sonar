import CoreAudio
import Foundation
import Testing
@testable import AutoPauseEngine

/// The rule the tap's rebuild path is judged by: *which* notification it was,
/// not just what it resolved to.
///
/// The bug this pins. A device change re-resolves the tap's per-process targets
/// and compares them to the last resolution. But the last resolution was made
/// for the device that has just gone away, and a tap left bound to a replaced
/// output is the worst possible outcome rather than an obvious one: coreaudiod
/// keeps delivering buffers, so `isCapturing` is true, the status is `.active`,
/// the heartbeat is healthy — and every sample is 0.0000. RMS never crosses the
/// threshold, the tap still wins every vote in the engine, and Auto-Pause never
/// pauses anything. In the field that showed up as
///
///     tap: heartbeat: capturing=true rms=0.0000 peak=0.0000 ... status=active(rms: 0.0)
///     engine: tick: detector=tap tap=0.0000 decision=quiet owned=false
///     tap: rebuild skipped (device change): targets unchanged      (x39)
///
/// 39 skipped rebuilds next to a live-but-silent tap is not a coincidence. It
/// is the whole bug: the comparison that was supposed to stop us rebuilding on
/// our own aggregate was also stopping us rebuilding after the user's hardware
/// changed.
///
/// The decision is a pure function so it can be asserted here, on a machine with
/// no audio hardware, no permission, and no aggregate devices of its own.

/// The debounce the detector uses, restated so a test cannot pass against a
/// number production does not use.
private let debounce: TimeInterval = 2.0

private func targets(
    excluded: [AudioObjectID] = [],
    included: [AudioObjectID] = [],
    exclusive: Bool? = nil,
    output: String? = "AppleHDAEngineOutput:1B,0,1,2:0",
    summary: String = "self(42)"
) -> TapDetector.TapTargets {
    TapDetector.TapTargets(
        excludedObjectIDs: excluded,
        includedObjectIDs: included,
        exclusive: exclusive ?? included.isEmpty,
        outputDeviceUID: output,
        excludedSummary: summary
    )
}

private func plan(
    _ reason: TapDetector.RebuildReason,
    last: TapDetector.TapTargets?,
    resolved: TapDetector.TapTargets,
    force: Bool = false,
    sinceLastBuild: TimeInterval? = nil
) -> TapDetector.RebuildPlan {
    TapDetector.plan(
        reason: reason,
        last: last,
        resolved: resolved,
        force: force,
        sinceLastBuild: sinceLastBuild,
        debounce: debounce
    )
}

// MARK: - A device change always rebuilds

@Test func aDeviceChangeWithChangedTargetsTriggersARebuild() {
    let before = targets(excluded: [42, 119], output: "BuiltInOutputDevice:1A,0,1,2:0")
    let after = targets(excluded: [42, 118, 119], output: "BoseQuietComfort:44,1,2,3:0")
    #expect(plan(.deviceChange, last: before, resolved: after) == .build)
}

@Test func aDeviceChangeAlsoRebuildsWhenTheTargetsCompareEqual() {
    // The case that shipped broken. Plugging AirPods in can leave the resolved
    // process set byte-for-byte identical — same processes, same ids, the same
    // default output UID — while the object behind that UID has been replaced
    // and the tap's binding to it is no longer real. The comparison cannot tell
    // this from "nothing happened", so it is not consulted at all here: the
    // whole point is that a resolution taken against the *old* device is not
    // evidence about the new one.
    let same = targets(excluded: [42, 119])
    #expect(plan(.deviceChange, last: same, resolved: same) == .build)
}

@Test func aDeviceChangeWithNothingBuiltYetStillRebuilds() {
    // No cached resolution to be misled by, and no reason not to build.
    #expect(plan(.deviceChange, last: nil, resolved: targets()) == .build)
}

@Test func aDeviceChangeInsideTheDebounceWindowCoalescesInsteadOfSkipping() {
    // Two notifications in quick succession must not build twice, but they must
    // not be dropped either: the coalesced one is forced, so it goes ahead on
    // the strength of the newest notification rather than waiting for another
    // one to arrive. Dropping it is how a device change disappears entirely.
    #expect(
        plan(.deviceChange, last: targets(), resolved: targets(), sinceLastBuild: 0.5)
            == .debounce
    )
    #expect(
        plan(.deviceChange, last: targets(), resolved: targets(), sinceLastBuild: 10)
            == .build
    )
}

// MARK: - The comparison is still valid where it is valid

@Test func aProcessChangeWithIdenticalTargetsIsSkipped() {
    // This is what the targets comparison is for: coreaudiod republishes the
    // process list constantly, and rebuilding a working tap on every one of
    // those notifications would drop detection for a second or two each time.
    let same = targets(excluded: [42, 119])
    guard case .skip(let why) = plan(.processChange, last: same, resolved: same) else {
        Issue.record("expected a process change with unchanged targets to be skipped")
        return
    }
    #expect(why == "targets unchanged")
}

@Test func aProcessChangeWithDifferentTargetsRebuilds() {
    let before = targets(excluded: [42, 119])
    let after = targets(excluded: [42, 119, 240], summary: "self(42), com.apple.Safari(119), Zoom(240)")
    #expect(plan(.processChange, last: before, resolved: after) == .build)
}

@Test func aLogSentenceIsNotATarget() {
    // Found in the field, and worth its own test because the failure it causes
    // is invisible. coreaudiod keeps process object IDs for processes that have
    // already exited, and hands out new ones as they appear — so the resolver
    // logged a `skip-stale(131)` note, then `skip-stale(138)`, then
    // `skip-stale(145)`, a few seconds apart. That sentence was part of the
    // synthesized identity, so every one of them tore the tap down and rebuilt
    // it from scratch, with the engine holding every decision for the second or
    // two each rebuild took. The object ids — the only thing that decides what
    // the tap captures — never changed.
    let before = targets(excluded: [42, 119], summary: "skip-stale(98), com.spotify.client(119), self(120), skip-stale(131)")
    let after = targets(excluded: [42, 119], summary: "skip-stale(98), com.spotify.client(119), self(120)")
    #expect(before.excludedSummary != after.excludedSummary, "the two log lines do differ")
    #expect(before == after, "and the tap is identical, so nothing should be rebuilt")
    #expect(plan(.processChange, last: before, resolved: after) == .skip(reason: "targets unchanged"))
    #expect(
        plan(.deviceChange, last: before, resolved: after) == .build,
        "a device change still rebuilds regardless — see the test above"
    )
}

@Test func theTargetIdentityIsEverythingThatChangesWhatIsCaptured() {
    // And the other direction: anything that *does* change the capture must
    // still count as a change, including the output the tap is bound to.
    let base = targets(excluded: [42, 119], included: [], exclusive: true, output: "A", summary: "x")
    #expect(base != targets(excluded: [42], included: [], exclusive: true, output: "A", summary: "x"))
    #expect(base != targets(excluded: [42, 119], included: [7], exclusive: false, output: "A", summary: "x"))
    #expect(base != targets(excluded: [42, 119], included: [], exclusive: false, output: "A", summary: "x"))
    #expect(base != targets(excluded: [42, 119], included: [], exclusive: true, output: "B", summary: "x"))
    #expect(base != targets(excluded: [42, 119], included: [], exclusive: true, output: nil, summary: "x"))
}

@Test func aForcedRebuildIgnoresTheComparisonEntirely() {
    // Waking, starting and retrying are deliberate: each is a moment where the
    // previous tap's evidence says nothing about the machine now.
    let same = targets()
    #expect(plan(.wake, last: same, resolved: same) == .build)
    #expect(plan(.retry, last: same, resolved: same) == .build)
    #expect(plan(.config, last: same, resolved: same, force: true) == .build)
    #expect(plan(.processChange, last: same, resolved: same, force: true) == .build)
}

@Test func anUnforcedWakeInsideTheDebounceWindowCoalesces() {
    #expect(plan(.wake, last: nil, resolved: targets(), sinceLastBuild: 0.1) == .debounce)
    #expect(plan(.config, last: nil, resolved: targets(), sinceLastBuild: 0.1) == .debounce)
}

@Test func aForceBeatsTheDebounceWindow() {
    // `start()` and the retry path are called at moments when "too soon" would
    // mean "never", so a forced build goes ahead.
    #expect(plan(.retry, last: nil, resolved: targets(), force: true, sinceLastBuild: 0) == .build)
}

// MARK: - The rules that keep a rebuild from happening at the wrong moment

@Test func aFirstBuildIsNeverSkippedForHavingNothingToCompareAgainst() {
    // `lastTargets` is nil until the first build, and "nil == wanted" is false,
    // so the very first build cannot be mistaken for a no-op. This is the case
    // that made the comparison safe to have at all.
    #expect(plan(.config, last: nil, resolved: targets()) == .build)
    #expect(plan(.processChange, last: nil, resolved: targets()) == .build)
}

@Test func theRebuildReasonsAreAllDistinct() {
    // The reason is what selects the rule, and the log prints it, so two
    // notifications that behave differently must not be indistinguishable.
    let reasons: [TapDetector.RebuildReason] = [
        .start, .config, .deviceChange, .processChange, .wake, .afterTeardown, .retry,
    ]
    #expect(Set(reasons).count == reasons.count)
    #expect(Set(reasons.map(\.rawValue)).count == reasons.count)
}
