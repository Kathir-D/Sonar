import Foundation
import Testing
@testable import AutoPauseEngine

// MARK: - Fakes

private func proc(
    pid: pid_t,
    bundle: String = "",
    rpid: pid_t = 0,
    rbundle: String = "",
    name: String = ""
) -> AudioProcess {
    AudioProcess(
        pid: pid,
        bundleID: bundle,
        responsiblePID: rpid == 0 ? pid : rpid,
        responsibleBundleID: rbundle.isEmpty ? bundle : rbundle,
        name: name
    )
}

// MARK: - Exclusion rules (pure, no hardware)

@Test func exclusionsRemoveSelfSpotifyAndSystemDaemons() {
    let selfPID: pid_t = 4242
    let filter = SourceFilter()
    let found = [
        proc(pid: 4242, bundle: "com.you.sonar", name: "Sonar"),  // self
        proc(pid: 100, bundle: "com.spotify.client", name: "Spotify"),  // player
        proc(pid: 101, bundle: "com.spotify.client.helper", rpid: 100, rbundle: "com.spotify.client", name: "Spotify Helper"),  // helper -> parent
        proc(pid: 200, name: "systemsoundserverd"),  // UI blips
        proc(pid: 201, name: "usernoted"),  // notification sounds
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),  // real media
        proc(pid: 301, bundle: "com.apple.WebKit.GPU", rpid: 300, rbundle: "com.apple.Safari", name: "Safari GPU"),  // helper -> Safari
    ]
    let kept = PollRules.filtered(found, selfPID: selfPID, filter: filter)
    #expect(kept.map(\.pid).sorted() == [300, 301])
}

@Test func allExceptDropsListedBundleIDs() {
    let filter = SourceFilter(mode: .allExcept, bundleIDs: ["com.apple.Safari"])
    let found = [
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),
        proc(pid: 400, bundle: "com.google.Chrome", name: "Chrome"),
    ]
    let kept = PollRules.filtered(found, selfPID: 1, filter: filter)
    #expect(kept.map(\.pid) == [400])
}

@Test func watchedOnlyKeepsListedBundleIDs() {
    let filter = SourceFilter(mode: .watchedOnly, bundleIDs: ["com.google.Chrome"])
    let found = [
        proc(pid: 300, bundle: "com.apple.Safari", name: "Safari"),
        proc(pid: 400, bundle: "com.google.Chrome", name: "Chrome"),
        // WebKit helper resolves to Safari via responsible bundle -> not watched.
        proc(pid: 301, bundle: "com.apple.WebKit.GPU", rpid: 300, rbundle: "com.apple.Safari", name: "Safari GPU"),
    ]
    let kept = PollRules.filtered(found, selfPID: 1, filter: filter)
    #expect(kept.map(\.pid) == [400])
}

// MARK: - Helper mapping + hardware smoke tests

@Test func responsiblePIDIsFailSafe() {
    // Own pid must resolve to something positive.
    #expect(ResponsibleProcess.pid(for: getpid()) > 0)
    // A bogus pid must fall back to itself, never to another live process.
    #expect(ResponsibleProcess.pid(for: 999_999_999) == 999_999_999)
}

@Test func runningOutputProcessesDoesNotCrash() {
    let found = AudioDetector.runningOutputProcesses()
    // No assertion on content (hardware-dependent); the call itself must be safe.
    #expect(found.count >= 0)
}

@Test func pollDetectorRefreshPublishesSignal() {
    let detector = PollDetector()
    detector.selfPID = getpid()
    let signal = detector.refresh()
    #expect(detector.latestSignal == signal)
    #expect(signal.rms == nil)  // poll backend has no loudness data
}
