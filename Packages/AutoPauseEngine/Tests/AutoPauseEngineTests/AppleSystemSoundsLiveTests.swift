import Darwin
import Foundation
import Testing
@testable import AutoPauseEngine

/// The classifier against the real kernel, not hand-written paths. The fixed
/// cases live in `PollRulesTests`; this file checks the one assumption they
/// cannot: that `proc_pidpath` really reports the daemon where the rules
/// expect it.

/// Every pid on the machine whose executable sits at `path`.
private func pids(at path: String) -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var all = [pid_t](repeating: 0, count: Int(count) * 2)
    let filled = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    return all.prefix(Int(filled)).filter { AppleSystemSounds.executablePath(of: $0) == path }
}

private let daemonPath = "/usr/sbin/systemsoundserverd"

@Test(.enabled(if: !pids(at: daemonPath).isEmpty, "systemsoundserverd is not running here"))
func theLiveSystemSoundDaemonIsRecognised() throws {
    let pid = try #require(pids(at: daemonPath).first)
    let path = try #require(AppleSystemSounds.executablePath(of: pid))
    #expect(path == daemonPath)
    #expect(AppleSystemSounds.isSystemSoundPlayer(executablePath: path))
}

@Test func theTestProcessIsNotASystemSound() throws {
    let path = try #require(AppleSystemSounds.executablePath(of: getpid()))
    #expect(!AppleSystemSounds.isSystemSoundPlayer(executablePath: path))
}

@Test func noPathForAPidThatDoesNotExist() {
    #expect(AppleSystemSounds.executablePath(of: 0) == nil)
    #expect(AppleSystemSounds.executablePath(of: -1) == nil)
    #expect(AppleSystemSounds.executablePath(of: pid_t(Int32.max)) == nil)
}
