import Foundation
import Testing
@testable import RoomEQCore

/// Direct evaluation of |H(e^jw)| with complex arithmetic (reference for
/// the phi formula used by the app).
private func directMagnitudeDecibels(_ c: BiquadCoefficients, frequency: Double, sampleRate: Double) -> Double {
    let w = 2 * Double.pi * frequency / sampleRate
    let nRe = c.b0 + c.b1 * cos(w) + c.b2 * cos(2 * w)
    let nIm = -(c.b1 * sin(w) + c.b2 * sin(2 * w))
    let dRe = 1 + c.a1 * cos(w) + c.a2 * cos(2 * w)
    let dIm = -(c.a1 * sin(w) + c.a2 * sin(2 * w))
    return 10 * log10((nRe * nRe + nIm * nIm) / (dRe * dRe + dIm * dIm))
}

private let defaultBands = EQBand.defaultBands()
private let testRates: [Double] = [44_100, 48_000, 96_000]

@Suite("Biquad design")
struct BiquadDesignTests {
    @Test func defaultBandsAreTheUsersREWFilters() {
        let bands = EQBand.defaultBands()
        #expect(bands.map(\.frequency) == [58.80, 76.60, 140.0, 192.0])
        #expect(bands.map(\.gain) == [-9.90, -6.80, -15.90, -5.40])
        #expect(bands.map(\.q) == [10.664, 14.316, 4.267, 3.628])
        #expect(bands.allSatisfy { $0.isEnabled })
    }

    /// Requirement: for each default band at 44.1/48/96 kHz the analytic
    /// magnitude of the computed coefficients at Fc equals the gain (0.1 dB).
    @Test(arguments: testRates + [192_000])
    func magnitudeAtCentreEqualsGain(sampleRate: Double) throws {
        for band in defaultBands {
            let c = try #require(BiquadCoefficients.peaking(
                frequency: band.frequency, gainDecibels: band.gain, q: band.q, sampleRate: sampleRate))
            let response = c.magnitudeDecibels(atFrequency: band.frequency, sampleRate: sampleRate)
            #expect(abs(response - band.gain) < 0.1, "\(band.frequency) Hz at \(sampleRate): \(response) dB")
            // In fact it is exact to numerical precision.
            #expect(abs(response - band.gain) < 1e-6)
            // Cross-check of the phi formula against direct complex evaluation.
            let direct = directMagnitudeDecibels(c, frequency: band.frequency, sampleRate: sampleRate)
            #expect(abs(direct - band.gain) < 1e-3)
            // Far away from Fc a peaking filter is flat.
            #expect(abs(c.magnitudeDecibels(atFrequency: 10_000, sampleRate: sampleRate)) < 0.05)
        }
    }

    @Test func phiFormulaMatchesDirectEvaluation() throws {
        let c = try #require(BiquadCoefficients.peaking(frequency: 1000, gainDecibels: 6, q: 2, sampleRate: 48_000))
        for frequency in [20.0, 100, 500, 999, 1000, 1500, 5000, 15_000, 23_000] {
            let analytic = c.magnitudeDecibels(atFrequency: frequency, sampleRate: 48_000)
            let direct = directMagnitudeDecibels(c, frequency: frequency, sampleRate: 48_000)
            #expect(abs(analytic - direct) < 1e-9)
        }
    }

    @Test func zeroGainIsIdentity() throws {
        let c = try #require(BiquadCoefficients.peaking(frequency: 1000, gainDecibels: 0, q: 1, sampleRate: 48_000))
        #expect(abs(c.b0 - 1) < 1e-15 && abs(c.b1 - c.a1) < 1e-15 && abs(c.b2 - c.a2) < 1e-15)
    }

    @Test(arguments: testRates + [192_000])
    func defaultBandsAreStable(sampleRate: Double) throws {
        for band in defaultBands {
            let c = try #require(BiquadCoefficients.peaking(
                frequency: band.frequency, gainDecibels: band.gain, q: band.q, sampleRate: sampleRate))
            #expect(c.isStable)
            #expect(c.poleRadius < 1)
        }
    }

    @Test func invalidParametersGiveNoCoefficients() {
        let rate = 48_000.0
        #expect(BiquadCoefficients.peaking(frequency: .nan, gainDecibels: 0, q: 1, sampleRate: rate) == nil)
        #expect(BiquadCoefficients.peaking(frequency: 100, gainDecibels: .infinity, q: 1, sampleRate: rate) == nil)
        #expect(BiquadCoefficients.peaking(frequency: 100, gainDecibels: 0, q: 0, sampleRate: rate) == nil)
        #expect(BiquadCoefficients.peaking(frequency: 100, gainDecibels: 0, q: -1, sampleRate: rate) == nil)
        #expect(BiquadCoefficients.peaking(frequency: 0, gainDecibels: 0, q: 1, sampleRate: rate) == nil)
        #expect(BiquadCoefficients.peaking(frequency: 24_000, gainDecibels: 0, q: 1, sampleRate: rate) == nil)
        #expect(BiquadCoefficients.peaking(frequency: 100, gainDecibels: 0, q: 1, sampleRate: 0) == nil)
    }
}

@Suite("EQ design validation")
struct EQDesignTests {
    @Test func allDefaultBandsBecomeSectionsInOrder() {
        let design = EQDesign(bands: defaultBands, sampleRate: 48_000)
        #expect(design.sections.count == 4)
        #expect(design.issues.isEmpty && design.warnings.isEmpty)
        let ids = defaultBands.map { FilterSection.idParts($0.id) }
        #expect(design.sections.map(\.bandIDHigh) == ids.map(\.high))
        #expect(design.sections.map(\.bandIDLow) == ids.map(\.low))
        // High-Q bass bands need a long warm-up (but at most 250 ms).
        #expect(design.sections.allSatisfy { $0.settleFrames > 0 && $0.settleFrames <= 12_000 })
    }

    @Test func disabledBandsAreLeftOutWithoutWarning() {
        var bands = defaultBands
        bands[1].isEnabled = false
        let design = EQDesign(bands: bands, sampleRate: 48_000)
        #expect(design.sections.count == 3)
        #expect(design.warnings.isEmpty)
    }

    /// Fc >= 0.45 Fs: disabled with a warning, never NaN.
    @Test func frequencyTooHighForTheSampleRateIsDisabledWithWarning() {
        let band = EQBand(frequency: 19_900, gain: -3, q: 2)  // 0.45 * 44100 = 19845
        let at44 = EQDesign(bands: [band], sampleRate: 44_100)
        #expect(at44.sections.isEmpty)
        let message = at44.issues[band.id]
        #expect(message == "Filtro 1: frequenza troppo alta per 44,1 kHz (massimo 19845 Hz), disattivato")
        #expect(at44.warnings == [message!])
        // The same band is fine at 48 kHz (limit 21600 Hz).
        #expect(EQDesign(bands: [band], sampleRate: 48_000).sections.count == 1)
    }

    @Test func invalidValuesAreDisabledWithWarningsAndNeverNaN() {
        let bands = [
            EQBand(frequency: .nan, gain: 0, q: 1),
            EQBand(frequency: 100, gain: .infinity, q: 1),
            EQBand(frequency: 100, gain: -3, q: 0),
            EQBand(frequency: 100, gain: -3, q: -2),
            EQBand(frequency: 100, gain: -3, q: .nan),
            EQBand(frequency: 0, gain: -3, q: 1),
            EQBand(frequency: 100, gain: 45, q: 1),
            EQBand(frequency: 100, gain: -3, q: 500),
            EQBand(frequency: 1000, gain: -3, q: 1),  // the only valid one
        ]
        let design = EQDesign(bands: bands, sampleRate: 48_000)
        #expect(design.sections.count == 1)
        #expect(design.warnings.count == 8)
        #expect(design.warnings.allSatisfy { $0.hasSuffix("disattivato") })
        #expect(design.warnings[0] == "Filtro 1: parametri non validi, disattivato")
        #expect(design.warnings[6] == "Filtro 7: guadagno fuori dall'intervallo -30…+30 dB, disattivato")
        #expect(design.warnings[7] == "Filtro 8: Q fuori dall'intervallo 0,1…100, disattivato")
        for section in design.sections {
            let c = section.coefficients
            #expect([c.b0, c.b1, c.b2, c.a1, c.a2].allSatisfy { $0.isFinite })
        }
        // The curve stays finite too.
        let curve = EQCurve.responseDecibels(
            coefficients: design.coefficients, sampleRate: 48_000, frequencies: EQCurve.logFrequencies())
        #expect(curve.allSatisfy { $0.isFinite })
    }

    @Test func clampedBringsBandsIntoRange() {
        let band = EQBand(frequency: 50_000, gain: -99, q: .nan).clamped()
        #expect(band.frequency == 20_000 && band.gain == -30 && band.q == 1)
        let low = EQBand(frequency: 1, gain: 99, q: 0.001).clamped()
        #expect(low.frequency == 10 && low.gain == 30 && low.q == 0.1)
        let fine = EQBand(frequency: 80, gain: -6, q: 5)
        #expect(fine.clamped() == fine)
    }
}

@Suite("EQ real-time filter")
struct EQFilterProcessingTests {
    /// Requirement: a sine at Fc through the actual RT filter code reaches
    /// the set gain in steady state (within 0.1 dB), per band and rate.
    @Test(arguments: testRates)
    func sineAtCentreReachesTheSetGain(sampleRate: Double) {
        for band in defaultBands {
            let design = EQDesign(bands: [band], sampleRate: sampleRate)
            var processor = DSPProcessor(sampleRate: sampleRate, maximumFrames: 512, sections: design.sections)
            let input = DSPTest.sine(frequency: band.frequency, sampleRate: sampleRate, count: Int(sampleRate * 2))
            let (left, right) = DSPTest.run(&processor, input)
            let tail = left.count - Int(sampleRate / 2)  // last 0.5 s: steady state
            let level = DSPTest.decibels(DSPTest.peak(left[tail...]) / 0.5)
            #expect(abs(level - band.gain) < 0.1, "\(band.frequency) Hz at \(sampleRate): \(level) dB")
            #expect(left == right)
        }
    }

    /// The same through the complete render kernel (preamp 0 dB, EQ on),
    /// with all four bands: the level at each Fc equals the combined curve.
    @Test func combinedBandsThroughTheFullKernel() {
        let rate = 48_000.0
        let design = EQDesign(bands: defaultBands, sampleRate: rate)
        for band in defaultBands {
            let handle = DSPTest.makeHandle(sampleRate: rate, filters: design.sections)
            let input = DSPTest.sine(frequency: band.frequency, sampleRate: rate, count: Int(rate * 2))
            let output = DSPTest.render(handle, input, block: 128)
            let level = DSPTest.decibels(DSPTest.peak(output[(output.count - 24_000)...]) / 0.5)
            let expected = EQCurve.responseDecibels(
                coefficients: design.coefficients, sampleRate: rate, frequencies: [band.frequency])[0]
            #expect(abs(level - expected) < 0.1, "\(band.frequency) Hz: \(level) vs \(expected) dB")
            #expect(handle.readMeters().clippedSamples == 0)
        }
    }

    /// Requirement: the impulse response decays (stable) for all default
    /// bands, including Q 14.3 at 192 kHz.
    @Test(arguments: testRates + [192_000])
    func impulseResponseDecays(sampleRate: Double) {
        for band in defaultBands {
            let design = EQDesign(bands: [band], sampleRate: sampleRate)
            var processor = DSPProcessor(sampleRate: sampleRate, maximumFrames: 1024, sections: design.sections)
            var impulse = [Float](repeating: 0, count: Int(sampleRate * 2))
            impulse[0] = 1
            let (response, _) = DSPTest.run(&processor, impulse, block: 1024)
            #expect(response.allSatisfy { $0.isFinite })
            // Remove the direct part (the impulse itself) and look at the ringing.
            var ringing = response.map(Double.init)
            ringing[0] -= 1
            let energy = ringing.reduce(0) { $0 + $1 * $1 }
            let lastTenth = ringing[(ringing.count * 9 / 10)...].reduce(0) { $0 + $1 * $1 }
            #expect(energy > 0)
            #expect(lastTenth < 1e-12 * max(energy, 1e-30), "\(band.frequency) Hz at \(sampleRate)")
            // Envelope decreases: the peak in each 100 ms window shrinks.
            let window = Int(sampleRate / 10)
            var previous = Double.infinity
            for start in stride(from: window, to: ringing.count - window, by: window) {
                let peak = ringing[start..<(start + window)].map(\.magnitude).max()!
                #expect(peak <= previous * 1.0001 || peak < 1e-15)
                previous = peak
            }
            #expect(processor.stateResets == 0)
        }
    }

    /// NaN/Inf input never poisons the filter state.
    @Test func nonFiniteInputDoesNotPoisonTheFilters() {
        let rate = 48_000.0
        let design = EQDesign(bands: defaultBands, sampleRate: rate)
        var processor = DSPProcessor(sampleRate: rate, maximumFrames: 256, sections: design.sections)
        var input = DSPTest.sine(frequency: 100, sampleRate: rate, count: 4800)
        input[1000] = .nan
        input[2000] = .infinity
        input[2001] = -.infinity
        let (left, right) = DSPTest.run(&processor, input)
        #expect(left.allSatisfy(\.isFinite) && right.allSatisfy(\.isFinite))
        #expect(processor.stateResets == 0)

        // Through the full kernel: the NaN on the dry side is silenced and counted.
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: design.sections)
        let output = DSPTest.render(handle, input)
        #expect(output.allSatisfy { $0.isFinite })
        // The dry signal enters the dry/wet mix, so the 3 bad samples (x L/R)
        // are silenced and counted; everything after them is normal.
        #expect(handle.readMeters().nonFiniteSamples == 6)
        #expect(output[2002...].allSatisfy { $0 != 0 })
        let bypassed = DSPTest.makeHandle(sampleRate: rate, filters: design.sections, bypass: true)
        let dry = DSPTest.render(bypassed, input)
        #expect(dry.allSatisfy { $0.isFinite })
        #expect(bypassed.readMeters().nonFiniteSamples == 6)  // 3 samples x L/R
    }

    @Test func noSectionsIsBitExactPassthrough() {
        var processor = DSPProcessor(sampleRate: 48_000, maximumFrames: 64)
        let input = DSPTest.sine(frequency: 1234, sampleRate: 48_000, count: 1000)
        let (left, _) = DSPTest.run(&processor, input, block: 100)  // also blocks > maximumFrames
        #expect(left == input)
    }
}
