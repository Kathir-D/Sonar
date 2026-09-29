import CoreAudio
import Foundation
import Testing
@testable import AutoPauseEngine

/// `TapMeter.rms(_:format:)` is the only thing standing between a Core Audio
/// IOProc and the loudness decision, so it is tested over real
/// `AudioBufferList` values built by hand - no device, no permission.
///
/// The layout that matters is the *non-interleaved* one: a tap delivers one
/// `AudioBuffer` per channel (`mNumberBuffers == channels`, each with
/// `mNumberChannels == 1`), while a plain device stream delivers a single
/// interleaved buffer. Squaring and summing is order-independent, so both
/// layouts must produce the *same* number; an implementation that assumed one
/// of them gets the wrong answer, and for the interleaved case it is wrong by a
/// factor of sqrt(channels) in one direction or the other.

private let tolerance = TestFormat.tolerance

/// Measures one entry of `samples` per `AudioBuffer`; pass a single entry for
/// an interleaved buffer.
private func floatRMS(
    channels: Int,
    buffers samples: [[Float]],
    format: TapAudioFormat? = nil,
    nonInterleaved: Bool = false
) -> Float? {
    let list = TestBufferList(bufferCount: samples.count)
    for (index, channel) in samples.enumerated() {
        list.set(channel, at: index, channels: nonInterleaved ? 1 : UInt32(channels))
    }
    return list.measure(format: format ?? TestFormat.float32(channels: channels))
}

private func int16RMS(
    channels: Int,
    buffers samples: [[Int16]],
    format: TapAudioFormat? = nil,
    nonInterleaved: Bool = false
) -> Float? {
    let list = TestBufferList(bufferCount: samples.count)
    for (index, channel) in samples.enumerated() {
        list.set(channel, at: index, channels: nonInterleaved ? 1 : UInt32(channels))
    }
    return list.measure(format: format ?? TestFormat.int16(channels: channels))
}

/// Builds a list with `bufferCount` buffers that carry no usable payload.
private func degenerateRMS(
    bufferCount: Int,
    byteSize: UInt32 = 0,
    hasData: Bool,
    channels: Int = 2
) -> Float? {
    let list = TestBufferList(bufferCount: bufferCount)
    let scratch = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
    defer { scratch.deallocate() }
    for index in 0..<bufferCount {
        list.setRaw(
            pointer: hasData ? scratch : nil,
            byteSize: byteSize,
            channels: 1,
            at: index,
            retain: false
        )
    }
    return list.measure(format: TestFormat.float32(channels: channels))
}

// MARK: - Interleaved float32

@Test func rmsOfAnInterleavedFloatBufferIsTheAmplitude() {
    let value = floatRMS(channels: 2, buffers: [.constant(0.5, frames: 1024)])
    #expect(value != nil)
    #expect(abs((value ?? -1) - 0.5) < tolerance)
}

@Test func rmsOfAnInterleavedBufferAveragesAcrossChannels() {
    // Right channel silent, left at full scale. A reader that only looked at
    // the first half of the buffer would answer 1.0.
    let value = floatRMS(
        channels: 2, buffers: [.interleaved(left: 1.0, right: 0.0, frames: 256)])
    let expected = Float(1 / Double(2).squareRoot())
    #expect(abs((value ?? -1) - expected) < tolerance)
}

@Test func rmsOfAMonoInterleavedBufferIsTheAmplitude() {
    let value = floatRMS(channels: 1, buffers: [.constant(0.25, frames: 64)])
    #expect(abs((value ?? -1) - 0.25) < tolerance)
}

@Test func rmsOfAnInterleavedSingleFrameBufferIsThatFrame() {
    // One frame of L=0.3, R=0.4: two samples, so the RMS is
    // sqrt((0.09 + 0.16) / 2), not sqrt(0.09 + 0.16) (which would be the sum
    // over one sample) and not the arithmetic mean (0.35).
    let value = floatRMS(channels: 2, buffers: [[0.3, 0.4]])
    let expected = Float(sqrt((0.09 + 0.16) / 2))
    #expect(abs((value ?? -1) - expected) < tolerance)
}

// MARK: - Non-interleaved float32 (what a tap actually delivers)

@Test func rmsOfANonInterleavedFloatPairIsTheAmplitude() {
    let value = floatRMS(
        channels: 2,
        buffers: [.constant(0.5, frames: 512), .constant(0.5, frames: 512)],
        nonInterleaved: true
    )
    #expect(abs((value ?? -1) - 0.5) < tolerance)
}

@Test func rmsOfANonInterleavedPairWithOneSilentChannelIsPeakOverSqrtTwo() {
    // The regression that matters most: one buffer per channel, left full
    // scale, right digital silence. This is the exact shape a stereo tap
    // delivers, and the shape a "just read buffer 0" implementation gets wrong
    // by sqrt(2) - a 3 dB error that moves a quiet sound across the threshold.
    let value = floatRMS(
        channels: 2,
        buffers: [.constant(1.0, frames: 512), .constant(0.0, frames: 512)],
        nonInterleaved: true
    )
    let expected = Float(1 / Double(2).squareRoot())
    #expect(abs((value ?? -1) - expected) < tolerance, "got \(value ?? -1), want \(expected)")
}

@Test func rmsOfANonInterleavedListCoversEveryBuffer() {
    // Three "channels" with different levels: all three must be pooled.
    let value = floatRMS(
        channels: 3,
        buffers: [.constant(0.2, frames: 128), .constant(0.4, frames: 128), .constant(0.6, frames: 128)],
        nonInterleaved: true
    )
    let expected = Float(sqrt((0.04 + 0.16 + 0.36) / 3))
    #expect(abs((value ?? -1) - expected) < tolerance)
}

@Test func interleavedAndNonInterleavedMeasurementsAgree() {
    // Property check: the layout is a storage detail and must not change the
    // measured loudness, including the mixed-silence corners where a
    // half-buffer reader diverges most.
    let levels: [Float] = [0, 0.1, 0.5, 1.0]
    for left in levels {
        for right in levels {
            let frames = 128
            let a = floatRMS(
                channels: 2, buffers: [.interleaved(left: left, right: right, frames: frames)]) ?? -1
            let b = floatRMS(
                channels: 2,
                buffers: [.constant(left, frames: frames), .constant(right, frames: frames)],
                nonInterleaved: true
            ) ?? -1
            #expect(abs(a - b) < tolerance, "L=\(left) R=\(right): interleaved \(a) vs planar \(b)")
        }
    }
}

@Test func nonInterleavedLayoutWithOneBufferPerChannelIsNotMistakenForInterleaved() {
    // Two buffers that look like one buffer's worth of data: the naive
    // "interleaved" read of a planar list would see 0.5 then 0.5 as if they
    // were L/R of a single frame and produce a different number.
    let value = floatRMS(
        channels: 2, buffers: [[0.5, 0.5], [0.5, 0.5]], nonInterleaved: true)
    #expect(abs((value ?? -1) - 0.5) < tolerance)
}

@Test func rmsIgnoresTheChannelsFieldAndUsesTheByteSize() {
    // The meter must derive the sample count from `mDataByteSize`, not from
    // `mNumberChannels`. HAL buffers routinely carry a `mNumberChannels` of 1
    // for every buffer of a non-interleaved pair, and vice versa on some paths;
    // trusting the wrong one halves or doubles the count and changes the
    // answer for any signal that is not stationary.
    let frames = 256
    let planar = floatRMS(
        channels: 2,
        buffers: [.constant(0.5, frames: frames), .constant(0.5, frames: frames)],
        // Deliberately lying: 1 channel in the format, 1 per buffer.
        format: TestFormat.float32(channels: 1, nonInterleaved: true),
        nonInterleaved: true
    )
    let honest = floatRMS(
        channels: 2,
        buffers: [.constant(0.5, frames: frames), .constant(0.5, frames: frames)],
        nonInterleaved: true
    )
    #expect(abs((planar ?? -1) - (honest ?? -2)) < tolerance)
}

// MARK: - int16 input

@Test func rmsOfInt16IsNormalisedToFullScale() {
    let half = int16RMS(channels: 1, buffers: [.constant(16384, frames: 256)])
    #expect(abs((half ?? -1) - 0.5) < tolerance)

    let full = int16RMS(channels: 1, buffers: [.constant(32767, frames: 256)])
    #expect(abs((full ?? -1) - 1.0) < tolerance)
}

@Test func rmsOfInt16IgnoresTheSign() {
    // -32768 must read as full scale, not as zero or as a negative RMS.
    let value = int16RMS(channels: 1, buffers: [.constant(-32768, frames: 256)])
    #expect(abs((value ?? -1) - 1.0) < tolerance)
}

@Test func rmsOfInterleavedInt16AveragesAcrossChannels() {
    let value = int16RMS(
        channels: 2, buffers: [.interleaved(left: 32767, right: 0, frames: 256)])
    let expected = Float(1 / Double(2).squareRoot())
    #expect(abs((value ?? -1) - expected) < tolerance)
}

@Test func rmsOfNonInterleavedInt16MatchesTheInterleavedValue() {
    let planar = int16RMS(
        channels: 2,
        buffers: [.constant(16384, frames: 256), .constant(-16384, frames: 256)],
        nonInterleaved: true
    )
    #expect(abs((planar ?? -1) - 0.5) < tolerance)
}

@Test func int16SampleCountComesFromTheInt16Width() {
    // The int16 path divides the byte size by the *int16* width, not by the
    // float width. Getting that wrong reads twice as many samples as exist and
    // walks off the end of the buffer, so the value here would be
    // unpredictable rather than merely wrong.
    let frames = 128
    let planar = int16RMS(
        channels: 2,
        buffers: [.constant(16384, frames: frames), .constant(16384, frames: frames)],
        nonInterleaved: true
    )
    #expect(abs((planar ?? -1) - 0.5) < tolerance)
}

@Test func floatAndInt16AgreeOnTheSameSignal() {
    // 16384/32768 is exactly half scale, and 0.5 is exactly half scale in
    // float: the `isFloat` flag must be honoured, not ignored.
    let asFloat = floatRMS(channels: 1, buffers: [.constant(0.5, frames: 256)])
    let asInt16 = int16RMS(channels: 1, buffers: [.constant(16384, frames: 256)])
    #expect(abs((asFloat ?? -1) - (asInt16 ?? -1)) < tolerance)
}

@Test func theInt16PathNormalisesRatherThanReadingTheBytesAsFloats() {
    // Control case for the flag test: int16 16384 is half scale, and read as a
    // float32 its bytes are 0x00004000, a denormal ~2.3e-41. So a meter that
    // ignored `isFloat` would return ~0 instead of 0.5 - a silent zero, which
    // is exactly the "tap looks alive and measures nothing" failure the whole
    // capture path exists to prevent. Asserting the flag is load-bearing is
    // therefore worth a test of its own.
    let asInt = int16RMS(channels: 1, buffers: [.constant(16384, frames: 256)])
    #expect(abs((asInt ?? -1) - 0.5) < tolerance)

    // The same bytes through the float path, which is the *wrong* format.
    let list = TestBufferList(bufferCount: 1)
    var raw = [UInt8](repeating: 0, count: 4 * 256)
    for index in stride(from: 0, to: raw.count, by: 4) {
        // 16384 == 0x4000, little-endian: 00 40 00 00.
        raw[index] = 0x00
        raw[index + 1] = 0x40
        raw[index + 2] = 0x00
        raw[index + 3] = 0x00
    }
    list.set(raw, at: 0, channels: 1)
    let asFloat = list.measure(format: TestFormat.float32(channels: 1))
    #expect(abs((asFloat ?? 1) - 0.5) > 0.1, "the float path must not read int16 bytes as audio")
}

// MARK: - Silence

@Test func rmsOfDigitalSilenceIsExactlyZero() {
    #expect(floatRMS(channels: 2, buffers: [.constant(0, frames: 1024)]) == 0)
    #expect(
        floatRMS(
            channels: 2,
            buffers: [.constant(0, frames: 512), .constant(0, frames: 512)],
            nonInterleaved: true) == 0)
    #expect(int16RMS(channels: 2, buffers: [.constant(0, frames: 512)]) == 0)
    #expect(
        int16RMS(
            channels: 2,
            buffers: [.constant(0, frames: 512), .constant(0, frames: 512)],
            nonInterleaved: true) == 0)
}

@Test func negativeZeroSilenceIsAlsoExactlyZero() {
    // -0.0 is what a real mixer emits for a silent interleaved frame. Its
    // square is +0.0, so the sum is +0.0 and the result must be +0.0, not NaN
    // and not -0.0 (which `== 0` would also accept, so the sign is checked
    // via the descriptor below).
    let value = floatRMS(channels: 2, buffers: [.constant(-0.0, frames: 256)])
    #expect(value == 0)
    #expect(value.map { $0.sign == .plus } ?? false)
}

// MARK: - Degenerate input: "no data" must never look like "silence"

@Test func rmsOfAnEmptyBufferListIsNil() {
    // Not 0. An empty list means "the tap delivered nothing this round", and
    // 0 is exactly what real silence looks like. Collapsing the two is how a
    // broken tap starts reading as a quiet room, which is the bug this whole
    // detector-preference path exists to survive.
    #expect(degenerateRMS(bufferCount: 0, hasData: false) == nil)
}

@Test func rmsOfAZeroLengthBufferIsNil() {
    #expect(degenerateRMS(bufferCount: 1, byteSize: 0, hasData: true) == nil)
}

@Test func rmsOfABufferWithNoDataPointerIsNil() {
    #expect(degenerateRMS(bufferCount: 2, byteSize: 4096, hasData: false) == nil)
}

@Test func rmsOfAMixOfUsableAndUnusableBuffersUsesTheUsableOnes() {
    // One channel of a two-channel block is fine; the whole block is not
    // thrown away because a single `mData` was null.
    let list = TestBufferList(bufferCount: 2)
    list.set(.constant(0.5, frames: 128), at: 0, channels: 1)
    let scratch = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
    defer { scratch.deallocate() }
    list.setRaw(pointer: nil, byteSize: 512, channels: 1, at: 1, retain: false)
    let value = list.measure(format: TestFormat.float32(channels: 2))
    #expect(abs((value ?? -1) - 0.5) < tolerance)
}

@Test func rmsOfAStarvedPairWhereOnlyOneChannelHasBytesUsesThatChannel() {
    // A HAL block whose right buffer is zero-length is still a real block. It
    // must measure the left channel, not collapse to nil: reporting nil here
    // would make a live tap look dead for one block.
    let list = TestBufferList(bufferCount: 2)
    list.set(.constant(0.5, frames: 128), at: 0, channels: 1)
    let scratch = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
    defer { scratch.deallocate() }
    list.setRaw(pointer: scratch, byteSize: 0, channels: 1, at: 1, retain: false)
    let value = list.measure(format: TestFormat.float32(channels: 2))
    #expect(abs((value ?? -1) - 0.5) < tolerance)
}

@Test func rmsIgnoresATrailingPartialSample() {
    // A block whose byte size is not a whole number of samples must be
    // truncated to the last complete sample, not rounded up into whatever
    // follows in memory.
    let list = TestBufferList(bufferCount: 1)
    let samples: [Float] = [0.5, 0.5, 0.5, 0.5, 1.0, 1.0, 1.0, 1.0]
    list.set(samples, at: 0, channels: 2)
    // Claim 4 samples + 2 bytes, i.e. one sample and a half of payload.
    list.setRaw(
        pointer: list.list[0].mData, byteSize: 4 * 4 + 2, channels: 2, at: 0, retain: false)
    let value = list.measure(format: TestFormat.float32(channels: 2))
    #expect(abs((value ?? -1) - 0.5) < tolerance, "a partial sample leaked in: \(value ?? -1)")
}

@Test func aByteSizeSmallerThanOneSampleIsNil() {
    // The int16 path divides by the int16 width, so a 1-byte buffer is
    // truncated to zero samples - and a zero-sample buffer must be nil, not a
    // division by zero and not 0.
    #expect(degenerateRMS(bufferCount: 1, byteSize: 1, hasData: true) == nil)
    #expect(degenerateRMS(bufferCount: 1, byteSize: 3, hasData: true) == nil)
}

// MARK: - The existing single-array meter still holds

@Test func theSampleArrayMeterAgreesWithTheBufferListMeter() {
    let samples = [Float].constant(0.4, frames: 1024)
    let arrayMeter = samples.withUnsafeBufferPointer { TapMeter.rms($0) }
    let listMeter = floatRMS(channels: 1, buffers: [samples]) ?? -1
    #expect(abs(arrayMeter - listMeter) < tolerance)
}

@Test func theSampleArrayMeterAndTheListMeterAgreeOnSilenceAndFullScale() {
    for level in [Float(0), 0.25, 1.0] {
        let samples = [Float].constant(level, frames: 512)
        let arrayMeter = samples.withUnsafeBufferPointer { TapMeter.rms($0) }
        let listMeter = floatRMS(channels: 1, buffers: [samples]) ?? -1
        #expect(abs(arrayMeter - listMeter) < tolerance, "level \(level)")
    }
}

@Test func theSampleArrayMeterIsEmptySafe() {
    // The array overload predates the buffer-list one and is still the seam
    // the diagnostics use; it must answer 0 (not crash, not NaN) for nothing.
    let empty: [Float] = []
    let rms = empty.withUnsafeBufferPointer { TapMeter.rms($0) }
    #expect(rms == 0)
}
