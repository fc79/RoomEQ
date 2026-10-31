import Testing
@testable import RoomEQCore

@Suite("Tap format helpers")
struct TapFormatTests {
    @Test func sourceInSingleStream() throws {
        // Quantum: one 10-channel output stream, preferred 1/2.
        #expect(try TapSourceSelection.locate(preferred: (1, 2), streamChannelCounts: [10]).get()
            == TapSource(stream: 0, left: 0, right: 1))
        #expect(try TapSourceSelection.locate(preferred: (3, 4), streamChannelCounts: [10]).get()
            == TapSource(stream: 0, left: 2, right: 3))
        // No preference reported -> 1/2.
        #expect(try TapSourceSelection.locate(preferred: nil, streamChannelCounts: [2]).get()
            == TapSource(stream: 0, left: 0, right: 1))
    }

    @Test func sourceInSecondStream() throws {
        // Two 2-channel streams, preferred 3/4 -> stream 1, channels 0/1.
        #expect(try TapSourceSelection.locate(preferred: (3, 4), streamChannelCounts: [2, 2]).get()
            == TapSource(stream: 1, left: 0, right: 1))
    }

    @Test func refusesSplitOrInvalidPairs() {
        // L and R in different (mono) streams: refused, never duplicated.
        if case .success = TapSourceSelection.locate(preferred: (1, 2), streamChannelCounts: [1, 1]) {
            Issue.record("must refuse L/R in different streams")
        }
        if case .success = TapSourceSelection.locate(preferred: (2, 3), streamChannelCounts: [2, 2]) {
            Issue.record("must refuse L/R in different streams")
        }
        if case .success = TapSourceSelection.locate(preferred: (11, 12), streamChannelCounts: [10]) {
            Issue.record("must refuse out-of-range channels")
        }
        if case .success = TapSourceSelection.locate(preferred: (1, 1), streamChannelCounts: [2]) {
            Issue.record("must refuse L == R")
        }
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
}
