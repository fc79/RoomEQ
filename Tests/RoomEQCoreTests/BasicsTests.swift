import Testing
@testable import RoomEQCore

@Suite("Latency math")
struct LatencyTests {
    @Test func breakdownAt44100() {
        let components = LatencyComponents(
            inputDeviceFrames: 10, inputSafetyOffsetFrames: 20, inputStreamFrames: 14,
            bufferFrames: 128,
            outputDeviceFrames: 100, outputSafetyOffsetFrames: 32, outputStreamFrames: 9)
        let latency = LatencyBreakdown(components: components, sampleRate: 44100)

        #expect(latency.inputFrames == 44)
        #expect(latency.bufferingFrames == 256)
        #expect(latency.outputFrames == 141)
        #expect(latency.totalFrames == 441)
        // 441 frames at 44.1 kHz is exactly 10 ms.
        #expect(abs(latency.totalMilliseconds - 10.0) < 1e-9)
        #expect(abs(latency.bufferingMilliseconds - 256.0 / 44.1) < 1e-9)
        #expect(latency.summary.hasPrefix("10.0 ms"))
    }

    @Test func unknownSampleRateGivesZero() {
        let latency = LatencyBreakdown(components: LatencyComponents(bufferFrames: 64), sampleRate: 0)
        #expect(latency.totalMilliseconds == 0)
    }
}

@Suite("Status codes")
struct StatusCodeTests {
    @Test func fourCharCode() {
        // 'nope' = kAudioHardwareIllegalOperationError
        #expect(describeOSStatus(1_852_797_029) == "'nope' (1852797029)")
        #expect(fourCharCodeString(0x77686F3F) == "who?")
    }

    @Test func plainNumber() {
        #expect(describeOSStatus(-50) == "-50")
        #expect(describeOSStatus(0) == "0")
    }
}

@Suite("Output channel pairs")
struct OutputChannelPairTests {
    @Test func pairsForTenChannels() {
        let pairs = OutputChannelPair.available(forChannelCount: 10)
        #expect(pairs.map(\.description) == ["1–2", "3–4", "5–6", "7–8", "9–10"])
    }

    @Test func oddAndTinyCounts() {
        #expect(OutputChannelPair.available(forChannelCount: 3).count == 1)
        #expect(OutputChannelPair.available(forChannelCount: 1).isEmpty)
        #expect(OutputChannelPair(left: 3).left == 2)
    }

    @Test func packing() {
        let pair = OutputChannelPair(left: 6)
        let unpacked = OutputChannelPair.unpack(pair.packed)
        #expect(unpacked.left == 6 && unpacked.right == 7)
    }
}

@Suite("Buffer sizes")
struct BufferSizeTests {
    @Test func optionsWithinRange() {
        #expect(BufferSize.options(minimum: 15, maximum: 4096) == [64, 128, 256])
        #expect(BufferSize.options(minimum: 100, maximum: 4096) == [128, 256])
        #expect(BufferSize.options(minimum: 512, maximum: 4096) == [512])
        #expect(BufferSize.clamp(64, minimum: 100, maximum: 200) == 100)
    }
}

@Suite("Decibels")
struct DecibelTests {
    @Test func roundTrip() {
        #expect(Decibels.linear(fromDecibels: 0) == 1)
        #expect(abs(Decibels.decibels(fromLinear: 0.5) + 6.0206) < 1e-3)
        #expect(Decibels.decibels(fromLinear: 0) == Decibels.floor)
    }
}
