import Foundation
import Testing
@testable import RoomEQCore

@Suite("Clip indicator")
struct ClipIndicatorTests {
    let rate = 48_000.0

    func status(_ handle: RenderStateHandle, baseline: ClipCounters = .zero) -> ClipStatus {
        ClipStatus(counters: handle.readClipCounters(), baseline: baseline)
    }

    /// The source itself over full scale (EQ off): input overs, no
    /// EQ-caused overs, no preamp suggestion.
    @Test func sourceOversAreCountedAsInput() {
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: [], bypass: true)
        let input: [Float] = (0..<512).map { $0 % 64 == 0 ? 1.5 : 0.5 }  // 8 overs per channel
        _ = DSPTest.render(handle, input)
        let clip = status(handle)
        #expect(clip.inputClippedSamples == 16 && clip.outputClippedSamples == 16)
        #expect(clip.processingClippedSamples == 0)
        #expect(!clip.eqCausedClipping && clip.sourceClipping && clip.isClipping)
        #expect(abs(clip.maxInputOverDecibels! - 20 * log10(1.5)) < 1e-4)
        #expect(abs(clip.maxOutputOverDecibels! - 20 * log10(1.5)) < 1e-4)
        #expect(clip.suggestedPreamp(currentPreamp: 0) == nil)
    }

    /// A boost pushes a clean 0,9 sine over full scale: EQ-caused.
    @Test func eqBoostOversAreClassifiedAndMeasured() {
        let boost = EQDesign(bands: [EQBand(frequency: 1000, gain: 6, q: 1)], sampleRate: rate).sections
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: boost)
        let input = DSPTest.sine(frequency: 1000, sampleRate: rate, amplitude: 0.9, count: 48_000)
        let output = DSPTest.render(handle, input)
        let clip = status(handle)
        #expect(clip.inputClippedSamples == 0 && clip.maxInputOverDecibels == nil)
        #expect(clip.outputClippedSamples > 0 && clip.processingClippedSamples == clip.outputClippedSamples)
        #expect(clip.eqCausedClipping && !clip.sourceClipping)
        let expectedOver = 20 * log10(0.9) + 6  // +5,08 dB
        #expect(abs(clip.maxProcessingOverDecibels! - expectedOver) < 0.05)
        #expect(abs(clip.maxOutputOverDecibels! - expectedOver) < 0.05)
        let suggested = clip.suggestedPreamp(currentPreamp: 0)!
        #expect(suggested == -5.1)  // rounded DOWN (more attenuation) to 0,1 dB
        #expect(output.allSatisfy { abs($0) <= 1 })  // still clamped
        // With that preamp the same material doesn't clip any more.
        let fixed = DSPTest.makeHandle(sampleRate: rate, filters: boost, gain: Preamp.linearGain(decibels: suggested)!)
        _ = DSPTest.render(fixed, input)
        #expect(!status(fixed).isClipping)
    }

    /// Why an ALL-CUT EQ can clip: cutting part of the spectrum changes the
    /// waveform's shape (phase), so peaks of a signal close to 0 dBFS can
    /// rise above it although no frequency is boosted.
    @Test func allCutEQCanRaisePeaksAboveFullScale() {
        let cuts = EQDesign(bands: EQBand.defaultBands(), sampleRate: rate).sections
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: cuts)
        // 58,8 Hz-ish square wave at -0,4 dBFS (cuts at 58,8 / 76,6 / 140 / 192 Hz).
        let input: [Float] = (0..<96_000).map { sin(2 * Double.pi * 70 * Double($0) / rate) >= 0 ? 0.955 : -0.955 }
        _ = DSPTest.render(handle, input)
        let clip = status(handle)
        #expect(clip.inputClippedSamples == 0)
        #expect(clip.eqCausedClipping, "max output \(clip.maxOutputOverDecibels.map { String($0) } ?? "≤ 0") dB")
        #expect(clip.suggestedPreamp(currentPreamp: 0).map { $0 < 0 } == true)
    }

    /// Reset: counts restart from the baseline, max levels from 0; later
    /// overs are counted again; a new session starts at 0.
    @Test func resetAcrossBlocks() {
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: [])
        let over: [Float] = [Float](repeating: 0.5, count: 255) + [1.2]
        let clean = [Float](repeating: 0.5, count: 256)
        _ = DSPTest.render(handle, over)
        _ = DSPTest.render(handle, over)
        #expect(status(handle).outputClippedSamples == 4)

        let baseline = handle.resetClipMaxima()
        #expect(status(handle, baseline: baseline) == .none)
        _ = DSPTest.render(handle, clean)
        #expect(status(handle, baseline: baseline) == .none)
        _ = DSPTest.render(handle, [Float](repeating: 0.5, count: 255) + [1.1])
        let after = status(handle, baseline: baseline)
        #expect(after.outputClippedSamples == 2 && after.inputClippedSamples == 2)
        #expect(abs(after.maxOutputOverDecibels! - 20 * log10(1.1)) < 1e-4)  // not the old 1,2

        // A baseline from an older session (larger counts) means "from 0".
        let fresh = DSPTest.makeHandle(sampleRate: rate, filters: [])
        _ = DSPTest.render(fresh, [Float](repeating: 0.5, count: 255) + [1.3])
        #expect(status(fresh, baseline: ClipCounters(inputOvers: 99, outputOvers: 99)).outputClippedSamples == 2)
    }

    /// The analysis doesn't change the audio: same output with and without
    /// resets in between, overs clamped exactly as before.
    @Test func noEffectOnAudio() {
        let boost = EQDesign(bands: [EQBand(frequency: 500, gain: 8, q: 2)], sampleRate: rate).sections
        let input = DSPTest.sine(frequency: 500, sampleRate: rate, amplitude: 0.8, count: 9600)
        let a = DSPTest.makeHandle(sampleRate: rate, filters: boost)
        let b = DSPTest.makeHandle(sampleRate: rate, filters: boost)
        let outA = DSPTest.render(a, input)
        let outB = DSPTest.render(b, input) { _, _ in _ = b.resetClipMaxima() }
        #expect(outA == outB)
        #expect(outA.allSatisfy { abs($0) <= 1 })
        #expect(a.readMeters().clippedSamples == status(a).outputClippedSamples)  // legacy counter intact
    }

    @Test func suggestionRoundingAndLimits() {
        var counters = ClipCounters(outputOvers: 10, processingOvers: 10, maxOutputLevel: 1.1, maxProcessingOverLevel: 1.1)
        var clip = ClipStatus(counters: counters, baseline: .zero)  // +0,83 dB
        #expect(clip.suggestedPreamp(currentPreamp: -2) == -2.9)
        #expect(clip.suggestedPreamp(currentPreamp: -23.5) == -24)  // never below -24
        counters.maxProcessingOverLevel = 1.0001
        clip = ClipStatus(counters: counters, baseline: .zero)
        #expect(clip.suggestedPreamp(currentPreamp: 0) == -0.1)
        #expect(ClipStatus.none.suggestedPreamp(currentPreamp: 0) == nil)
        #expect(ClipStatus.none.maxOutputOverDecibels == nil && !ClipStatus.none.isClipping)
    }
}
