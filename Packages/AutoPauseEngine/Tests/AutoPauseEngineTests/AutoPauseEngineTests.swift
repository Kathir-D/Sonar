import Testing
@testable import AutoPauseEngine

@Test func engineVersionIsSet() {
    #expect(!AutoPauseEngine.version.isEmpty)
}

@Test func fusionHoldsWhenQuiet() {
    var fusion = FusionState()
    let decision = fusion.evaluate(
        poll: AudioSignal(isActive: false),
        tap: AudioSignal(isActive: false, rms: 0.0)
    )
    #expect(decision == .hold)
}

@Test func fadeAdapterDefaults() {
    let adapter = SpotifyFadeAdapter()
    #expect(adapter.mode == .fadeAndPause)
    #expect(SpotifyFadeAdapter.spotifyBundleID == "com.spotify.client")
}
