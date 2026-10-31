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
