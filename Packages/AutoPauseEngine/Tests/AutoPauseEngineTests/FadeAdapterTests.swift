import Foundation
import Testing
@testable import AutoPauseEngine

/// Scriptable fake: no AppleScript, no Spotify. Records every call.
final class FakeSpotifyControl: SpotifyControl, @unchecked Sendable {
    var state: SpotifyPlayerState = .playing
    var transportFails = false
    var currentVolume = 70
    var pid: pid_t? = 1234
    var calls: [String] = []
    var volumesSet: [Int] = []
    var rereadHook: (() -> Void)?
    /// Fired from inside `setVolume`, i.e. from the middle of a fade. This is
    /// the only hook that can land while a fade is in flight, which is what
    /// the generation-token tests need.
    var volumeSetHook: ((Int) -> Void)?
    /// Models an unreadable `sound volume` (an AppleScript timeout, or a
    /// Spotify that answered with something unparseable). `nil` is not the same
    /// as "the volume is 0", and the adapter has to tell them apart: a nil read
    /// is a transport problem, never a user moving the slider.
    var volumeUnreadable = false

    func playerState() -> SpotifyPlayerState? {
        calls.append("state")
        rereadHook?()
        return transportFails ? nil : state
    }

    func volume() -> Int? {
        calls.append("getVolume")
        return volumeUnreadable ? nil : currentVolume
    }

    func setVolume(_ value: Int) {
        let v = min(100, max(0, value))
        calls.append("setVolume(\(v))")
        volumesSet.append(v)
        currentVolume = v
        volumeSetHook?(v)
    }

    func play() {
        calls.append("play")
        state = .playing
    }

    func pause() {
        calls.append("pause")
        state = .paused
    }

    func spotifyPID() -> pid_t? {
        calls.append("pid")
        return pid
    }

    func resetCalls() {
        calls = []
        volumesSet = []
    }
}

private func instantAdapter(_ fake: FakeSpotifyControl) -> SpotifyFadeAdapter {
    let adapter = SpotifyFadeAdapter(control: fake, mode: .instant)
    adapter.rereadDelay = 0
    return adapter
}

// MARK: - duck

@Test func duckPausesPlayingSpotify() {
    let fake = FakeSpotifyControl()
    let adapter = instantAdapter(fake)
    adapter.duckSync(source: "poll")
    #expect(fake.calls.contains("pause"))
    #expect(adapter.isOwned)
}

@Test func duckTakesNoOwnershipWhenPaused() {
    // Manual pause BEFORE any duck: never take ownership -> never resume.
    let fake = FakeSpotifyControl()
    fake.state = .paused
    let adapter = instantAdapter(fake)
    adapter.duckSync(source: "poll")
    #expect(!fake.calls.contains("pause"))
    #expect(!adapter.isOwned)
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
}

@Test func duckSkipsStoppedSpotify() {
    let fake = FakeSpotifyControl()
    fake.state = .stopped
    let adapter = instantAdapter(fake)
    adapter.duckSync(source: "poll")
    #expect(!adapter.isOwned)
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
}

@Test func duckSkipsWhenPlayerGone() {
    let fake = FakeSpotifyControl()
    fake.pid = nil
    let adapter = instantAdapter(fake)
    adapter.duckSync(source: "poll")
    #expect(!adapter.isOwned)
}

// MARK: - restore

@Test func restoreResumesOwnedPausedSpotify() {
    let fake = FakeSpotifyControl()
    let adapter = instantAdapter(fake)
    adapter.duckSync(source: "poll")
    #expect(adapter.isOwned)
    fake.resetCalls()
    adapter.restoreSync()
    #expect(fake.calls.contains("play"))
    #expect(!adapter.isOwned)
}

@Test func noResumeAfterManualPause() {
    // Full story: duck while playing, user pauses manually?? — already paused
    // by us. The real manual-pause case: Spotify paused BEFORE duck (covered
    // above). Here: user quits (pid nil) after duck -> no play, relinquish.
    let fake = FakeSpotifyControl()
    let adapter = instantAdapter(fake)
    adapter.duckSync(source: "poll")
    fake.pid = nil
    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(!adapter.isOwned)
}

@Test func pidChangeRelinquishes() {
    // Spotify restarted mid-duck: new instance owns itself, never resumed.
    let fake = FakeSpotifyControl()
    let adapter = instantAdapter(fake)
    adapter.duckSync(source: "poll")
    fake.pid = 9999
    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(!adapter.isOwned)
}

@Test func manualResumeRelinquishesWithoutReplay() {
    // User hit play themselves while ducked: restore volume, don't call play.
    let fake = FakeSpotifyControl()
    let adapter = SpotifyFadeAdapter(control: fake, mode: .muteOnly)
    adapter.rereadDelay = 0
    adapter.fadeStepInterval = 0
    adapter.duckSync(source: "poll")
    fake.state = .playing // manual resume
    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(!adapter.isOwned)
    #expect(fake.currentVolume == 70) // captured volume restored
}

@Test func manualVolumeChangePreservesUserVolume() {
    let fake = FakeSpotifyControl()
    let adapter = SpotifyFadeAdapter(control: fake, mode: .muteOnly)
    adapter.rereadDelay = 0
    adapter.duckSync(source: "poll")
    #expect(fake.currentVolume == 0)
    fake.currentVolume = 42 // user moved the slider mid-duck
    fake.resetCalls()
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(fake.currentVolume == 42) // preserved, not clobbered
    #expect(!adapter.isOwned)
}

// MARK: - modes

@Test func fadeModeFadesDownAndUp() {
    let fake = FakeSpotifyControl()
    let adapter = SpotifyFadeAdapter(control: fake, mode: .fadeAndPause, fadeOutDuration: 0.3, fadeInDuration: 0.3)
    adapter.rereadDelay = 0
    adapter.fadeStepInterval = 0.05
    adapter.duckSync(source: "tap")
    #expect(fake.calls.contains("pause"))
    #expect(fake.currentVolume == 0)
    let downSteps = fake.volumesSet.filter { $0 < 70 }
    #expect(!downSteps.isEmpty) // gradual, not a single jump
    fake.resetCalls()
    adapter.restoreSync()
    #expect(fake.calls.contains("play"))
    #expect(fake.currentVolume == 70)
}

@Test func muteOnlyNeverPauses() {
    let fake = FakeSpotifyControl()
    let adapter = SpotifyFadeAdapter(control: fake, mode: .muteOnly)
    adapter.rereadDelay = 0
    adapter.duckSync(source: "poll")
    #expect(!fake.calls.contains("pause"))
    #expect(fake.currentVolume == 0)
    #expect(adapter.isOwned)
    adapter.restoreSync()
    #expect(!fake.calls.contains("play"))
    #expect(fake.currentVolume == 70)
}

// MARK: - SpotifyScript contract

@Test func scriptsUseExplicitPlayPauseWithTimeout() {
    #expect(SpotifyScript.play.contains("to play"))
    #expect(!SpotifyScript.play.contains("playpause"))
    #expect(SpotifyScript.pause.contains("to pause"))
    #expect(SpotifyScript.play.contains("with timeout of 4 seconds"))
    #expect(SpotifyScript.pause.contains("with timeout of 4 seconds"))
    #expect(SpotifyScript.playerState.contains("player state"))
}

@Test func scriptsParsePlayerState() {
    #expect(SpotifyScript.parseState("playing") == .playing)
    #expect(SpotifyScript.parseState("paused") == .paused)
    #expect(SpotifyScript.parseState("stopped") == .stopped)
    #expect(SpotifyScript.parseState(nil) == .unknown)
    #expect(SpotifyScript.parseState("weird") == .unknown)
}

@Test func scriptsClampVolume() {
    #expect(SpotifyScript.setVolume(150).contains("100"))
    #expect(SpotifyScript.setVolume(-5).contains("0"))
}
