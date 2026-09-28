// Ported from https://github.com/yasinozmeen/smartpause @ 69f3a9db31919b1e2ba4d1c6ba6f41564d6ed9b7
// (MIT 2026 Yasin Özmen). Detection logic is verbatim; comments translated to
// English; types made public for the Sonar app and tests.
// Full license text: THIRD-PARTY-NOTICES.md.

import AppKit
import CoreAudio
import Foundation

/// A process that is currently producing output audio (public Core Audio API,
/// macOS 14.2+). No audio-recording permission required. A single scan costs
/// ~14 ms, so callers invoke it on demand, not on a hot loop.
public struct AudioProcess: Sendable, Equatable {
    public let pid: pid_t
    public let bundleID: String
    public let responsiblePID: pid_t
    public let responsibleBundleID: String
    public let name: String

    public init(
        pid: pid_t,
        bundleID: String,
        responsiblePID: pid_t,
        responsibleBundleID: String,
        name: String
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.responsiblePID = responsiblePID
        self.responsibleBundleID = responsibleBundleID
        self.name = name
    }
}

public enum AudioDetector {
    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: sel,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ zero: T) -> T? {
        var a = addr(sel)
        var size = UInt32(MemoryLayout<T>.size)
        var v = zero
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var v: Unmanaged<CFString>? = nil
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v?.takeRetainedValue() as String?
    }

    /// Processes currently producing output audio.
    public static func runningOutputProcesses() -> [AudioProcess] {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard (get(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0,
                  let pid = get(id, kAudioProcessPropertyPID, Int32(0)) else { return nil }
            let bundle = getString(id, kAudioProcessPropertyBundleID) ?? ""
            let rpid = ResponsibleProcess.pid(for: pid)
            let rbundle = NSRunningApplication(processIdentifier: rpid)?.bundleIdentifier ?? bundle
            let name = NSRunningApplication(processIdentifier: rpid)?.localizedName
                ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            return AudioProcess(
                pid: pid,
                bundleID: bundle,
                responsiblePID: rpid,
                responsibleBundleID: rbundle,
                name: name
            )
        }
    }
}

/// Helper process (browser GPU/renderer, WebKit.GPU) -> responsible parent app.
/// `responsibility_get_pid_responsible_for_pid` is undocumented but is the
/// same libSystem function TCC itself uses. If it cannot be resolved, the pid
/// itself is returned (fail-safe). This one private-API call site is isolated
/// here and nowhere else.
public enum ResponsibleProcess {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    public static func pid(for pid: pid_t) -> pid_t {
        guard let fn else { return pid }
        let r = fn(pid)
        return r > 0 ? r : pid
    }
}
