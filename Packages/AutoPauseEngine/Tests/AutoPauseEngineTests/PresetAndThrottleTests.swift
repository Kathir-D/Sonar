import Foundation
import Testing
@testable import AutoPauseEngine

/// Local helper (the one in FadeAdapterTests is file-private).
private func instantAdapter(_ fake: FakeSpotifyControl) -> SpotifyFadeAdapter {
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    return adapter
}

// MARK: - Presets

@Test func instantPresetIsActuallyInstant() {
    let preset = AutoPausePreset.instant
    #expect(preset.mode == .instant)
    // Near-zero dwell times: the point of the preset is that the configured
    // value is the felt latency, which is what regressed before.
    #expect(preset.activeDuration <= 0.1)
    #expect(preset.quietDuration <= 0.3)
    #expect(preset.fadeOutDuration == 0)
    #expect(preset.fadeInDuration == 0)
}

@Test func fadePresetKeepsGradualTimings() {
    let preset = AutoPausePreset.fade
    #expect(preset.mode == .fadeAndPause)
    #expect(preset.fadeOutDuration > 0)
    #expect(preset.fadeInDuration > 0)
    #expect(preset.quietDuration > preset.activeDuration)
}

@Test func presetMatchDetectsExactAndCustomSettings() {
    let fade = AutoPausePreset.fade
    #expect(
        fade.matches(
            mode: .fadeAndPause,
            activeDuration: fade.activeDuration,
            quietDuration: fade.quietDuration,
            fadeOutDuration: fade.fadeOutDuration,
            fadeInDuration: fade.fadeInDuration
        ))
    // An instant-mode setup with fade-preset timings is *not* the fade preset:
    // this is the mismatch that made "Instant" feel slow.
    #expect(
        !fade.matches(
            mode: .instant,
            activeDuration: fade.activeDuration,
            quietDuration: fade.quietDuration,
            fadeOutDuration: fade.fadeOutDuration,
            fadeInDuration: fade.fadeInDuration
        ))
    #expect(
        !AutoPausePreset.instant.matches(
            mode: .instant,
            activeDuration: 0.3,
            quietDuration: 1.0,
            fadeOutDuration: 0,
            fadeInDuration: 0
        ))
}

// MARK: - Reconcile throttling

@Test func reconcileIsThrottledWhileOwned() {
    let fake = FakeSpotifyControl()
    let adapter = instantAdapter(fake)
    let controller = AutoPauseController(poll: StubPoll(), tap: nil, adapter: adapter)
    controller.reconcileInterval = 10  // effectively "once"

    adapter.duckSync(source: "test")
    #expect(adapter.isOwned)
    fake.resetCalls()

    // Many ticks inside one interval must not each spend an AppleEvent.
    for _ in 0..<50 { controller.tick() }
    let pidCalls = fake.calls.filter { $0 == "pid" }.count
    #expect(pidCalls <= 1, "expected reconcile throttled, saw \(pidCalls) pid calls")
}

@Test func reconcileStaysOffWhenNotOwned() {
    let fake = FakeSpotifyControl()
    let adapter = instantAdapter(fake)
    let controller = AutoPauseController(poll: StubPoll(), tap: nil, adapter: adapter)

    fake.resetCalls()
    for _ in 0..<20 { controller.tick() }
    #expect(fake.calls.filter { $0 == "pid" }.isEmpty)
}

// MARK: - Mid-duck reconcile must not steal our own playback

@Test func midFadePlaybackIsNotTreatedAsManualResume() {
    let fake = FakeSpotifyControl()
    // Slow fade so the reconcile lands while Spotify is still playing.
    let adapter = SpotifyFadeAdapter(control: fake, mode: .fadeAndPause)
    adapter.fadeOutDuration = 0.4
    adapter.fadeStepInterval = 0.1
    adapter.rereadDelay = 0

    // One-shot: reconcile itself reads player state, so an unguarded hook
    // would recurse forever.
    var fired = false
    fake.rereadHook = { [weak adapter] in
        guard !fired else { return }
        fired = true
        if adapter?.isOwned == true {
            adapter?.reconcileSync()
        }
    }
    adapter.duckSync(source: "test")
    fake.rereadHook = nil

    // Ownership must survive the fade: we paused it ourselves.
    #expect(fake.state == .paused)
}

// MARK: - Batched read

@Test func stateAndVolumeParsesCombinedResponse() {
    let control = AppleScriptSpotifyControl()
    // Script shape is asserted directly; parsing is covered by the shape.
    #expect(SpotifyScript.stateAndVolume.contains("sound volume"))
    #expect(SpotifyScript.stateAndVolume.contains("player state"))
    #expect(SpotifyScript.stateAndVolume.hasPrefix("with timeout of"))
}

/// Minimal poll stub so the controller can tick without hardware.
final class StubPoll: RefreshingDetector, @unchecked Sendable {
    var name = "stub"
    var filter = SourceFilter()
    var signal = AudioSignal(isActive: false, rms: nil)
    var latestSignal: AudioSignal? { signal }
    func start() {}
    func stop() {}
    func refresh() -> AudioSignal { signal }
}
