import CoreAudio
import Foundation
import Testing
@testable import AutoPauseEngine

/// `TapAudioFormat` is what the meter is told about the stream. It is read
/// back from the HAL rather than assumed, and the failure mode of getting it
/// wrong is silent: the buffers are reinterpreted as noise, or rejected, and
/// auto-pause quietly never fires. So the ASBD parsing is pinned case by case -
/// in particular, an unsupported format must be *rejected* rather than guessed
/// at, because a wrong guess is indistinguishable from a working tap.

/// A float32 Linear PCM ASBD, the shape a macOS aggregate input stream uses.
private func floatASBD(
    channels: UInt32 = 2,
    rate: Double = 48_000,
    nonInterleaved: Bool = false
) -> AudioStreamBasicDescription {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = rate
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    if nonInterleaved { asbd.mFormatFlags |= kAudioFormatFlagIsNonInterleaved }
    asbd.mBytesPerPacket = 4 * channels
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerFrame = 4 * channels
    asbd.mChannelsPerFrame = channels
    asbd.mBitsPerChannel = 32
    asbd.mReserved = 0
    return asbd
}

private func int16ASBD(channels: UInt32 = 2) -> AudioStreamBasicDescription {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = 44_100
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    asbd.mBytesPerPacket = 2 * channels
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerFrame = 2 * channels
    asbd.mChannelsPerFrame = channels
    asbd.mBitsPerChannel = 16
    asbd.mReserved = 0
    return asbd
}

// MARK: - Formats the meter can read

@Test func aFloat32ASBDParsesIntoATapAudioFormat() {
    let format = TapAudioFormat(floatASBD())
    #expect(format != nil)
    #expect(format?.sampleRate == 48_000)
    #expect(format?.channels == 2)
    #expect(format?.isFloat == true)
    #expect(format?.bitsPerChannel == 32)
    #expect(format?.isNonInterleaved == false)
}

@Test func aNonInterleavedASBDIsReportedAsNonInterleaved() {
    // This flag is the one that explains the "one AudioBuffer per channel"
    // shape in the diagnostics log. If it were never set the log would
    // contradict what a debugger shows on the buffer list.
    #expect(TapAudioFormat(floatASBD(nonInterleaved: true))?.isNonInterleaved == true)
}

@Test func aSignedInt16ASBDParsesAsAnIntegerFormat() {
    let format = TapAudioFormat(int16ASBD())
    #expect(format?.isFloat == false)
    #expect(format?.bitsPerChannel == 16)
    #expect(format?.channels == 2)
    #expect(format?.sampleRate == 44_100)
}

@Test func aMonoStreamParsesAsMono() {
    #expect(TapAudioFormat(floatASBD(channels: 1))?.channels == 1)
}

@Test func aZeroChannelCountIsClampedToOne() {
    // A stream that reports zero channels is nonsense, but "one" keeps the
    // frame math from dividing by zero, and it is still honest to say the
    // stream is mono rather than to claim it has no channels at all.
    var asbd = floatASBD()
    asbd.mChannelsPerFrame = 0
    #expect(TapAudioFormat(asbd)?.channels == 1)
}

// MARK: - Formats the meter must refuse

@Test func aCompressedFormatIsRejected() {
    var asbd = floatASBD()
    asbd.mFormatID = kAudioFormatMPEG4AAC
    asbd.mFormatFlags = 0
    #expect(TapAudioFormat(asbd) == nil)
}

@Test func aLinearPCMFormatWithNoConversionPathIsRejected() {
    // 24-bit integer: Linear PCM, signed, but neither 32-bit float nor 16-bit
    // int. Guessing here is the dangerous move - reading 24-bit samples as
    // float32 yields plausible-looking garbage.
    var asbd = int16ASBD()
    asbd.mBitsPerChannel = 24
    asbd.mBytesPerFrame = 3 * 2
    asbd.mBytesPerPacket = 3 * 2
    #expect(TapAudioFormat(asbd) == nil)
}

@Test func aDoubleFormatIsRejected() {
    // 64-bit float is a real and supported HAL format; the meter does not
    // convert it, so it must be reported unsupported rather than read as
    // float32 (which would give a plausible wrong number).
    var asbd = floatASBD()
    asbd.mBitsPerChannel = 64
    asbd.mBytesPerFrame = 8 * 2
    asbd.mBytesPerPacket = 8 * 2
    #expect(TapAudioFormat(asbd) == nil)
}

@Test func anUnsignedIntegerFormatIsRejected() {
    // Unsigned 8/16-bit PCM is a different scale entirely; normalising it with
    // the signed scale would read it as very loud.
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = 48_000
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = kAudioFormatFlagIsPacked
    asbd.mBytesPerPacket = 2
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerFrame = 2
    asbd.mChannelsPerFrame = 1
    asbd.mBitsPerChannel = 16
    #expect(TapAudioFormat(asbd) == nil)
}

// MARK: - Frames-per-buffer, the diagnostics-only derived value

@Test func framesPerBufferUsesTheInterleavedFrameWidth() {
    // 48 kHz float32 stereo: one frame is 8 bytes, so a 4096-byte buffer holds
    // 512 frames.
    let format = TestFormat.float32(channels: 2)
    #expect(format.frames(perBufferByteSize: 4096) == 512)
}

@Test func framesPerBufferUsesOneSampleForANonInterleavedBuffer() {
    // In a non-interleaved list each buffer is one channel, so a buffer's
    // frame count is its sample count, not samples/channels.
    let format = TestFormat.float32(channels: 2, nonInterleaved: true)
    #expect(format.frames(perBufferByteSize: 4096) == 1024)
}

@Test func framesPerBufferTruncatesAPartialFrame() {
    let format = TestFormat.float32(channels: 2)
    // 4097 bytes is 512 whole frames plus one stray byte.
    #expect(format.frames(perBufferByteSize: 4097) == 512)
}

@Test func framesPerBufferOfAZeroByteBufferIsZero() {
    // The starved-tap case: the buffer list is well-formed but empty.
    let format = TestFormat.float32(channels: 2)
    #expect(format.frames(perBufferByteSize: 0) == 0)
}

@Test func framesPerBufferIsInt16WidthAware() {
    let format = TestFormat.int16(channels: 2)
    // 4 bytes per frame at 16-bit stereo -> 8 frames in 32 bytes.
    #expect(format.frames(perBufferByteSize: 32) == 8)
}

// MARK: - The value type itself

@Test func tapAudioFormatDefaultsToInterleaved() {
    // The default matters: a caller that constructs a format by hand without
    // thinking about the layout gets the device-stream shape, which is also
    // what the RMS comes out as, so it is a safe default.
    let format = TapAudioFormat(
        sampleRate: 48_000, channels: 2, isFloat: true, bitsPerChannel: 32)
    #expect(format.isNonInterleaved == false)
}

@Test func tapAudioFormatIsEquatableSoTheTapCanCompareFormats() {
    let a = TestFormat.float32(channels: 2, nonInterleaved: true)
    var b = TestFormat.float32(channels: 2, nonInterleaved: true)
    #expect(a == b)
    b.channels = 1
    #expect(a != b)
    b.channels = 2
    b.bitsPerChannel = 16
    #expect(a != b)
}
