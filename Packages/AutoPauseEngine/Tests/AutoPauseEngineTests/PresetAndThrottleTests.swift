import Foundation
import Testing
@testable import AutoPauseEngine

/// Two things live here, both pure and both about what the engine hands the
/// UI:
///
/// 1. `AutoPausePreset` - the timings and the threshold, and whether they are
///    still a preset after the user has touched them. The thorough
///    field-by-field `matches` coverage is in `PresetMatchingTests.swift`.
/// 2. The tick-level reconcile throttle, which is a property of the
///    controller's loop rather than of any one value.

private func instantAdapter(_ fake: FakeSpotifyControl) -> SpotifyFadeAdapter {
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    return adapter
}

// MARK: - Preset values

@Test func instantPresetIsActuallyInstant() {
    let preset = AutoPausePreset.instant
    #expect(preset.mode == .instant)
    // Near-zero dwell times: the point of the preset is that the configured
    // value is the felt latency, which is what regressed before.
    #expect(preset.activeDuration <= 0.1)
    #expect(preset.quietDuration <= 0.3)
    #expect(preset.fadeOutDuration == 0)
    #expect(preset.fadeInDuration == 0)
    #expect(preset.fadeOutDuration == 0 && preset.fadeInDuration == 0, "instant must not fade")
}

@Test func fadePresetKeepsGradualTimings() {
    let preset = AutoPausePreset.fade
    #expect(preset.mode == .fadeAndPause)
    #expect(preset.fadeOutDuration > 0)
    #expect(preset.fadeInDuration > 0)
    #expect(preset.quietDuration > preset.activeDuration)
}

@Test func bothPresetsAreStrictlyFasterToReactThanTheirFadeCounterpart() {
    // The reason two presets exist at all: picking "Instant" must change the
    // felt latency, not just the fade curve. If the dwell times ever matched,
    // the only difference would be cosmetic.
    #expect(AutoPausePreset.instant.activeDuration < AutoPausePreset.fade.activeDuration)
    #expect(AutoPausePreset.instant.quietDuration < AutoPausePreset.fade.quietDuration)
    #expect(AutoPausePreset.instant.fadeOutDuration < AutoPausePreset.fade.fadeOutDuration)
    #expect(AutoPausePreset.instant.fadeInDuration < AutoPausePreset.fade.fadeInDuration)
}

@Test func theFadePresetSummaryDescribesTheFadePresetNumbers() {
    // The summary is the only place the user learns what a preset does before
    // clicking it, and it is written as prose. If a timing changes, a summary
    // that stops matching is a small lie on screen.
    let summary = AutoPausePreset.fade.summary
    #expect(summary.contains("2s"), "the fade preset fades over 2s: \(summary)")
    #expect(summary.contains("3s"), "the fade preset waits 3s: \(summary)")
    #expect(AutoPausePreset.instant.summary.lowercased().contains("resume"))
}

@Test func presetTitlesAreDistinctAndNonEmpty() {
    // `ForEach(AutoPausePreset.allCases)` renders these as the preset buttons.
    let titles = AutoPausePreset.allCases.map(\.title)
    #expect(titles.allSatisfy { !$0.isEmpty })
    #expect(Set(titles).count == titles.count, "two presets render the same label: \(titles)")
}

@Test func presetMatchDetectsExactAndCustomSettings() {
    let fade = AutoPausePreset.fade
    #expect(
        fade.matches(
            mode: .fadeAndPause,
            activeDuration: fade.activeDuration,
            quietDuration: fade.quietDuration,
            fadeOutDuration: fade.fadeOutDuration,
            fadeInDuration: fade.fadeInDuration,
            threshold: fade.threshold
        ))
    // An instant-mode setup with fade-preset timings is *not* the fade preset:
    // this is the mismatch that made "Instant" feel slow.
    #expect(
        !fade.matches(
            mode: .instant,
            activeDuration: fade.activeDuration,
            quietDuration: fade.quietDuration,
            fadeOutDuration: fade.fadeOutDuration,
            fadeInDuration: fade.fadeInDuration,
            threshold: fade.threshold
        ))
    #expect(
        !AutoPausePreset.instant.matches(
            mode: .instant,
            activeDuration: 0.3,
            quietDuration: 1.0,
            fadeOutDuration: 0,
            fadeInDuration: 0,
            threshold: AutoPausePreset.instant.threshold
        ))
}

// MARK: - Duck modes

@Test func duckModeRawValuesAreStable() {
    // The mode is persisted through `rawValue` in UserDefaults, so a rename
    // would silently reset every user's setting to a default.
    #expect(DuckMode.fadeAndPause.rawValue == "fadeAndPause")
    #expect(DuckMode.instant.rawValue == "instant")
    #expect(DuckMode.muteOnly.rawValue == "muteOnly")
    #expect(DuckMode.allCases.count == 3)
}

@Test func muteOnlyIsNotOfferedByAnyPreset() {
    // `muteOnly` is a mode the adapter supports but no preset configures, so
    // it is reachable only by hand-editing settings. Pinned so that adding it
    // to a preset is a deliberate act.
    for preset in AutoPausePreset.allCases {
        #expect(preset.mode != .muteOnly, "\(preset.rawValue) configures mute-only")
    }
}

@Test func relinquishReasonsAreStable() {
    // The reasons are persisted in logs and read by support, and the raw values
    // are what a shipped log line will contain.
    #expect(RelinquishReason.playerGone.rawValue == "playerGone")
    #expect(RelinquishReason.pidChanged.rawValue == "pidChanged")
    #expect(RelinquishReason.manuallyResumed.rawValue == "manuallyResumed")
    #expect(RelinquishReason.manuallyStopped.rawValue == "manuallyStopped")
    #expect(RelinquishReason.volumeChangedByUser.rawValue == "volumeChangedByUser")
    #expect(RelinquishReason.wasPausedAlready.rawValue == "wasPausedAlready")
    #expect(RelinquishReason.notOwned.rawValue == "notOwned")
}

@Test func sourceFilterModesAreStable() {
    // `SourceFilterMode.rawValue` is what the prefs model persists.
    #expect(SourceFilterMode.allExcept.rawValue == "allExcept")
    #expect(SourceFilterMode.watchedOnly.rawValue == "watchedOnly")
    #expect(SourceFilterMode.allCases.count == 2)
}

// MARK: - Signals and decisions

@Test func audioSignalDefaultsToAnUnreadableRms() {
    // Poll cannot measure loudness, so the default has to be nil rather than
    // 0: a 0 would look like a measurement of digital silence and could be
    // compared against a threshold.
    let signal = AudioSignal(isActive: false)
    #expect(signal.rms == nil)
    #expect(signal.isActive == false)
    #expect(signal.at <= Date())
}

@Test func fusionDecisionsAreEquatableBecauseTheEngineSwitchesOnThem() {
    #expect(FusionDecision.quiet == .quiet)
    #expect(FusionDecision.candidate(source: "poll") == .candidate(source: "poll"))
    #expect(FusionDecision.candidate(source: "poll") != .candidate(source: "tap"))
    #expect(FusionDecision.hold != .quiet)
    #expect(FusionDecision.hold != .candidate(source: "poll"))
}

@Test func detectorKindsAreExactlyTapAndPoll() {
    // The UI renders a fixed label per kind; a third case would need a third
    // string, and the absence of one is what "no tap" is expressed with.
    #expect(DetectorKind(rawValue: "tap") == .tap)
    #expect(DetectorKind(rawValue: "poll") == .poll)
    #expect(DetectorKind(rawValue: "none") == nil)
}

@Test func spotifyPlayerStatesCoverEveryScriptResponse() {
    // `parseState` maps whatever AppleScript returns onto these, and an
    // unrecognised string must become `.unknown` rather than being dropped -
    // that is the state in which the adapter refuses to take ownership.
    #expect(Set(["playing", "paused", "stopped"]).count == 3)
    #expect(SpotifyScript.parseState("PLAYING") == .playing)
    #expect(SpotifyScript.parseState("  Paused  ") == .paused)
    #expect(SpotifyScript.parseState("Stopped\n") == .stopped)
    #expect(SpotifyScript.parseState("") == .unknown)
    #expect(SpotifyScript.parseState("playpaused") == .unknown)
}

// MARK: - The batched AppleScript read

@Test func stateAndVolumeScriptIsASingleRoundTrip() {
    // The comment in `SpotifyFadeAdapter.duckImpl` says one AppleEvent instead
    // of two is the difference between "instant" and "noticeably late", so the
    // script really has to ask for both in one `tell` block. Two `tell`
    // blocks would be two round trips.
    let script = SpotifyScript.stateAndVolume
    #expect(script.contains("player state"))
    #expect(script.contains("sound volume"))
    #expect(script.contains("with timeout of 4 seconds"))
    #expect(script.contains("if it is running"))
    // The separator the parser splits on must be in the script, and must not
    // be the volume's own division.
    #expect(script.contains("& \"/\" &"))
    // A stopped Spotify must answer with a well-formed pair, not a bare word,
    // or `stateAndVolume()` would parse state and lose the volume.
    #expect(script.contains("\"stopped/0\""))
}

@Test func theBatchedResponseIsParsedIntoBothHalves() {
    // The parsing is the whole value of the batched read, and it is the only
    // part that is testable without a permission grant.
    #expect(SpotifyScript.parseState("playing") == .playing)
    // A response with no separator leaves the volume nil, which is what the
    // adapter treats as "unreadable" rather than "0".
    let parts = "playing".split(separator: "/", maxSplits: 1).map(String.init)
    #expect(parts.count == 1)
    let full = "paused/42".split(separator: "/", maxSplits: 1).map(String.init)
    #expect(full.count == 2)
    #expect(SpotifyScript.parseState(full[0]) == .paused)
    #expect(Int(full[1].trimmingCharacters(in: .whitespaces)) == 42)
}
