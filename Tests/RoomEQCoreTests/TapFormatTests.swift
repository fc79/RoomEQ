import Testing
@testable import RoomEQCore

@Suite("Tap format helpers")
struct TapFormatTests {
    @Test func sourceInSingleStream() throws {
        // An interface with one 10-channel output stream, preferred 1/2.
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

    /// Unknown rates (NaN, infinite, 0, negative, absurd) never crash and
    /// are named as unknown; the capture rate is named too.
    @Test func unknownRatesAreSafe() {
        for bad in [Double.nan, .infinity, -.infinity, 0, -48_000, 1e300] {
            #expect(AudioFormatText.kilohertz(bad) == "—", "\(bad)")
            #expect(AudioFormatText.kilohertzOrUnknown(bad) == "sconosciuta", "\(bad)")
            #expect(AudioFormatText.change(from: bad, to: 48_000) == "48 kHz", "\(bad)")
            #expect(AudioFormatText.change(from: 44_100, to: bad) == "—", "\(bad)")
            #expect(LatencyBreakdown(components: LatencyComponents(delayFrames: 64), sampleRate: bad).summary == "—")
            #expect(LatencyBreakdown(components: LatencyComponents(delayFrames: 64), sampleRate: bad).totalMilliseconds == 0)
        }
        for bad in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            #expect(AudioFormatText.oneDecimal(bad) == "—", "\(bad)")
        }
        #expect(
            SampleRateGuard.violation(tapRate: .nan, deviceRate: 48_000, captureRate: .infinity)
                == "Frequenza di campionamento sconosciuta (tap sconosciuta, dispositivo 48 kHz, "
                + "cattura sconosciuta): RoomEQ non si avvia.")
        #expect(SampleRateGuard.violation(tapRate: 48_000, deviceRate: 48_000, captureRate: 0)?.contains("cattura sconosciuta") == true)
        #expect(SampleRateGuard.violation(tapRate: 48_000, deviceRate: .nan, captureRate: 48_000) != nil)
    }
}
