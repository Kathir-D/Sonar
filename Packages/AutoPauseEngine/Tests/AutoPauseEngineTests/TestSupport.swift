import CoreAudio
import Foundation
@testable import AutoPauseEngine

/// Builds a real `AudioBufferList` in memory so the tap's meter can be tested
/// against the exact shape the HAL hands the IOProc, with no device, no
/// permission and no sleep.
///
/// `AudioBufferList.allocate(maximumBuffers:)` is the only allocator the SDK
/// offers, and it hands back an `UnsafeMutableAudioBufferListPointer` whose
/// `count` writes `mNumberBuffers`. Building this by hand (rather than passing
/// a `[Float]` array) matters: the tap delivers one `AudioBuffer` per channel,
/// and an implementation that assumes a single interleaved buffer is wrong by
/// a factor of sqrt(channels) - which is the class of bug that makes a working
/// tap read as silence.
final class TestBufferList {
    private let pointer: UnsafeMutableAudioBufferListPointer
    /// Every raw allocation made for this list, so nothing leaks.
    private var owned: [UnsafeMutableRawPointer] = []

    init(bufferCount: Int) {
        pointer = AudioBufferList.allocate(maximumBuffers: max(1, bufferCount))
        pointer.count = bufferCount
    }

    deinit {
        for raw in owned { raw.deallocate() }
        pointer.unsafeMutablePointer.deallocate()
    }

    /// A buffer of `frames` samples of `T`, one channel per entry.
    func set<T>(
        _ samples: [T],
        at index: Int,
        channels: UInt32 = 1
    ) {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: max(1, samples.count) * MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
        if samples.isEmpty {
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: 1)
        } else {
            samples.withUnsafeBytes { raw.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        owned.append(raw)
        pointer[index] = AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(samples.count) * UInt32(MemoryLayout<T>.size),
            mData: raw
        )
    }

    /// A buffer that carries a `mDataByteSize` the caller chose, so a
    /// deliberately mis-sized block can be built.
    func setRaw(
        pointer data: UnsafeMutableRawPointer?,
        byteSize: UInt32,
        channels: UInt32,
        at index: Int,
        retain: Bool
    ) {
        if retain { owned.append(data!) }
        pointer[index] = AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: byteSize,
            mData: data
        )
    }

    /// Run the engine's meter over this list and return the raw pointer it
    /// expects, keeping the list alive for the duration of the call.
    func measure(format: TapAudioFormat) -> Float? {
        TapMeter.rms(pointer, format: format)
    }

    var list: UnsafeMutableAudioBufferListPointer { pointer }
}

// MARK: - Formats

enum TestFormat {
    static let sampleRate: Double = 48_000
    static let tolerance: Float = 0.0001

    /// Float32, which is what a macOS aggregate's input stream settles on.
    static func float32(channels: Int, nonInterleaved: Bool = false) -> TapAudioFormat {
        TapAudioFormat(
            sampleRate: sampleRate,
            channels: channels,
            isFloat: true,
            bitsPerChannel: 32,
            isNonInterleaved: nonInterleaved
        )
    }

    /// Signed 16-bit integer, the other format the meter converts.
    static func int16(channels: Int, nonInterleaved: Bool = false) -> TapAudioFormat {
        TapAudioFormat(
            sampleRate: sampleRate,
            channels: channels,
            isFloat: false,
            bitsPerChannel: 16,
            isNonInterleaved: nonInterleaved
        )
    }
}

extension Array where Element == Float {
    /// A constant block of `frames` samples.
    static func constant(_ value: Float, frames: Int) -> [Float] {
        [Float](repeating: value, count: frames)
    }

    /// L,R,L,R... frames of two constant levels.
    static func interleaved(left: Float, right: Float, frames: Int) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(frames * 2)
        for _ in 0..<frames {
            out.append(left)
            out.append(right)
        }
        return out
    }
}

extension Array where Element == Int16 {
    static func constant(_ value: Int16, frames: Int) -> [Int16] {
        [Int16](repeating: value, count: frames)
    }

    static func interleaved(left: Int16, right: Int16, frames: Int) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(frames * 2)
        for _ in 0..<frames {
            out.append(left)
            out.append(right)
        }
        return out
    }
}
