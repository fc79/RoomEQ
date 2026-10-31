import Testing
@testable import RoomEQCore

@Suite("Tap format helpers")
struct TapFormatTests {
    @Test func stereoPairSelection() {
        #expect(TapChannelSelection.stereoPair(tapChannels: 1, preferredStereo: nil) == (0, 0))
        #expect(TapChannelSelection.stereoPair(tapChannels: 2, preferredStereo: nil) == (0, 1))
        #expect(TapChannelSelection.stereoPair(tapChannels: 2, preferredStereo: (1, 2)) == (0, 1))
        // Quantum: 10-channel tap, preferred stereo 1/2 or 3/4.
        #expect(TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (1, 2)) == (0, 1))
        #expect(TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (3, 4)) == (2, 3))
        // Invalid preferences fall back to the first two channels.
        #expect(TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (11, 12)) == (0, 1))
        #expect(TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (2, 2)) == (0, 1))
    }

    @Test func preferredChannelsRelativeToStream() {
        // Device with two 2-channel streams; preferred 3/4 are channels 1/2 of stream 1.
        let within = TapChannelSelection.preferredWithinStream((3, 4), streamFirstChannel: 3)
        #expect(within.map { [$0.0, $0.1] } == [1, 2])
        #expect(TapChannelSelection.preferredWithinStream(nil, streamFirstChannel: 1) == nil)
    }

    @Test func formatText() {
        #expect(AudioFormatText.summary(sampleRate: 44100, channels: 10) == "44,1 kHz · 10 ch")
        #expect(AudioFormatText.kilohertz(48000) == "48 kHz")
        #expect(AudioFormatText.kilohertz(88200) == "88,2 kHz")
    }

    @Test func noSampleRateConversionGuard() {
        #expect(SampleRateGuard.violation(tapRate: 44100, deviceRate: 44100, captureRate: 44100) == nil)
        let tapMismatch = SampleRateGuard.violation(tapRate: 48000, deviceRate: 44100, captureRate: 44100)
        #expect(
            tapMismatch
                == "La frequenza del tap (48 kHz) non coincide con quella del dispositivo (44,1 kHz): "
                + "RoomEQ non converte la frequenza, quindi non si avvia.")
        #expect(SampleRateGuard.violation(tapRate: 44100, deviceRate: 44100, captureRate: 48000) != nil)
        #expect(SampleRateGuard.violation(tapRate: 0, deviceRate: 44100, captureRate: 44100) != nil)
    }

    @Test func splitLatencyComponents() {
        // Quantum at 64: delay 220 frames, safety 17 + 11, device latency 32.
        let components = LatencyComponents.split(
            delayFrames: 220, tapExtraFrames: 0, tapStreamFrames: 0, captureSafetyOffsetFrames: 17,
            bufferFrames: 64, outputSafetyOffsetFrames: 11, outputDeviceFrames: 32, outputStreamFrames: 0)
        let latency = LatencyBreakdown(components: components, sampleRate: 44100)
        #expect(components.ringFrames == 220 - 17 - 128 - 11)
        #expect(latency.totalFrames == 220 + 32)
        #expect(latency.summary.hasPrefix("Stima 5.7 ms"))
    }
}
