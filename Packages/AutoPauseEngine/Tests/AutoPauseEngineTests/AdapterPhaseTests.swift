import Foundation
import Testing
@testable import AutoPauseEngine

/// `AdapterPhase` is what Sonar publishes to `state.json` for companion
/// tools. It is observation only, so these tests pin two things: the phases
/// come out in the right order for each mode, and watching them changes
/// nothing about what the adapter does to Spotify.

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: [AdapterPhase] = []
    private var _pids: [pid_t?] = []

    func record(_ phase: AdapterPhase, _ pid: pid_t?) {
        lock.lock()
        _phases.append(phase)
        _pids.append(pid)
        lock.unlock()
    }

    var phases: [AdapterPhase] {
        lock.lock()
        defer { lock.unlock() }
        return _phases
    }

    var pids: [pid_t?] {
        lock.lock()
        defer { lock.unlock() }
        return _pids
    }
}

private func adapter(_ fake: FakeSpotifyControl, _ mode: DuckMode, fade: TimeInterval = 0) -> SpotifyFadeAdapter {
    let adapter = SpotifyFadeAdapter(
        control: fake, mode: mode, fadeOutDuration: fade, fadeInDuration: fade)
    adapter.rereadDelay = 0
    adapter.fadeStepInterval = 0.05
    return adapter
}

@Test func fadeModeGoesDuckingDuckedResumingIdle() {
    let fake = FakeSpotifyControl()
    let log = PhaseLog()
    let adapter = adapter(fake, .fadeAndPause, fade: 0.1)
    adapter.onPhaseChange = { log.record($0, $1) }

    adapter.duckSync(source: "tap")
    #expect(adapter.phase == .ducked)
    adapter.restoreSync()
    #expect(adapter.phase == .idle)
    #expect(log.phases == [.ducking, .ducked, .resuming, .idle])
    #expect(log.pids == [1234, 1234, 1234, nil])
}

@Test func instantModeHasNoResumingPhase() {
    // Instant resumes in one command, so there is no window worth reporting.
    let fake = FakeSpotifyControl()
    let log = PhaseLog()
    let adapter = adapter(fake, .instant)
    adapter.onPhaseChange = { log.record($0, $1) }

    adapter.duckSync(source: "tap")
    adapter.restoreSync()
    #expect(log.phases == [.ducking, .ducked, .idle])
}

@Test func aSkippedDuckPublishesNothing() {
    // Spotify already paused: the adapter takes no ownership, so there is no
    // phase change to report.
    let fake = FakeSpotifyControl()
    fake.state = .paused
    let log = PhaseLog()
    let adapter = adapter(fake, .instant)
    adapter.onPhaseChange = { log.record($0, $1) }

    adapter.duckSync(source: "tap")
    adapter.restoreSync()
    adapter.reconcileSync()
    #expect(log.phases.isEmpty)
    #expect(adapter.phase == .idle)
    #expect(adapter.ownedPID == nil)
}

@Test func aRelinquishPublishesIdle() {
    let fake = FakeSpotifyControl()
    let log = PhaseLog()
    let adapter = adapter(fake, .instant)
    adapter.onPhaseChange = { log.record($0, $1) }

    adapter.duckSync(source: "tap")
    fake.state = .playing  // another process pressed play
    adapter.reconcileSync()
    #expect(log.phases == [.ducking, .ducked, .idle])
}

@Test func repeatedTicksDoNotRepublishTheSamePhase() {
    let fake = FakeSpotifyControl()
    let log = PhaseLog()
    let adapter = adapter(fake, .instant)
    adapter.onPhaseChange = { log.record($0, $1) }

    for _ in 0..<5 { adapter.duckSync(source: "tap") }
    for _ in 0..<5 { adapter.reconcileSync() }
    #expect(log.phases == [.ducking, .ducked])
}

@Test func observingPhasesDoesNotChangeWhatTheAdapterSendsToSpotify() {
    // The same cycle with and without an observer must issue the identical
    // command sequence.
    func run(observed: Bool) -> [String] {
        let fake = FakeSpotifyControl()
        let adapter = adapter(fake, .fadeAndPause, fade: 0.1)
        if observed { adapter.onPhaseChange = { _, _ in } }
        adapter.duckSync(source: "tap")
        adapter.reconcileSync()
        adapter.restoreSync()
        return fake.calls
    }
    #expect(run(observed: true) == run(observed: false))
}
