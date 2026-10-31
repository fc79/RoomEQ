import Foundation
import Testing
@testable import RoomEQCore

/// Click-free changes of the filter set (two banks, warm-up + crossfade),
/// the lock-free mailbox and the bypass with warm filters.
@Suite("EQ bank switching")
struct EQTransitionTests {
    let rate = 48_000.0

    /// Runs `input`, switching from `old` to `new` at `switchAt` (directly on
    /// the processor). Returns the output, the warm-up length and the
    /// largest deviation from the ideal crossfade between the two filters
    /// (each run on the whole signal), relative to the input peak, in dB.
    func switchRun(old: [FilterSection], new: [FilterSection], input: [Float], switchAt: Int)
        -> (output: [Float], warmup: Int, artifactDecibels: Double)
    {
        var reference = DSPProcessor(sampleRate: rate, maximumFrames: 1024, sections: old)
        let oldOutput = DSPTest.run(&reference, input).0
        var target = DSPProcessor(sampleRate: rate, maximumFrames: 1024, sections: new)
        let newOutput = DSPTest.run(&target, input).0

        var processor = DSPProcessor(sampleRate: rate, maximumFrames: 1024, sections: old)
        var output = DSPTest.run(&processor, Array(input[..<switchAt])).0
        processor.beginTransition(to: new)
        let warmup = processor.warmupRemaining
        let fade = processor.crossfadeFrames
        output += DSPTest.run(&processor, Array(input[switchAt...])).0
        let finished = !processor.isTransitioning, switches = processor.completedTransitions
        #expect(finished)
        #expect(switches == 1)

        var worst: Float = 0
        for index in switchAt..<input.count {
            let position = index - switchAt - warmup + 1
            var weight = 0.0
            if position >= fade { weight = 1 } else if position > 0 {
                let t = Double(position) / Double(fade)
                weight = t * t * (3 - 2 * t)
            }
            let ideal = Float((1 - weight) * Double(oldOutput[index]) + weight * Double(newOutput[index]))
            worst = max(worst, abs(output[index] - ideal))
        }
        let peak = input.map(\.magnitude).max() ?? 1
        return (output, warmup, DSPTest.decibels(Double(max(worst, 1e-12) / peak)))
    }

    func sections(_ bands: [EQBand]) -> [FilterSection] { EQDesign(bands: bands, sampleRate: rate).sections }

    /// Largest |y[n] - y[n-1]|.
    func largestJump(_ samples: [Float], from start: Int = 1) -> Float {
        var jump: Float = 0
        for index in max(1, start)..<samples.count { jump = max(jump, abs(samples[index] - samples[index - 1])) }
        return jump
    }

    /// Requirement: switching bank on a sine produces no sample-to-sample
    /// jump above what the sine itself has (high-Q band changed at its Fc).
    @Test func bankSwitchOnASineHasNoJump() {
        let bands = EQBand.defaultBands()
        var edited = bands
        edited[1].gain = 0  // F2 (76.6 Hz, Q 14.3): -6.8 dB -> 0 dB
        let input = DSPTest.sine(frequency: 76.6, sampleRate: rate, count: Int(rate * 1.5))
        let result = switchRun(old: sections(bands), new: sections(edited), input: input, switchAt: 24_000)
        // A sine of amplitude a moves at most 2 a sin(pi f / Fs) per sample;
        // the output amplitude never exceeds the input's (all cuts here).
        let sineStep = Float(2 * 0.5 * sin(Double.pi * 76.6 / rate))
        #expect(largestJump(result.output, from: 24_000) <= sineStep * 1.05)
        #expect(result.artifactDecibels < -40)
        // The new setting is really applied: back to (almost) full level.
        let level = DSPTest.decibels(DSPTest.peak(result.output[(result.output.count - 4800)...]) / 0.5)
        let expected = EQCurve.responseDecibels(
            coefficients: sections(edited).map(\.coefficients), sampleRate: rate, frequencies: [76.6])[0]
        #expect(abs(level - expected) < 0.1)
    }

    /// Why the silent warm-up exists: a high-Q band whose state does not
    /// match (new IDs = zero state, or changed coefficients) rings for tens
    /// of ms. With the warm-up the residue is >40 dB below the signal;
    /// crossfading immediately (no warm-up) leaves an audible one.
    @Test func warmupRemovesTheRingingOfHighQChanges() {
        let bands = EQBand.defaultBands()
        var gainStep = bands
        gainStep[1].gain = -3
        let freshIDs = bands.map { EQBand(frequency: $0.frequency, gain: $0.gain, q: $0.q) }
        var removedFirst = bands
        removedFirst[0].isEnabled = false
        let input = DSPTest.sine(frequency: 76.6, sampleRate: rate, count: Int(rate * 1.5))

        for new in [gainStep, freshIDs, removedFirst] {
            let warm = switchRun(old: sections(bands), new: sections(new), input: input, switchAt: 24_000)
            #expect(warm.warmup > 0 && warm.warmup <= Int(EQDesign.maximumWarmupSeconds * rate))
            #expect(warm.artifactDecibels < -45, "with warm-up: \(warm.artifactDecibels) dB")

            var noWarmup = sections(new)
            for index in noWarmup.indices { noWarmup[index].settleFrames = 0 }
            let immediate = switchRun(old: sections(bands), new: noWarmup, input: input, switchAt: 24_000)
            #expect(immediate.warmup == 0)
            #expect(immediate.artifactDecibels > -40, "without warm-up: \(immediate.artifactDecibels) dB")
        }
    }

    /// Unchanged bands keep their exact state: an identical set (or one
    /// that only drops the LAST band) needs no warm-up and is seamless.
    @Test func unchangedLeadingBandsNeedNoWarmup() {
        let bands = EQBand.defaultBands()
        let input = DSPTest.sine(frequency: 140, sampleRate: rate, count: 24_000)
        let same = switchRun(old: sections(bands), new: sections(bands), input: input, switchAt: 12_000)
        #expect(same.warmup == 0)
        #expect(same.artifactDecibels < -120)  // bit-identical outputs

        var lastOff = bands
        lastOff[3].isEnabled = false
        let dropLast = switchRun(old: sections(bands), new: sections(lastOff), input: input, switchAt: 12_000)
        #expect(dropLast.warmup == 0)
        #expect(dropLast.artifactDecibels < -100)
    }

    /// Through the kernel: rapid successive publications (a slider drag)
    /// are coalesced and the LAST one is always the one finally active.
    @Test func rapidChangesAreCoalescedAndTheFinalValueIsApplied() {
        var bands = EQBand.defaultBands()
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: sections(bands))
        let input = DSPTest.sine(frequency: 76.6, sampleRate: rate, count: Int(rate * 3))
        var lastPublished: [FilterSection] = []
        let output = DSPTest.render(handle, input, block: 128) { cycle, _ in
            // 60 changes, one every ~8 ms (every 3rd cycle of 128 frames).
            guard cycle % 3 == 0, cycle / 3 < 60 else { return }
            bands[1].gain = -6.8 + Double(cycle / 3 + 1) * 0.1
            lastPublished = sections(bands)
            #expect(handle.publishFilters(lastPublished))
        }
        #expect(!handle.eqIsTransitioning)
        #expect(handle.eqActiveSections == lastPublished)
        // Fewer switches than publications (coalesced), but at least one.
        let switches = handle.eqCompletedTransitions
        #expect(switches >= 2 && switches < 60)
        // No clicks along the way.
        let sineStep = Float(2 * 0.5 * sin(Double.pi * 76.6 / rate))
        #expect(largestJump(output) <= sineStep * 1.05)
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
        #expect(handle.eqIsTransitioning)
    }

    /// A set published while a switch is running waits in the mailbox and
    /// is applied right after (never dropped).
    @Test func setPublishedDuringASwitchIsAppliedAfterIt() {
        let first = sections(EQBand.defaultBands())
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: first)
        let silence = [Float](repeating: 0, count: 256)
        let second = sections([EQBand(frequency: 500, gain: -4, q: 2)])
        let third = sections([EQBand(frequency: 800, gain: -2, q: 1)])
        handle.publishFilters(second)
        _ = DSPTest.renderCycle(handle, left: silence, right: silence)
        #expect(handle.eqIsTransitioning)
        handle.publishFilters(third)
        for _ in 0..<200 { _ = DSPTest.renderCycle(handle, left: silence, right: silence) }  // ~1 s
        #expect(!handle.eqIsTransitioning)
        #expect(handle.eqCompletedTransitions == 2)
        #expect(handle.eqActiveSections == third)
    }

    /// Requirement: the filters keep running while the EQ is off, so turning
    /// it back on is click-free and lands exactly on the warm EQ output.
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
        // After the 10 ms crossfade back, identical to the never-bypassed EQ.
        let settled = 48_128 + 480
        var difference: Float = 0
        for index in settled..<input.count { difference = max(difference, abs(output[index] - expected[index])) }
        #expect(difference < 1e-6)
        // And no jumps on the way (input amplitude 0.5 is the largest level).
        let sineStep = Float(2 * 0.5 * sin(Double.pi * 58.8 / rate))
        #expect(largestJump(output) <= sineStep * 1.05)
    }

    /// A new session starts with its set active at once, no crossfade.
    @Test func initialSetIsActiveImmediately() {
        let filters = sections(EQBand.defaultBands())
        let handle = DSPTest.makeHandle(sampleRate: rate, filters: filters)
        #expect(!handle.eqIsTransitioning)
        #expect(handle.eqActiveSections == filters)
    }
}

@Suite("Preamp")
struct PreampTests {
    @Test func clampedToMinus24To0() {
        #expect(Preamp.clamp(6) == 0)
        #expect(Preamp.clamp(0.0001) == 0)
        #expect(Preamp.clamp(-3.5) == -3.5)
        #expect(Preamp.clamp(-40) == -24)
        #expect(Preamp.clamp(.nan) == 0)
        #expect(Preamp.clamp(-0.0).sign == .plus)
        #expect(Preamp.linearGain(decibels: 12) == 1)
        #expect(abs(Preamp.linearGain(decibels: -6.0206) - 0.5) < 1e-4)
    }

    @Test func renderGainNeverBoosts() {
        let handle = DSPTest.makeHandle(sampleRate: 48_000, filters: [], gain: 4)
        #expect(handle.targetGain == 1)
        handle.setGain(linear: 2)
        #expect(handle.targetGain == 1)
        handle.setGain(linear: .nan)
        #expect(handle.targetGain == 0)
        handle.setPreamp(decibels: 12)
        #expect(handle.targetGain == 1)
        let input = [Float](repeating: 0.5, count: 2048)
        let output = DSPTest.render(handle, input)
        #expect(output.last == 0.5)
        handle.setPreamp(decibels: -60)  // limited to -24 dB
        let quieter = DSPTest.render(handle, input)
        #expect(abs(Double(quieter.last!) - 0.5 * pow(10, -24.0 / 20)) < 1e-6)
    }
}
