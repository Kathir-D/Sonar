import Foundation
import Testing
@testable import AutoPauseEngine

/// `PollDetector` exists for two reasons: to list what is playing for the
/// diagnostics pane, and to keep auto-pause working when the tap cannot. The
/// rules that decide what counts as "another app" are pure functions
/// (`PollRules.isExcluded`, `SourceFilter.allows`) and are pinned here with no
/// Core Audio, no permission and no device.
///
/// The hardware-facing surface is deliberately barely touched at the bottom of
/// this file: `AudioDetector.runningOutputProcesses()` reads the live HAL, so
/// asserting anything about its *content* would make the suite machine-dependent
/// and would fail in CI with no audio permission.

/// Builds an `AudioProcess`. `rpid`/`rbundle` default to the process itself,
/// which is what Core Audio reports for an ordinary app; a helper (WebKit GPU,
/// Spotify Helper) passes a real parent.
private func proc(
    pid: pid_t,
    bundle: String = "",
    rpid: pid_t? = nil,
    rbundle: String? = nil,
    name: String = ""
) -> AudioProcess {
    AudioProcess(
        pid: pid,
        bundleID: bundle,
        responsiblePID: rpid ?? pid,
        responsibleBundleID: rbundle ?? bundle,
        name: name
    )
}

/// The pid every test pretends to be "Sonar".
private let selfPID: pid_t = 4242

// MARK: - Hard exclusions, one rule at a time

@Test func exclusionsMatchTheOwnPid() {
    #expect(PollRules.isExcluded(proc(pid: selfPID, name: "Sonar"), selfPID: selfPID))
    // ...and a different pid carrying Sonar's bundle id is still excluded,
    // because a second copy of the app must never duck itself.
    #expect(
        PollRules.isExcluded(
            proc(pid: 77, bundle: "com.KathirD.sonar", name: "Sonar"), selfPID: selfPID))
}

@Test func exclusionsFollowTheResponsiblePidToSelf() {
    // A WebKit/GPU helper whose responsible process is us. Excluding only on
    // `pid == selfPID` would let Sonar's own helper count as external audio and
    // make the app duck itself.
    #expect(
        PollRules.isExcluded(
            proc(pid: 900, rpid: selfPID, rbundle: "com.KathirD.sonar", name: "Sonar Helper"),
            selfPID: selfPID))
}

@Test func exclusionsMatchSpotifyByRawOrResponsibleBundle() {
    // The player itself...
    #expect(
        PollRules.isExcluded(
            proc(pid: 100, bundle: "com.spotify.client", name: "Spotify"), selfPID: selfPID))
    // ...and a helper that only carries Spotify as its responsible bundle.
    #expect(
        PollRules.isExcluded(
            proc(
                pid: 101, bundle: "com.spotify.client.helper", rpid: 100,
                rbundle: "com.spotify.client", name: "Spotify Helper"),
            selfPID: selfPID))
    // A helper whose *name* mentions Spotify is NOT excluded: only the bundle
    // identity counts.
    #expect(
        !PollRules.isExcluded(
            proc(pid: 102, bundle: "com.evil.lookalike", name: "Spotify"), selfPID: selfPID))
}

@Test func exclusionsMatchDaemonNamesExactly() {
    // UI blips and notification sounds are not media. If they counted, every
    // incoming message would pause the music.
    #expect(PollRules.isExcluded(proc(pid: 200, name: "systemsoundserverd"), selfPID: selfPID))
    #expect(PollRules.isExcluded(proc(pid: 201, name: "usernoted"), selfPID: selfPID))
    // Exact match only: a lookalike name is somebody else's audio.
    #expect(
        !PollRules.isExcluded(proc(pid: 202, name: "usernoted-helper"), selfPID: selfPID))
    #expect(
        !PollRules.isExcluded(proc(pid: 203, name: "myusernoted"), selfPID: selfPID))
    #expect(
        !PollRules.isExcluded(proc(pid: 204, name: "USERNOTED"), selfPID: selfPID))
    // A daemon *with* a bundle id is not covered by the name rule alone if the
    // bundle is a media app - the bundle id is what matters, and the name is
    // only ever consulted for the two listed daemons.
    #expect(
        !PollRules.isExcluded(
            proc(pid: 205, bundle: "com.apple.Music", name: "Music"), selfPID: selfPID))
}

@Test func filteringKeepsOnlyRealMediaWhenNothingElseIsExcluded() {
    // Carried over verbatim in behaviour from the original detector test: the
    // whole default rule in one list. Everything in this array is either us,
    // the player, or a system sound, except Safari and its GPU helper.
    let found = [
        proc(pid: selfPID, bundle: "com.KathirD.sonar", name: "Sonar"),
        proc(pid: 100, bundle: "com.spotify.client", name: "Spotify"),
        proc(pid: 101, bundle: "com.spotify.client.helper", rpid: 100,
             rbundle: "com.spotify.client", name: "Spotify Helper"),
        proc(pid: 200, name: "systemsoundserverd"),
        proc(pid: 201, name: "usernoted"),
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),
        proc(pid: 301, bundle: "com.apple.WebKit.GPU", rpid: 300,
             rbundle: "com.apple.Safari", name: "Safari GPU"),
    ]
    let kept = PollRules.filtered(found, selfPID: selfPID, filter: SourceFilter())
    #expect(kept.map(\.pid).sorted() == [300, 301])
}

@Test func allExceptDropsListedBundleIDsThroughTheFullPipeline() {
    let filter = SourceFilter(mode: .allExcept, bundleIDs: ["com.apple.Safari"])
    let found = [
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),
        proc(pid: 400, bundle: "com.google.Chrome", name: "Chrome"),
    ]
    #expect(PollRules.filtered(found, selfPID: 1, filter: filter).map(\.pid) == [400])
}

@Test func watchedOnlyKeepsListedBundleIDsThroughTheFullPipeline() {
    let filter = SourceFilter(mode: .watchedOnly, bundleIDs: ["com.google.Chrome"])
    let found = [
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),
        proc(pid: 400, bundle: "com.google.Chrome", name: "Chrome"),
        // WebKit helper resolves to Safari via responsible bundle -> not watched.
        proc(pid: 301, bundle: "com.apple.WebKit.GPU", rpid: 300,
             rbundle: "com.apple.Safari", name: "Safari GPU"),
    ]
    #expect(PollRules.filtered(found, selfPID: 1, filter: filter).map(\.pid) == [400])
}

@Test func theExcludedSetsAreExactlyTheTwoExpectedIdentities() {
    // Pinned as literals: this list is the difference between "auto-pause" and
    // "Sonar ducks itself", and it is persisted nowhere, so a typo in a bundle
    // id is invisible until it misfires on a real machine.
    #expect(PollRules.excludedBundleIDs == ["com.spotify.client", "com.KathirD.sonar"])
    #expect(PollRules.excludedNames == ["systemsoundserverd", "usernoted"])
}

@Test func theSpotifyBundleIdIsTheSameConstantTheAdapterUses() {
    // Two copies of this string would eventually drift, and the failure would
    // be silent: poll would stop excluding Spotify, the app would duck itself,
    // and the tap would see its own "other app" as external audio.
    #expect(PollRules.excludedBundleIDs.contains(SpotifyFadeAdapter.spotifyBundleID))
    #expect(SpotifyFadeAdapter.spotifyBundleID == "com.spotify.client")
    // ...and the same for the protocol's default, reached on a concrete
    // conformer (a static member on a protocol metatype is not reachable, and
    // the value it supplies is the one every conformer inherits unless it
    // overrides - `AppleScriptSpotifyControl` does not).
    #expect(AppleScriptSpotifyControl.spotifyBundleID == SpotifyFadeAdapter.spotifyBundleID)
}

@Test func exclusionsLeaveOrdinaryMediaAppsAlone() {
    #expect(
        !PollRules.isExcluded(
            proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"), selfPID: selfPID))
    #expect(
        !PollRules.isExcluded(
            proc(pid: 301, bundle: "com.apple.WebKit.GPU", rpid: 300,
                 rbundle: "com.apple.Safari", name: "Safari GPU"), selfPID: selfPID))
    #expect(
        !PollRules.isExcluded(
            proc(pid: 304, bundle: "com.google.Chrome", name: "Google Chrome"), selfPID: selfPID))
    #expect(
        !PollRules.isExcluded(
            proc(pid: 305, bundle: "com.apple.QuickTimePlayer", name: "QuickTime Player"),
            selfPID: selfPID))
    // A process with no bundle id and no name is not excluded either: the
    // detector cannot resolve it, but it must not be silently dropped.
    #expect(!PollRules.isExcluded(proc(pid: 302), selfPID: selfPID))
}

@Test func exclusionDoesNotDependOnWhichPidIsUsedAsSelf() {
    // `selfPID` is injected, so the rule is a pure comparison. Two different
    // "us" values must classify the same process the same way relative to
    // themselves and differently relative to a third party.
    let a: pid_t = 100
    let b: pid_t = 200
    let target = proc(pid: 300, bundle: "com.apple.Safari", name: "Safari")
    #expect(!PollRules.isExcluded(target, selfPID: a))
    #expect(!PollRules.isExcluded(target, selfPID: b))
    #expect(PollRules.isExcluded(target, selfPID: 300))
    #expect(PollRules.isExcluded(target, selfPID: 0) == false, "pid 0 is not our pid here")
}

// MARK: - SourceFilter.allows, in isolation from the hard exclusions

@Test func sourceFilterAllExceptKeepsEverythingWithNoRules() {
    // The default filter must be a no-op. If it ever defaulted to
    // `watchedOnly` with an empty set, auto-pause would stop working entirely
    // and nothing would fail loudly.
    let filter = SourceFilter()
    #expect(filter.mode == .allExcept)
    #expect(filter.bundleIDs.isEmpty)
    #expect(filter.allows(proc(pid: 300, bundle: "com.apple.Safari")))
    #expect(filter.allows(proc(pid: 301, bundle: "com.whatever.Unknown")))
    #expect(filter.allows(proc(pid: 302)))
}

@Test func sourceFilterAllExceptDropsOnlyTheListedBundleIDs() {
    let filter = SourceFilter(mode: .allExcept, bundleIDs: ["com.apple.Safari"])
    #expect(!filter.allows(proc(pid: 300, bundle: "com.apple.Safari")))
    #expect(filter.allows(proc(pid: 400, bundle: "com.google.Chrome")))
    // Prefix / substring near-misses must not match.
    #expect(filter.allows(proc(pid: 401, bundle: "com.apple.SafariTechnologyPreview")))
    #expect(filter.allows(proc(pid: 402, bundle: "com.apple.Safari-helper")))
    #expect(filter.allows(proc(pid: 403, bundle: "not.com.apple.Safari")))
    // Several exclusions at once.
    let many = SourceFilter(
        mode: .allExcept, bundleIDs: ["com.apple.Safari", "com.google.Chrome", "com.apple.Music"])
    #expect(!many.allows(proc(pid: 300, bundle: "com.apple.Safari")))
    #expect(!many.allows(proc(pid: 400, bundle: "com.google.Chrome")))
    #expect(!many.allows(proc(pid: 500, bundle: "com.apple.Music")))
    #expect(many.allows(proc(pid: 600, bundle: "com.spotify.client")))
}

@Test func sourceFilterAllExceptDropsAProcessByItsResponsibleBundleID() {
    // The mirror of the watchedOnly case: excluding Safari must also exclude
    // the WebKit helper that is the process actually holding the output.
    let filter = SourceFilter(mode: .allExcept, bundleIDs: ["com.apple.Safari"])
    #expect(
        !filter.allows(
            proc(pid: 301, bundle: "com.apple.WebKit.GPU", rpid: 300,
                 rbundle: "com.apple.Safari")))
}

@Test func sourceFilterWatchedOnlyWithNoBundleIDsAllowsNothing() {
    // The dangerous edge case: `watchedOnly` + empty set is a silent
    // "auto-pause off". The engine must never construct it (the preferences
    // model has to fall back to allExcept), and this test is the tripwire.
    let filter = SourceFilter(mode: .watchedOnly, bundleIDs: [])
    #expect(!filter.allows(proc(pid: 300, bundle: "com.apple.Safari")))
    #expect(!filter.allows(proc(pid: 301, bundle: "com.google.Chrome")))
    #expect(
        PollRules.filtered([proc(pid: 300, bundle: "com.apple.Safari")], selfPID: 1, filter: filter)
            .isEmpty)
    // A process with no bundle at all is also not in an empty watch list.
    #expect(!filter.allows(proc(pid: 302)))
}

@Test func sourceFilterWatchedOnlyMatchesTheResponsibleBundleID() {
    // A WebKit helper must count as Safari when Safari is watched, or watching
    // Safari would do nothing in practice (the helper is the process that
    // actually holds the audio output).
    let filter = SourceFilter(mode: .watchedOnly, bundleIDs: ["com.apple.Safari"])
    #expect(
        filter.allows(
            proc(pid: 301, bundle: "com.apple.WebKit.GPU", rpid: 300,
                 rbundle: "com.apple.Safari")))
    // The helper's own bundle id is irrelevant once a responsible one exists.
    #expect(
        !filter.allows(
            proc(pid: 302, bundle: "com.apple.WebKit.GPU", rpid: 300,
                 rbundle: "com.google.Chrome")))
    // Watching a *helper* bundle id matches nothing when a responsible app is
    // reported, which is the same asymmetry seen from the other side.
    let helperOnly = SourceFilter(mode: .watchedOnly, bundleIDs: ["com.apple.WebKit.GPU"])
    #expect(
        !helperOnly.allows(
            proc(pid: 303, bundle: "com.apple.WebKit.GPU", rpid: 300,
                 rbundle: "com.apple.Safari")))
    // Several watched apps at once.
    let many = SourceFilter(
        mode: .watchedOnly, bundleIDs: ["com.apple.Safari", "com.google.Chrome"])
    #expect(many.allows(proc(pid: 300, bundle: "com.apple.Safari")))
    #expect(many.allows(proc(pid: 400, bundle: "com.google.Chrome")))
    #expect(!many.allows(proc(pid: 500, bundle: "com.apple.Music")))
}

@Test func sourceFilterFallsBackToTheRawBundleIDWhenThereIsNoResponsibleOne() {
    // Audio processes with no responsible application (a bare helper reported
    // by the HAL) still have to be filterable by their own bundle id.
    let orphan = AudioProcess(
        pid: 500,
        bundleID: "com.apple.WebKit.Networking",
        responsiblePID: 500,
        responsibleBundleID: "",
        name: "WebKit Networking"
    )
    #expect(
        SourceFilter(mode: .watchedOnly, bundleIDs: ["com.apple.WebKit.Networking"]).allows(orphan))
    #expect(
        !SourceFilter(mode: .watchedOnly, bundleIDs: ["com.apple.Safari"]).allows(orphan))
    #expect(
        !SourceFilter(mode: .allExcept, bundleIDs: ["com.apple.WebKit.Networking"]).allows(orphan))
    // An orphan with no bundle id either cannot be matched in watchedOnly, and
    // is kept by allExcept.
    let anonymous = AudioProcess(
        pid: 501, bundleID: "", responsiblePID: 501, responsibleBundleID: "", name: "")
    #expect(!SourceFilter(mode: .watchedOnly, bundleIDs: ["anything"]).allows(anonymous))
    #expect(SourceFilter(mode: .allExcept, bundleIDs: ["anything"]).allows(anonymous))
}

@Test func sourceFilterIsEquatableSoTheTapCanSkipPointlessRebuilds() {
    // `TapDetector` compares the resolved filter to decide whether a settings
    // change needs a tap rebuild, and a filter that never compared equal would
    // restart the tap on every keystroke in the preferences pane.
    #expect(SourceFilter() == SourceFilter(mode: .allExcept, bundleIDs: []))
    #expect(
        SourceFilter(mode: .watchedOnly, bundleIDs: ["a", "b"])
            == SourceFilter(mode: .watchedOnly, bundleIDs: ["b", "a"]))
    #expect(SourceFilter(mode: .allExcept) != SourceFilter(mode: .watchedOnly))
    #expect(
        SourceFilter(mode: .allExcept, bundleIDs: ["a"])
            != SourceFilter(mode: .allExcept, bundleIDs: ["b"]))
}

// MARK: - Composition: hard exclusions win over user rules

@Test func filteredAppliesHardExclusionsBeforeTheUserFilter() {
    // Even if the user explicitly watches Spotify, it must never count as the
    // "other app" that pauses it.
    let filter = SourceFilter(mode: .watchedOnly, bundleIDs: ["com.spotify.client", "com.google.Chrome"])
    let found = [
        proc(pid: 100, bundle: "com.spotify.client", name: "Spotify"),
        proc(pid: 101, bundle: "com.spotify.client.helper", rpid: 100,
             rbundle: "com.spotify.client", name: "Spotify Helper"),
        proc(pid: selfPID, bundle: "com.KathirD.sonar", name: "Sonar"),
        proc(pid: 200, name: "systemsoundserverd"),
        proc(pid: 400, bundle: "com.google.Chrome", name: "Chrome"),
    ]
    #expect(PollRules.filtered(found, selfPID: selfPID, filter: filter).map(\.pid) == [400])
}

@Test func filteredOnAnEmptyProcessListIsEmpty() {
    let filter = SourceFilter(mode: .allExcept)
    #expect(PollRules.filtered([], selfPID: selfPID, filter: filter).isEmpty)
    // "Nothing is playing" must not look like a signal, and it must not
    // produce a phantom decision either way.
    #expect(
        PollRules.filtered(
            [], selfPID: selfPID, filter: SourceFilter(mode: .watchedOnly, bundleIDs: ["x"])).isEmpty)
}

@Test func filteredKeepsTheProcessListOrder() {
    // `activeSources()` feeds the diagnostics list, so the order Core Audio
    // reported must survive filtering rather than being reshuffled.
    let filter = SourceFilter(mode: .allExcept, bundleIDs: ["com.apple.Safari"])
    let found = [
        proc(pid: 400, bundle: "com.google.Chrome", name: "Chrome"),
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),
        proc(pid: 500, bundle: "com.apple.QuickTimePlayer", name: "QuickTime"),
    ]
    #expect(PollRules.filtered(found, selfPID: 1, filter: filter).map(\.pid) == [400, 500])
}

@Test func filteredAppliesToASingleExcludedProcessCorrectly() {
    // Regression shape for the whole rule: a list of *only* excluded
    // processes must come back empty, which is the "Spotify is the only thing
    // making sound" case that must not duck Spotify.
    let filter = SourceFilter()
    let found = [
        proc(pid: 100, bundle: "com.spotify.client", name: "Spotify"),
        proc(pid: selfPID, bundle: "com.KathirD.sonar", name: "Sonar"),
    ]
    #expect(PollRules.filtered(found, selfPID: selfPID, filter: filter).isEmpty)
}

@Test func filteredKeepsBothPidsOfALegitimateHelperPair() {
    // Safari and its GPU helper are one logical source, and the diagnostics
    // list should show both (they are separate processes holding output), so
    // filtering must not collapse or drop the helper.
    let found = [
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),
        proc(pid: 301, bundle: "com.apple.WebKit.GPU", rpid: 300,
             rbundle: "com.apple.Safari", name: "Safari GPU"),
        proc(pid: 302, bundle: "com.apple.WebKit.Networking", rpid: 300,
             rbundle: "com.apple.Safari", name: "Safari Networking"),
    ]
    let kept = PollRules.filtered(found, selfPID: 1, filter: SourceFilter())
    #expect(kept.map(\.pid) == [300, 301, 302])
    // The same three under a watchedOnly rule naming the responsible app.
    let watched = PollRules.filtered(
        found, selfPID: 1, filter: SourceFilter(mode: .watchedOnly, bundleIDs: ["com.apple.Safari"]))
    #expect(watched.map(\.pid) == [300, 301, 302])
}

@Test func filteringIsIdempotentBecauseItIsAppliedOnEveryRefresh() {
    // `PollDetector.activeSources()` re-applies the rules to a fresh scan every
    // time, and the engine may filter again for the diagnostics list. Applying
    // them twice must not change the answer or lose entries.
    let found = [
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),
        proc(pid: 100, bundle: "com.spotify.client", name: "Spotify"),
        proc(pid: 400, bundle: "com.google.Chrome", name: "Chrome"),
    ]
    let filter = SourceFilter(mode: .allExcept, bundleIDs: ["com.google.Chrome"])
    let once = PollRules.filtered(found, selfPID: selfPID, filter: filter)
    let twice = PollRules.filtered(once, selfPID: selfPID, filter: filter)
    #expect(once.map(\.pid) == [300])
    #expect(twice.map(\.pid) == [300])
}

@Test func filteredDoesNotMutateTheInputList() {
    // The caller (`activeSources`) hands the array straight to the diagnostics
    // model after filtering, so filtering must not reorder or clear it.
    let found = [
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),
        proc(pid: 100, bundle: "com.spotify.client", name: "Spotify"),
    ]
    let copy = found
    _ = PollRules.filtered(found, selfPID: selfPID, filter: SourceFilter())
    #expect(found == copy)
    #expect(found.count == 2)
}

@Test func audioProcessIsEquatableSoSignalsCanBeCompared() {
    // `AudioProcess` is `Equatable` over every field, and the equality is what
    // makes `AudioSignal` (also Equatable) usable in a test comparison.
    let a = proc(pid: 300, bundle: "com.apple.Safari", name: "Safari")
    #expect(a == proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"))
    #expect(a != proc(pid: 301, bundle: "com.apple.Safari", name: "Safari"))
    #expect(a != proc(pid: 300, bundle: "com.google.Chrome", name: "Safari"))
    #expect(a != proc(pid: 300, bundle: "com.apple.Safari", rpid: 1, name: "Safari"))
    // ...and an `AudioSignal` comparison, which is how the poll tests below
    // assert on a published reading.
    let stamp = Date(timeIntervalSince1970: 1_000)
    #expect(
        AudioSignal(isActive: true, at: stamp)
            == AudioSignal(isActive: true, rms: nil, at: stamp))
    #expect(
        AudioSignal(isActive: true, at: stamp)
            != AudioSignal(isActive: false, at: stamp))
}

// MARK: - Live scan: shape only, never content

@Test func responsiblePIDIsFailSafe() {
    // Own pid must resolve to something positive.
    #expect(ResponsibleProcess.pid(for: getpid()) > 0)
    // A bogus pid must fall back to itself, never to another live process.
    #expect(ResponsibleProcess.pid(for: 999_999_999) == 999_999_999)
    // pid 0 means "no such process", so it must also come back unchanged.
    #expect(ResponsibleProcess.pid(for: 0) == 0)
}

@Test func runningOutputProcessesDoesNotCrashAndReturnsRealProcesses() {
    // No assertion on *which* apps are present: that is machine state, and CI
    // has none. What is asserted is the contract the engine relies on: every
    // entry has a positive pid and a resolved name.
    let found = AudioDetector.runningOutputProcesses()
    for process in found {
        #expect(process.pid > 0)
        #expect(process.responsiblePID > 0)
        #expect(!process.name.isEmpty, "an unresolved name would show as a blank row in the UI")
    }
}

@Test func runningOutputProcessesNeverIncludesSonarOrSpotify() {
    // The same no-content caveat, but this one is checkable: the detector
    // applies its own exclusions, so whatever is playing, Sonar and Spotify
    // must not come out of the *filtered* list.
    let detector = PollDetector()
    detector.selfPID = getpid()
    detector.filter = SourceFilter()
    let active = detector.activeSources()
    for process in active {
        #expect(process.responsibleBundleID != "com.spotify.client")
        #expect(process.bundleID != "com.spotify.client")
        #expect(process.pid != getpid())
    }
}

@Test func pollDetectorRefreshPublishesASignalWithNoRms() {
    // Poll cannot measure loudness; that limitation is the reason the tap
    // exists. If a fake RMS ever appeared here the engine's tap preference
    // would be reading a number it could not trust.
    let detector = PollDetector()
    detector.selfPID = getpid()
    detector.minScanInterval = 0
    let signal = detector.refresh()
    #expect(signal.rms == nil)
    // refresh() must not block on Core Audio: the scan is scheduled and the
    // last reading is returned. Wait for the scan to land, then confirm the
    // published signal matches what is returned.
    let deadline = Date().addingTimeInterval(5)
    while detector.latestSignal == nil, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(detector.latestSignal != nil)
    #expect(detector.latestSignal == detector.refresh())
}

@Test func pollRefreshDoesNotBlockOnASlowScan() {
    // A scan can take seconds when a browser holds many audio helpers. The
    // tick must return promptly regardless, or fusion never evaluates and
    // auto-pause silently stops working.
    let detector = PollDetector()
    detector.selfPID = getpid()
    detector.minScanInterval = 0

    let start = Date()
    for _ in 0..<10 { _ = detector.refresh() }
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 0.5, "10 refreshes took \(elapsed)s - the scan is blocking the tick")
}

@Test func pollDetectorIsNamedPollAndCarriesAFilter() {
    // `name` is what the diagnostics pane prints, and the filter has to be the
    // same type the tap uses so one prefs model drives both backends.
    let detector = PollDetector()
    #expect(detector.name == "poll")
    detector.filter = SourceFilter(mode: .watchedOnly, bundleIDs: ["com.apple.Safari"])
    #expect(detector.filter.mode == .watchedOnly)
    #expect(TapConfig().filter == SourceFilter())
}
