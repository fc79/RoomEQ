import Testing
@testable import RoomEQCore

@Suite("Latency math")
struct LatencyTests {
    @Test func splitBreakdownDoesNotDoubleCountTheDelay() {
        // Quantum at 64: delay 220 frames (already contains safeties and
        // buffers), device latency 32, no tap or stream latency.
        let components = LatencyComponents(
            delayFrames: 220, outputDeviceFrames: 32, bufferFrames: 64, captureSafetyOffsetFrames: 17,
            outputSafetyOffsetFrames: 11)
        let latency = LatencyBreakdown(components: components, sampleRate: 44100)
        #expect(latency.roomEQFrames == 220)
        #expect(latency.outputFrames == 32)
        #expect(latency.totalFrames == 252)
        #expect(abs(latency.totalMilliseconds - 252 / 44.1) < 1e-9)
        #expect(latency.summary == "Stima 5,7 ms (RoomEQ 5,0 + uscita 0,7) a 44,1 kHz")
        let at48 = LatencyBreakdown(components: LatencyComponents(delayFrames: 288), sampleRate: 48_000)
        #expect(at48.summary == "Stima 6,0 ms (RoomEQ 6,0 + uscita 0,0) a 48 kHz")
    }

    @Test func tapPathLatencyIsAddedAndNothingIsNegative() {
        let latency = LatencyBreakdown(
            components: LatencyComponents(delayFrames: 100, tapExtraFrames: 5, tapStreamFrames: 7,
                                          outputDeviceFrames: -3, outputStreamFrames: 639),
            sampleRate: 44100)
        #expect(latency.roomEQFrames == 112)
        #expect(latency.outputFrames == 639)
    }

    @Test func unknownSampleRateGivesZero() {
        let latency = LatencyBreakdown(components: LatencyComponents(delayFrames: 64), sampleRate: 0)
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
