import CoreAudio
import Foundation

/// Read-only Core Audio helpers for the tests.
///
/// These read the live HAL. They never create, destroy or start anything, and
/// no assertion depends on which devices a particular machine has - only on
/// invariants that hold on every machine, including CI with no permissions
/// granted and no audio hardware. That is what keeps them safe in a suite that
/// has to pass unattended.

// MARK: - Device enumeration

/// Every audio device object the system knows about.
func allDeviceIDs() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
        size >= MemoryLayout<AudioObjectID>.size
    else { return [] }
    var ids = [AudioObjectID](
        repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
        return []
    }
    return ids
}

/// True when `id` answers the aggregate-device tap list. Only aggregates have
/// that property, which makes it a safe read-only way to tell one out of a
/// device list.
func isAggregateDevice(_ id: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyTapList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectHasProperty(id, &address)
}

func aggregateDeviceIDs() -> [AudioObjectID] {
    allDeviceIDs().filter { isAggregateDevice($0) }
}

/// The name the engine gives its tap and its aggregate, mirrored here so the
/// tests do not need access to a private constant.
func isSonarAggregateName(_ name: String?) -> Bool {
    guard let name else { return false }
    return name.trimmingCharacters(in: .whitespaces) == "Sonar auto-pause"
}

/// How many of this machine's aggregate devices are named like ours. A leaked
/// one from a crashed run is the thing `purgeStaleAggregates` exists to reap,
/// so a test that builds a tap and leaves it behind would show up here.
func countSonarAggregates() -> Int {
    aggregateDeviceIDs().filter { isSonarAggregateName(deviceName($0)) }.count
}

// MARK: - Property readers

func devicePropertyUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func devicePropertyString(
    _ id: AudioObjectID, _ selector: AudioObjectPropertySelector
) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<CFString?>.size)
    var raw: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw) == noErr else { return nil }
    return raw?.takeRetainedValue() as String?
}

func deviceName(_ id: AudioObjectID) -> String? {
    devicePropertyString(id, kAudioObjectPropertyName)
}
