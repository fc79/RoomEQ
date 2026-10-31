import Foundation
import Testing
@testable import RoomEQCore

/// Click-free EQ changes by parameter smoothing: criteria on the measured
/// cases, coalescing, band add/remove, slot handling, stability, denormals,
/// bypass with warm filters.
@Suite("EQ parameter smoothing")
struct EQSmoothingTests {
    let rate = 48_000.0

    func sections(_ bands: [EQBand], rate: Double = 48_000) -> [FilterSection] {
        EQDesign(bands: bands, sampleRate: rate).sections
    }

    /// The measured cases (see EQSmoothingMeasurementTests for the
    /// definitions): response <= 50 ms, no broadband click above -40 dB, no
    /// overshoot above either setting, stable all along, and the new
    /// setting reached (output = new filter's steady state, -40 dB).
    @Test(arguments: MeasurementCase.all())
    func smoothingMeetsTheCriteria(testCase: MeasurementCase) {
        for (rate, signals) in [(44_100.0, ["seno", "rumore rosa"]), (192_000.0, ["seno"])] {
            for (name, input) in EQMeasure.signals(sampleRate: rate, tone: testCase.tone) where signals.contains(name) {
                let switchAt = Int(rate * 0.6)
                let m = EQMeasure.run(.smoothing(updateInterval: 16), testCase, input: input, sampleRate: rate, switchAt: switchAt)
                let label = "\(testCase.name) \(rate) \(name)"
                #expect(m.responseMs <= 50, "\(label): \(m.responseMs) ms")
                #expect(m.clickDecibels < -40, "\(label): click \(m.clickDecibels) dB")
                #expect(m.overshootDecibels < 0.1, "\(label): overshoot \(m.overshootDecibels) dB")
                #expect(m.maxPoleRadius < 1, "\(label)")
                #expect(m.output.allSatisfy { $0.isFinite })
                let yNew = EQMeasure.lti(testCase.new, input, sampleRate: rate)
                let tail = input.count - Int(rate * 0.2)
                let peak = Double(input.map(\.magnitude).max()!)
                let residual = (tail..<input.count).map { Double(abs(m.output[$0] - yNew[$0])) }.max()!
                #expect(DSPTest.decibels(residual / peak) < -40, "\(label): not settled")
            }
        }
    }

    /// Largest |y[n] - y[n-1]|.
    func largestJump(_ samples: [Float], from start: Int = 1) -> Float {
        var jump: Float = 0
        for index in max(1, start)..<samples.count { jump = max(jump, abs(samples[index] - samples[index - 1])) }
        return jump
    }

    /// No sample-to-sample jump beyond what a sine of the larger of the two
    /// steady-state levels has (1 % margin), for a high-Q change at its Fc.
    @Test func changeOnASineHasNoJump() {
        let bands = EQBand.defaultBands()
        var edited = bands
        edited[1].gain = 0  // F2 (76.6 Hz, Q 14.3): -6.8 dB -> 0 dB
        let input = DSPTest.sine(frequency: 76.6, sampleRate: rate, count: Int(rate * 1.5))
        var processor = DSPProcessor(sampleRate: rate, maximumFrames: 1024, sections: sections(bands))
        var output = DSPTest.run(&processor, Array(input[..<24_000])).0
        processor.apply(sections(edited))
        output += DSPTest.run(&processor, Array(input[24_000...])).0
        let levels = [bands, edited].map {
            EQCurve.responseDecibels(coefficients: sections($0).map(\.coefficients), sampleRate: rate, frequencies: [76.6])[0]
        }
        let largestAmplitude = 0.5 * pow(10, levels.max()! / 20)
        let sineStep = Float(2 * largestAmplitude * sin(Double.pi * 76.6 / rate))
        #expect(largestJump(output, from: 24_000) <= sineStep * 1.01)
        let finished = !processor.isRamping
        #expect(finished)
    }

    /// Rapid successive publications (slider drag) through the kernel: the
    /// band follows, and the LAST value is the one finally reached.
    @Test func rapidChangesEndOnTheLastValue() {
        var bands = EQBand.defaultBands()
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: sections(bands))
        let input = DSPTest.sine(frequency: 76.6, sampleRate: rate, count: Int(rate * 2))
        var lastPublished: [FilterSection] = []
        let output = DSPTest.render(handle, input, block: 128) { cycle, _ in
            // 60 changes, one every 8 ms (every 3rd cycle of 128 frames).
            guard cycle % 3 == 0, cycle / 3 < 60 else { return }
            bands[1].gain = -6.8 + Double(cycle / 3 + 1) * 0.1
            lastPublished = sections(bands)
            #expect(handle.publishFilters(lastPublished))
        }
        #expect(!handle.eqIsRamping)
        #expect(handle.eqActiveTargets == lastPublished)
        #expect(handle.eqAppliedSets == 60)
        #expect(handle.eqActiveSlotCount == 4)
        // Ends exactly on the last setting's steady state.
        let expected = EQMeasure.lti(bands, input, sampleRate: rate)
        let difference = (input.count - 4800..<input.count).map { abs(output[$0] - expected[$0]) }.max()!
        #expect(difference < 1e-4)
        #expect(handle.readMeters().clippedSamples == 0)
    }

    @Test func publishingTheSameSetTwiceIsIgnored() {
        let initial = sections(EQBand.defaultBands())
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: initial)
        #expect(!handle.publishFilters(initial))
        let other = sections([EQBand(frequency: 1000, gain: -3, q: 1)])
        #expect(handle.publishFilters(other))
        #expect(!handle.publishFilters(other))
        _ = DSPTest.renderCycle(handle, left: [Float](repeating: 0, count: 64), right: [Float](repeating: 0, count: 64))
        #expect(handle.eqAppliedSets == 1)
        #expect(handle.eqIsRamping)
    }

    /// A set published while bands are still ramping is taken at once and
    /// the bands turn towards it from where they are.
    @Test func setPublishedDuringARampIsReached() {
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: sections(EQBand.defaultBands()))
        let silence = [Float](repeating: 0, count: 256)
        let second = sections([EQBand(frequency: 500, gain: -4, q: 2)])
        let third = sections([EQBand(frequency: 800, gain: -2, q: 1)])
        handle.publishFilters(second)
        _ = DSPTest.renderCycle(handle, left: silence, right: silence)
        #expect(handle.eqIsRamping)
        handle.publishFilters(third)
        _ = DSPTest.renderCycle(handle, left: silence, right: silence)
        #expect(handle.eqAppliedSets == 2)
        for _ in 0..<40 { _ = DSPTest.renderCycle(handle, left: silence, right: silence) }  // ~0.2 s
        #expect(!handle.eqIsRamping)
        #expect(handle.eqActiveTargets == third)
        #expect(handle.eqActiveSlotCount == 1)  // the others drained and were freed
    }

    /// A removed band ramps out, drains and frees its slot; re-adding it
    /// while it is still ramping out continues from where it is (no jump).
    @Test func bandsRampOutAndBackIn() {
        let bands = EQBand.defaultBands()
        var processor = DSPProcessor(sampleRate: rate, maximumFrames: 1024, sections: sections(bands))
        let input = DSPTest.sine(frequency: 58.8, sampleRate: rate, count: Int(rate))
        var output = DSPTest.run(&processor, Array(input[..<24_000])).0
        processor.apply(sections(Array(bands.dropFirst())))  // F1 removed
        output += DSPTest.run(&processor, Array(input[24_000..<24_480])).0  // 10 ms: still ramping out
        let ramping = processor.activeSlotCount
        #expect(ramping == 4)
        processor.apply(sections(bands))  // F1 back (same ID)
        output += DSPTest.run(&processor, Array(input[24_480...])).0
        let slots = processor.activeSlotCount, targets = processor.activeTargets
        #expect(slots == 4)  // same slot reused, nothing new
        #expect(targets == sections(bands))
        #expect(largestJump(output, from: 24_000) <= Float(2 * 0.5 * sin(Double.pi * 58.8 / rate)) * 1.01)

        processor.apply(sections(Array(bands.dropFirst())))
        _ = DSPTest.run(&processor, [Float](repeating: 0, count: Int(rate * 2)))  // drain in silence
        let left = processor.activeSlotCount
        #expect(left == 3)
    }

    /// Imports in quick succession: old sets ramp out while new ones ramp in;
    /// up to three full sets fit without cutting a band short.
    @Test func quickSuccessiveImports() {
        func fullSet(_ base: Double) -> [EQBand] {
            (0..<16).map { EQBand(frequency: base * pow(1.25, Double($0)), gain: -4, q: 6) }
        }
        var processor = DSPProcessor(sampleRate: rate, maximumFrames: 512, sections: sections(fullSet(40)))
        let noise = EQMeasure.pinkNoise(count: 4800)
        _ = DSPTest.run(&processor, noise)
        processor.apply(sections(fullSet(45)))
        _ = DSPTest.run(&processor, noise)
        processor.apply(sections(fullSet(50)))
        let output = DSPTest.run(&processor, noise).0
        let reuses = processor.forcedSlotReuses, slots = processor.activeSlotCount
        #expect(reuses == 0)
        #expect(slots <= 48)
        #expect(output.allSatisfy { $0.isFinite })
        // A fourth full set right away has to take draining slots: still safe.
        processor.apply(sections(fullSet(55)))
        let more = DSPTest.run(&processor, noise).0
        #expect(more.allSatisfy { $0.isFinite })
        let resets = processor.stateResets
        #expect(resets == 0)
    }

    /// Every RBJ peaking filter with Q > 0, 0 < w0 < pi is stable, and so is
    /// every linear interpolation between two of them (convex region).
    @Test func everyPointOfARampIsStable() {
        var generator = SeededGenerator(state: 3)
        for _ in 0..<2000 {
            func random() -> BiquadCoefficients {
                let rate = [44_100.0, 48_000, 96_000, 192_000].randomElement(using: &generator)!
                return BiquadCoefficients.peakingRT(
                    logFrequency: log(Double.random(in: 10...min(20_000, 0.45 * rate), using: &generator)),
                    gainDecibels: Double.random(in: -30...30, using: &generator),
                    logQ: log(Double.random(in: 0.1...100, using: &generator)), radiansPerHertz: 2 * .pi / rate)
            }
            let a = random(), b = random()
            #expect(a.isStable && b.isStable)
            for t in stride(from: 0.0, through: 1.0, by: 0.125) {
                let c = BiquadCoefficients(
                    b0: a.b0 + t * (b.b0 - a.b0), b1: a.b1 + t * (b.b1 - a.b1), b2: a.b2 + t * (b.b2 - a.b2),
                    a1: a.a1 + t * (b.a1 - a.a1), a2: a.a2 + t * (b.a2 - a.a2))
                #expect(c.isStable)
            }
        }
    }

    /// The RT coefficient function matches the validated one.
    @Test func realTimeCoefficientsMatchTheDesign() throws {
        let exact = try #require(BiquadCoefficients.peaking(frequency: 58.8, gainDecibels: -9.9, q: 10.664, sampleRate: rate))
        let rt = BiquadCoefficients.peakingRT(
            logFrequency: log(58.8), gainDecibels: -9.9, logQ: log(10.664), radiansPerHertz: 2 * .pi / rate)
        for (x, y) in [(exact.b0, rt.b0), (exact.b1, rt.b1), (exact.b2, rt.b2), (exact.a1, rt.a1), (exact.a2, rt.a2)] {
            #expect(abs(x - y) < 1e-13)
        }
    }

    /// After a long silence no filter state is subnormal (anti-denormal offset
    /// for normal bands, identity bands skipped once drained).
    @Test func noDenormalsAfterLongSilence() {
        let bands = EQBand.defaultBands() + [
            EQBand(frequency: 15_000, gain: -12, q: 0.1),  // fast-decaying low-Q band
            EQBand(frequency: 1000, gain: 0, q: 1),  // identity band
            EQBand(frequency: 300, gain: 0.01, q: 2),  // almost identity
        ]
        var processor = DSPProcessor(sampleRate: rate, maximumFrames: 1024, sections: sections(bands))
        _ = DSPTest.run(&processor, EQMeasure.pinkNoise(count: 24_000))
        _ = DSPTest.run(&processor, [Float](repeating: 0, count: Int(rate * 4)))
        let values = processor.stateValues
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0 == 0 || $0.magnitude >= Double.leastNormalMagnitude })
        // Silence in -> silence out (the offset is removed exactly).
        let out = DSPTest.run(&processor, [Float](repeating: 0, count: 1024)).0
        #expect(out.allSatisfy { $0.magnitude < 1e-30 })
    }

    @Test func zeroDecibelBandIsBitExactPassthrough() {
        var processor = DSPProcessor(
            sampleRate: rate, maximumFrames: 256, sections: sections([EQBand(frequency: 1000, gain: 0, q: 1)]))
        let input = DSPTest.sine(frequency: 1234, sampleRate: rate, count: 4000)
        let (left, _) = DSPTest.run(&processor, input)
        #expect(left == input)
    }

    /// The filters keep running while the EQ is off, so turning it back on
    /// lands exactly on the warm EQ output.
    @Test func bypassKeepsTheFiltersWarm() {
        let filters = sections(EQBand.defaultBands())
        let reference = DSPTest.makeHandle(sampleRate: rate, filters: filters)  // EQ always on
        let toggled = DSPTest.makeHandle(sampleRate: rate, filters: filters)
        let input = DSPTest.sine(frequency: 58.8, sampleRate: rate, count: Int(rate * 2))
        let expected = DSPTest.render(reference, input, block: 256)
        let output = DSPTest.render(toggled, input, block: 256) { _, start in
            if start == 24_064 { toggled.setBypass(true) }  // EQ off at 0.5 s
            if start == 48_128 { toggled.setBypass(false) }  // back on at 1 s
        }
        let settled = 48_128 + 480  // after the 10 ms crossfade
        let difference = (settled..<input.count).map { abs(output[$0] - expected[$0]) }.max()!
        #expect(difference < 1e-6)
        // Bound: the sine's own step plus the crossfade's slope term,
        // |dry - wet| / 480 per sample (at Fc the phase is 0, so
        // |dry - wet| <= 0.5 (1 - g) with g the EQ gain at 58.8 Hz).
        let g = pow(10, EQCurve.responseDecibels(
            coefficients: filters.map(\.coefficients), sampleRate: rate, frequencies: [58.8])[0] / 20)
        let bound = 2 * 0.5 * sin(Double.pi * 58.8 / rate) + 0.5 * (1 - g) / 480
        #expect(Double(largestJump(output)) <= bound * 1.01)
    }

    @Test func initialSetIsActiveImmediately() {
        let filters = sections(EQBand.defaultBands())
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: filters)
        #expect(!handle.eqIsRamping)
        #expect(handle.eqActiveTargets == filters)
    }
}

@Suite("Preamp")
struct PreampTests {
    @Test func clampedToMinus24To0() {
        #expect(Preamp.clamp(6) == 0)
        #expect(Preamp.clamp(0.0001) == 0)
        #expect(Preamp.clamp(-3.5) == -3.5)
        #expect(Preamp.clamp(-40) == -24)
        #expect(Preamp.clamp(-.infinity) == -24)
        #expect(Preamp.clamp(.infinity) == 0)
        #expect(Preamp.clamp(.nan) == nil)  // rejected: callers keep the previous value
        #expect(Preamp.clamp(-0.0)!.sign == .plus)
        #expect(Preamp.linearGain(decibels: 12) == 1)
        #expect(Preamp.linearGain(decibels: .nan) == nil)
        #expect(abs(Preamp.linearGain(decibels: -6.0206)! - 0.5) < 1e-4)
    }

    @Test func renderGainNeverBoostsAndIgnoresNaN() {
        let handle = DSPTest.makeHandle(sampleRate: 48_000, filters: [], gain: 4)
        #expect(handle.targetGain == 1)
        handle.setGain(linear: 2)
        #expect(handle.targetGain == 1)
        handle.setGain(linear: 0.5)
        handle.setGain(linear: .nan)
        #expect(handle.targetGain == 0.5)  // NaN ignored
        handle.setPreamp(decibels: .nan)
        #expect(handle.targetGain == 0.5)
        handle.setGain(linear: -.infinity)
        #expect(handle.targetGain == 0)
        handle.setPreamp(decibels: 12)
        #expect(handle.targetGain == 1)
        let input = [Float](repeating: 0.5, count: 2048)
        let output = DSPTest.render(handle, input)
        #expect(output.last == 0.5)
        handle.setPreamp(decibels: -60)  // limited to -24 dB
        let quieter = DSPTest.render(handle, input)
        #expect(abs(Double(quieter.last!) - 0.5 * pow(10, -24.0 / 20)) < 1e-6)
        #expect(DSPTest.makeHandle(sampleRate: 48_000, filters: [], gain: .nan).targetGain == 1)
    }
}
