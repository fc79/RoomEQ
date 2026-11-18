import Foundation
import Testing
@testable import RoomEQCore

@Suite("Linear ramp")
struct LinearRampTests {
    @Test func reachesTargetExactlyAfterRampFrames() {
        var ramp = LinearRamp(value: 0, rampFrames: 3)
        ramp.setTarget(0.3)
        let values = (0..<5).map { _ in ramp.next() }
        #expect(abs(values[0] - 0.1) < 1e-6)
        #expect(abs(values[1] - 0.2) < 1e-6)
        #expect(values[2] == Float(0.3))
        #expect(values[3] == Float(0.3))
        #expect(!ramp.isRamping)
    }

    @Test func retargetDuringRampStartsFromCurrentValue() {
        var ramp = LinearRamp(value: 0, rampFrames: 4)
        ramp.setTarget(1)
        _ = ramp.next()  // 0.25
        _ = ramp.next()  // 0.5
        ramp.setTarget(0)  // new 4-sample ramp from 0.5 down to 0
        let first = ramp.next()
        #expect(abs(first - 0.375) < 1e-6)
        _ = ramp.next(); _ = ramp.next()
        let last = ramp.next()
        #expect(last == 0)
    }

    @Test func sameTargetDoesNotRestart() {
        var ramp = LinearRamp(value: 1, rampFrames: 10)
        ramp.setTarget(1)
        #expect(!ramp.isRamping)
        let value = ramp.next()
        #expect(value == 1)
    }

    @Test func framesFromTime() {
        #expect(LinearRamp.frames(seconds: 0.015, sampleRate: 44100) == 662)
        #expect(LinearRamp.frames(seconds: 0.010, sampleRate: 48000) == 480)
        #expect(LinearRamp.frames(seconds: 0, sampleRate: 48000) == 1)
    }
}

@Suite("Preamp gain ramp")
struct GainRampTests {
    private static func decibels(_ gain: Float) -> Double { 20 * log10(Double(gain)) }

    /// Between audible gains the ramp is linear in dB over `levelFrames`,
    /// like a band's gain: a band going from +10 to 0 dB and the preamp from
    /// −10 to 0 dB add up to 0 dB at every step (no overshoot).
    @Test func audibleChangesAreLinearInDecibels() {
        var ramp = GainRamp(value: Float(pow(10, -10.0 / 20)), fadeFrames: 15, levelFrames: 100)
        ramp.setTarget(1)
        for step in 1...100 {
            let preamp = Self.decibels(ramp.next())
            let band = 10 - 10 * Double(step) / 100
            #expect(abs(preamp + band) < 0.001)
        }
        #expect(ramp.value == 1)
        #expect(!ramp.isRamping)
    }

    /// The fade to silence at stop stays linear and as short as before
    /// (teardown waits 25 ms for a 15 ms fade).
    @Test func fadesToAndFromSilenceAreLinear() {
        var ramp = GainRamp(value: 1, fadeFrames: 4, levelFrames: 100)
        ramp.setTarget(0)
        #expect([ramp.next(), ramp.next(), ramp.next(), ramp.next()] == [0.75, 0.5, 0.25, 0])
        ramp.setTarget(0.5)
        #expect([ramp.next(), ramp.next(), ramp.next(), ramp.next()] == [0.125, 0.25, 0.375, 0.5])
    }

    /// A new target during a ramp continues from the current value.
    @Test func retargetingNeverJumps() {
        var ramp = GainRamp(value: 0.5, fadeFrames: 4, levelFrames: 10)
        ramp.setTarget(1)
        for _ in 0..<5 { _ = ramp.next() }
        let middle = ramp.value
        ramp.setTarget(0.25)
        let after = ramp.next()
        #expect(after < middle)
        #expect(abs(Self.decibels(after) - Self.decibels(middle)) < 1)
        for _ in 0..<9 { _ = ramp.next() }
        #expect(ramp.value == 0.25)
    }

    /// A fade to silence asked in the middle of a dB ramp (stop while a
    /// preset changes) is linear from where the gain is, and ends at 0
    /// within `fadeFrames`.
    @Test func silenceDuringALevelRampFadesLinearly() {
        var ramp = GainRamp(value: 0.25, fadeFrames: 4, levelFrames: 100)
        ramp.setTarget(1)
        for _ in 0..<50 { _ = ramp.next() }
        let from = ramp.value
        ramp.setTarget(0)
        let values = (0..<4).map { _ in ramp.next() }
        #expect(abs(values[0] - from * 0.75) < 1e-6)
        #expect(values[3] == 0)
    }

    /// Same target again: nothing restarts.
    @Test func sameTargetIsANoOp() {
        var ramp = GainRamp(value: 0.5, fadeFrames: 4, levelFrames: 10)
        ramp.setTarget(0.5)
        #expect(!ramp.isRamping)
        #expect(ramp.next() == 0.5)
    }
}
