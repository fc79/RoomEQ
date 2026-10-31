import Foundation
import Testing
@testable import RoomEQCore

// Measurement of EQ changes: parameter smoothing (the app's DSPProcessor)
// vs. the stage-3 A/B bank crossfade (LegacyABProcessor, test-only copy).
//
// Definitions (all levels relative to the input peak):
//   yOld / yNew  = the old / new filter set, LTI, run on the whole input
//                  (the ideal steady-state outputs before / after the change);
//   response R   = time from the change until the new parameters are fully
//                  in effect (smoothing: the ramp; A/B: warm-up + fade);
//   yRef         = crossfade reference (1 - w) yOld + w yNew, with w a
//                  smoothstep over the engine's own response window;
//   deviation    = max |y - yRef|: includes the filter's own physical
//                  settling (a Q 14 bass band has a 50-130 ms time
//                  constant, so ANY response much faster than that deviates
//                  from yRef by roughly the size of the change);
//   click        = max |HP(y - yRef)|, HP = 4th-order Butterworth high-pass
//                  well above every frequency involved: broadband energy
//                  that neither filter would produce (clicks, zipper);
//   settled      = time after the change until |y - yNew| stays below -40 dB;
//   overshoot    = peak |y| after the change vs. the larger of the peaks of
//                  yOld and yNew over the same time (> 0 dB = a "bong"
//                  louder than either setting);
//   zipper       = (smoothing only) max |y(16-sample updates) - y(per-sample
//                  updates, same ramp length)|: error of the update interval.
//
// The full table runs only with ROOMEQ_MEASURE=1 (it takes a while in
// debug builds); `smoothingMeetsTheCriteria` runs always on a subset.

struct MeasurementCase: Sendable, CustomStringConvertible {
    let name: String
    let old: [EQBand]
    let new: [EQBand]
    /// Sine frequency for the tone test.
    let tone: Double
    /// High-pass corner for the click metric.
    let clickHighPass: Double
    var description: String { name }

    static func all() -> [MeasurementCase] {
        let id = UUID()
        func band(_ f: Double, _ g: Double, _ q: Double) -> EQBand { EQBand(id: id, frequency: f, gain: g, q: q) }
        let defaults = EQBand.defaultBands()
        let replacement = [
            EQBand(frequency: 45, gain: -8, q: 8), EQBand(frequency: 90, gain: -6, q: 12),
            EQBand(frequency: 150, gain: -10, q: 5), EQBand(frequency: 300, gain: 4, q: 3),
        ]
        return [
            MeasurementCase(name: "58,8 Hz Q14 0→+10 dB", old: [band(58.8, 0, 14)], new: [band(58.8, 10, 14)],
                            tone: 58.8, clickHighPass: 2000),
            MeasurementCase(name: "58,8 Hz Q14 0→−10 dB", old: [band(58.8, 0, 14)], new: [band(58.8, -10, 14)],
                            tone: 58.8, clickHighPass: 2000),
            MeasurementCase(name: "58,8 Hz Q14 −10→+10 dB", old: [band(58.8, -10, 14)], new: [band(58.8, 10, 14)],
                            tone: 58.8, clickHighPass: 2000),
            MeasurementCase(name: "20 Hz Q10 0→−10 dB", old: [band(20, 0, 10)], new: [band(20, -10, 10)],
                            tone: 20, clickHighPass: 2000),
            MeasurementCase(name: "76,6 Hz Q14,3 −6,8 dB attivato", old: [], new: [defaults[1]],
                            tone: 76.6, clickHighPass: 2000),
            MeasurementCase(name: "60 Hz → 1 kHz (Q4, −10 dB)", old: [band(60, -10, 4)], new: [band(1000, -10, 4)],
                            tone: 1000, clickHighPass: 6000),
            MeasurementCase(name: "import: 4 filtri sostituiti", old: defaults, new: replacement,
                            tone: 76.6, clickHighPass: 2000),
        ]
    }
}

enum Engine: CustomStringConvertible {
    case smoothing(updateInterval: Int)
    case legacyAB
    var description: String {
        switch self {
        case .smoothing(let interval): "smoothing/\(interval)"
        case .legacyAB: "A/B"
        }
    }
}

struct Measurement {
    var responseMs: Double
    var deviationDecibels: Double
    var clickDecibels: Double
    var settledMs: Double
    var maxPoleRadius: Double
    var overshootDecibels: Double
    var output: [Float]
}

enum EQMeasure {
    static let rampSeconds = 0.030

    static func pinkNoise(count: Int, seed: UInt64 = 7) -> [Float] {
        var generator = SeededGenerator(state: seed)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let white = Double.random(in: -1...1, using: &generator)
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            result[index] = Float((b0 + b1 + b2 + white * 0.1848) * 0.08)
        }
        return result
    }

    /// 4th-order Butterworth high-pass (two RBJ HP biquads), in Double.
    static func highPass(_ signal: [Double], corner: Double, sampleRate: Double) -> [Double] {
        var data = signal
        for q in [0.541_196_1, 1.306_563] {
            let w0 = 2 * Double.pi * min(corner, 0.45 * sampleRate) / sampleRate
            let alpha = sin(w0) / (2 * q), cw = cos(w0), a0 = 1 + alpha
            let b0 = (1 + cw) / 2 / a0, b1 = -(1 + cw) / a0, b2 = b0, a1 = -2 * cw / a0, a2 = (1 - alpha) / a0
            var s1 = 0.0, s2 = 0.0
            for index in data.indices {
                let x = data[index]
                let y = b0 * x + s1
                s1 = b1 * x - a1 * y + s2
                s2 = b2 * x - a2 * y
                data[index] = y
            }
        }
        return data
    }

    static func lti(_ bands: [EQBand], _ input: [Float], sampleRate: Double) -> [Float] {
        var processor = DSPProcessor(
            sampleRate: sampleRate, maximumFrames: 1024, sections: EQDesign(bands: bands, sampleRate: sampleRate).sections)
        return DSPTest.run(&processor, input).0
    }

    static func run(
        _ engine: Engine, _ testCase: MeasurementCase, input: [Float], sampleRate: Double, switchAt: Int,
        block: Int = 256, rampSeconds: Double = EQMeasure.rampSeconds
    ) -> Measurement {
        let old = EQDesign(bands: testCase.old, sampleRate: sampleRate).sections
        let new = EQDesign(bands: testCase.new, sampleRate: sampleRate).sections
        var output: [Float] = []
        var responseFrames = 0
        var windowStart = 0
        var maxRadius = 0.0
        switch engine {
        case .smoothing(let interval):
            var processor = DSPProcessor(
                sampleRate: sampleRate, maximumFrames: 1024, rampSeconds: rampSeconds, updateInterval: interval,
                sections: old)
            output = DSPTest.run(&processor, Array(input[..<switchAt]), block: block).0
            processor.apply(new)
            responseFrames = processor.rampSteps * processor.updateInterval
            var start = switchAt
            while start < input.count {
                let end = min(input.count, start + block)
                output += DSPTest.run(&processor, Array(input[start..<end]), block: block).0
                for c in processor.currentCoefficients { maxRadius = max(maxRadius, c.poleRadius) }
                start = end
            }
        case .legacyAB:
            var processor = LegacyABProcessor(
                sampleRate: sampleRate, maximumFrames: 1024, crossfadeSeconds: 0.020,
                sections: LegacySection.make(old, sampleRate: sampleRate))
            var head = Array(input[..<switchAt])
            var outHead = head
            runLegacy(&processor, &head, &outHead, block: block)
            output = outHead
            processor.beginTransition(to: LegacySection.make(new, sampleRate: sampleRate))
            windowStart = processor.warmupRemaining
            responseFrames = processor.warmupRemaining + processor.crossfadeFrames
            var tail = Array(input[switchAt...])
            var outTail = tail
            runLegacy(&processor, &tail, &outTail, block: block)
            output += outTail
            for c in old + new { maxRadius = max(maxRadius, c.coefficients.poleRadius) }
        }
        var peakOut: Float = 0, peakOld: Float = 0, peakNew: Float = 0

        let yOld = lti(testCase.old, input, sampleRate: sampleRate)
        let yNew = lti(testCase.new, input, sampleRate: sampleRate)
        for index in switchAt..<input.count {
            peakOut = max(peakOut, abs(output[index]))
            peakOld = max(peakOld, abs(yOld[index]))
            peakNew = max(peakNew, abs(yNew[index]))
        }
        let peak = Double(input.map(\.magnitude).max() ?? 1)
        var difference = [Double](repeating: 0, count: input.count)
        var worst = 0.0
        var lastUnsettled = switchAt
        let fade = max(1, responseFrames - windowStart)
        for index in switchAt..<input.count {
            let position = index - switchAt - windowStart + 1
            var weight = 0.0
            if position >= fade { weight = 1 } else if position > 0 {
                let t = Double(position) / Double(fade)
                weight = t * t * (3 - 2 * t)
            }
            let reference = (1 - weight) * Double(yOld[index]) + weight * Double(yNew[index])
            difference[index] = Double(output[index]) - reference
            worst = max(worst, abs(difference[index]))
            if abs(Double(output[index]) - Double(yNew[index])) > 0.01 * peak { lastUnsettled = index }
        }
        let click = highPass(difference, corner: testCase.clickHighPass, sampleRate: sampleRate)[switchAt...]
            .map(\.magnitude).max() ?? 0
        func decibels(_ value: Double) -> Double { 20 * log10(max(value, 1e-12) / peak) }
        return Measurement(
            responseMs: Double(responseFrames) * 1000 / sampleRate, deviationDecibels: decibels(worst),
            clickDecibels: decibels(click), settledMs: Double(lastUnsettled - switchAt) * 1000 / sampleRate,
            maxPoleRadius: maxRadius,
            overshootDecibels: 20 * log10(Double(peakOut) / Double(max(peakOld, peakNew))), output: output)
    }

    static func runLegacy(_ processor: inout LegacyABProcessor, _ input: inout [Float], _ output: inout [Float], block: Int) {
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var done = 0
                while done < source.count {
                    let count = min(block, source.count - done)
                    processor.process(
                        inputLeft: source.baseAddress! + done, inputRight: source.baseAddress! + done,
                        outputLeft: destination.baseAddress! + done, outputRight: destination.baseAddress! + done,
                        frameCount: count)
                    done += count
                }
            }
        }
    }

    static func signals(sampleRate: Double, tone: Double, seconds: Double = 1.8) -> [(String, [Float])] {
        let count = Int(sampleRate * seconds)
        return [
            ("seno", DSPTest.sine(frequency: tone, sampleRate: sampleRate, count: count)),
            ("rumore rosa", pinkNoise(count: count)),
        ]
    }
}

@Suite("EQ smoothing measurements")
struct EQSmoothingMeasurementTests {
    /// The full comparison table (ROOMEQ_MEASURE=1 swift test --filter EQSmoothingMeasurementTests).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROOMEQ_MEASURE"] != nil))
    func comparisonTable() {
        print("caso | Fs | segnale | motore | risposta ms | deviazione dB | click dB | assestato ms | sovraelong. dB | zipper dB | r max")
        for testCase in MeasurementCase.all() {
            for rate in [44_100.0, 48_000, 96_000, 192_000] {
                for (signalName, input) in EQMeasure.signals(sampleRate: rate, tone: testCase.tone) {
                    let switchAt = Int(rate * 0.6)
                    // Same ramp length in samples as the 16-sample version.
                    let steps = max(1, Int((EQMeasure.rampSeconds * rate / 16).rounded()))
                    let fine = EQMeasure.run(
                        .smoothing(updateInterval: 1), testCase, input: input, sampleRate: rate, switchAt: switchAt,
                        rampSeconds: Double(steps * 16) / rate)
                    for engine in [Engine.smoothing(updateInterval: 16), .legacyAB] {
                        let m = EQMeasure.run(engine, testCase, input: input, sampleRate: rate, switchAt: switchAt)
                        var zipper = "—"
                        if case .smoothing = engine {
                            let error = zip(m.output, fine.output).map { Double(abs($0 - $1)) }.max() ?? 0
                            let peak = Double(input.map(\.magnitude).max()!)
                            zipper = String(format: "%.0f", 20 * log10(max(error, 1e-12) / peak))
                        }
                        print(String(
                            format: "%@ | %.1f | %@ | %@ | %.0f | %.1f | %.1f | %.0f | %+.2f | %@ | %.7f",
                            testCase.name, rate / 1000, signalName, engine.description, m.responseMs,
                            m.deviationDecibels, m.clickDecibels, m.settledMs, m.overshootDecibels, zipper,
                            m.maxPoleRadius))
                    }
                }
            }
        }
    }
}
