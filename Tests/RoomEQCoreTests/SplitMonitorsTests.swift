import Testing
@testable import RoomEQCore

@Suite("Split health monitor")
struct SplitHealthMonitorTests {
    /// Feeds `polls` polls of 100 ms with the given per-poll increments.
    private func run(
        _ monitor: inout SplitHealthMonitor, polls: Int, capture: UInt64, output: UInt64, bad: UInt64 = 0,
        start: (UInt64, UInt64, UInt64) = (0, 0, 0)
    ) -> [SplitHealthMonitor.Problem?] {
        var (c, o, b) = start
        var results: [SplitHealthMonitor.Problem?] = []
        for _ in 0..<polls {
            c += capture; o += output; b += bad
            results.append(monitor.update(captureCycles: c, outputCycles: o, badOutputCycles: b, elapsed: 0.1))
        }
        return results
    }

    @Test func healthyRunNeverTrips() {
        var monitor = SplitHealthMonitor()
        #expect(run(&monitor, polls: 100, capture: 69, output: 69, bad: 1).allSatisfy { $0 == nil })
    }

    @Test func outputStalledWhileCaptureRuns() {
        var monitor = SplitHealthMonitor()
        _ = run(&monitor, polls: 3, capture: 69, output: 69)
        let results = run(&monitor, polls: 6, capture: 69, output: 0, start: (207, 207, 0))
        #expect(results.prefix(4).allSatisfy { $0 == nil })
        #expect(results.contains(.outputStalled))
    }

    @Test func captureStalledWhileOutputRuns() {
        var monitor = SplitHealthMonitor()
        let results = run(&monitor, polls: 7, capture: 0, output: 69)
        #expect(results.contains(.captureStalled))
    }

    @Test func bothStalledIsNotHidden() {
        var monitor = SplitHealthMonitor()
        let results = run(&monitor, polls: 12, capture: 0, output: 0)
        #expect(results.contains(.ioStalled))
    }

    @Test func persistentBadCyclesTrip() {
        var monitor = SplitHealthMonitor()
        let results = run(&monitor, polls: 7, capture: 69, output: 69, bad: 60)
        #expect(results.contains(.badCycles))
    }
}

@Suite("Drift monitor")
struct DriftMonitorTests {
    @Test func sameClockWithJitterDoesNotTrip() {
        var monitor = DriftMonitor(sampleRate: 44100, bufferFrames: 64)
        for second in 1...120 {
            let jitter = Double((second * 7) % 3) - 1  // -1, 0, +1 frames
            let tripped = monitor.add(meanNeed: 190 + jitter, at: Double(second))
            #expect(!tripped)
        }
        #expect(abs(monitor.trendPPM ?? 99) < 1)
    }

    @Test func tenPPMDriftTrips() {
        var monitor = DriftMonitor(sampleRate: 44100, bufferFrames: 64)
        var tripped: Int?
        for second in 1...120 where tripped == nil {
            // 10 ppm of 44100 Hz = 0.441 frames per second.
            if monitor.add(meanNeed: 190 + 0.441 * Double(second), at: Double(second)) { tripped = second }
        }
        #expect(tripped != nil && tripped! >= 30 && tripped! <= 31)
    }

    @Test func lagJumpLargerThanABufferTrips() {
        var monitor = DriftMonitor(sampleRate: 44100, bufferFrames: 64)
        for second in 1...5 { _ = monitor.add(meanNeed: 190, at: Double(second)) }
        let first = monitor.add(meanNeed: 250, at: 6)  // averaged with the previous second: +30
        let second = monitor.add(meanNeed: 270, at: 7)  // recent mean 260: +70 > 64
        #expect(!first)
        #expect(second)
    }
}

@Suite("Warm-up and delay adaptation")
struct WarmupAndAdaptationTests {
    @Test func statistics() throws {
        let stats = try #require(WarmupAnalysis.statistics([5, 1, 9, 3, 7]))
        #expect(stats.min == 1 && stats.median == 5 && stats.max == 9)
        #expect(WarmupAnalysis.statistics([]) == nil)
    }

    @Test func windowWithStallOrGlitchIsRejected() {
        var before = SplitLinkStatus()
        before.captureCycles = 100
        before.outputCycles = 100
        var clean = before
        clean.captureCycles = 434
        clean.outputCycles = 434
        #expect(WarmupAnalysis.windowIsClean(before: before, after: clean, expectedCycles: 344))

        var stalled = clean
        stalled.captureCycles = 150  // capture stalled during the window
        #expect(!WarmupAnalysis.windowIsClean(before: before, after: stalled, expectedCycles: 344))

        var glitch = clean
        glitch.discontinuities = 1
        #expect(!WarmupAnalysis.windowIsClean(before: before, after: glitch, expectedCycles: 344))

        var overload = clean
        overload.captureOverloads = 1
        #expect(!WarmupAnalysis.windowIsClean(before: before, after: overload, expectedCycles: 344))
    }

    @Test func adaptationGrowsByOneBlockThenFails() {
        var adaptation = DelayAdaptation(maximumIncreases: 2)
        let actions = [
            adaptation.evaluate(newUnderruns: 0, currentDelay: 220, block: 64, maximum: 1000),
            adaptation.evaluate(newUnderruns: 3, currentDelay: 220, block: 64, maximum: 1000),
            adaptation.evaluate(newUnderruns: 1, currentDelay: 284, block: 64, maximum: 1000),
            adaptation.evaluate(newUnderruns: 1, currentDelay: 348, block: 64, maximum: 1000),
        ]
        #expect(actions == [.none, .increase(to: 284), .increase(to: 348), .fail])
    }

    @Test func adaptationFailsWhenNoRoomIsLeft() {
        var adaptation = DelayAdaptation(maximumIncreases: 4)
        let action = adaptation.evaluate(newUnderruns: 1, currentDelay: 990, block: 64, maximum: 1000)
        #expect(action == .fail)
    }
}
