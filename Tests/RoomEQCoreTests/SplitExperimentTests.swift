import CoreAudio
import Testing
@testable import RoomEQCore

/// Synthetic trace: one callback every `period` frames at `rate` Hz, host
/// clock of 24 MHz, starting at `startHost`, sample times from `startSample`.
private func makeTrace(
    rate: Double, period: Int = 128, count: Int = 2000, startHost: UInt64 = 1_000_000, startSample: Double = 0,
    hostOffset: Double = 0
) -> CallbackTraceSnapshot {
    let ticks = 24_000_000.0
    var now: [UInt64] = [], samples: [Double] = [], hosts: [UInt64] = [], frames: [UInt32] = []
    for index in 0..<count {
        let sample = Double(index * period)
        let host = startHost + UInt64(((sample / rate) + hostOffset) * ticks)
        now.append(host)
        samples.append(startSample + sample)
        hosts.append(host)
        frames.append(UInt32(period))
    }
    return CallbackTraceSnapshot(nowHost: now, stampSample: samples, stampHost: hosts, frames: frames, callbacks: count)
}

@Suite("Split experiment analysis")
struct SplitAnalysisTests {
    let ticks = 24_000_000.0

    @Test func sameClockGivesZeroDrift() throws {
        let capture = try #require(SplitAnalysis.clock(makeTrace(rate: 44100), ticksPerSecond: ticks))
        let output = try #require(SplitAnalysis.clock(makeTrace(rate: 44100, startSample: 5000), ticksPerSecond: ticks))
        #expect(abs(capture.rate - 44100) < 0.01)
        #expect(abs(SplitAnalysis.driftPPM(capture: capture.rate, output: output.rate)) < 0.5)
    }

    @Test func detectsTenPPMDrift() throws {
        let capture = try #require(SplitAnalysis.clock(makeTrace(rate: 44100 * 1.00001), ticksPerSecond: ticks))
        let output = try #require(SplitAnalysis.clock(makeTrace(rate: 44100), ticksPerSecond: ticks))
        let drift = SplitAnalysis.driftPPM(capture: capture.rate, output: output.rate)
        #expect(abs(drift - 10) < 0.5)
        #expect(abs(capture.firstLastRate - capture.rate) < 0.05)
    }

    @Test func fitPredictsSampleTime() throws {
        let fit = try #require(SplitAnalysis.clock(makeTrace(rate: 48000, startSample: 1000), ticksPerSecond: ticks))
        // One second after the first callback.
        #expect(abs(fit.sampleTime(atHost: 1_000_000 + 24_000_000) - 49_000) < 0.5)
    }

    @Test func ringAddsHalfABufferWhenCaptureLeadsByHalf() throws {
        // Output callbacks half a period after the capture ones.
        let capture = makeTrace(rate: 44100)
        let output = makeTrace(rate: 44100, hostOffset: 64.0 / 44100)
        let ring = try #require(
            SplitAnalysis.ring(capture: capture, output: output, warmupTicks: 0, ticksPerSecond: ticks, sampleRate: 44100))
        // Each captured buffer is read half a period later.
        #expect(abs(ring.meanDelayFrames - 64) < 0.5)
        #expect(abs(ring.maxDelayFrames - 64) < 0.5)
    }

    @Test func ringAddsOneBufferWhenOutputRunsFirst() throws {
        // Simultaneous callbacks: ties count the output first -> one buffer of delay.
        let capture = makeTrace(rate: 44100)
        let output = makeTrace(rate: 44100)
        let ring = try #require(
            SplitAnalysis.ring(capture: capture, output: output, warmupTicks: 0, ticksPerSecond: ticks, sampleRate: 44100))
        #expect(ring.alignmentFrames == 128)
        #expect(abs(ring.meanDelayFrames - 128) < 0.5)
    }

    @Test func projectedLatency() {
        let ms = SplitAnalysis.projectedLatencyMilliseconds(
            sampleRate: 44100, tapStreamLatency: 0, captureSafetyOffset: 11, captureBuffer: 128, ringFrames: 0,
            outputBuffer: 128, outputSafetyOffset: 11, outputDeviceLatency: 32, outputStreamLatency: 0)
        #expect(abs(ms - 310.0 / 44.1) < 1e-9)
    }

    @Test func frameStats() throws {
        let stats = try #require(SplitAnalysis.frameStats(makeTrace(rate: 44100, count: 10)))
        #expect(stats.min == 128 && stats.max == 128 && stats.mean == 128)
    }
}

@Suite("Callback tracer")
struct CallbackTracerTests {
    @Test func recordsCaptureAndOutput() {
        let capture = CallbackTraceHandle(capacity: 4)
        let output = CallbackTraceHandle(capacity: 4)
        let input = TestBufferList(channelCounts: [2], frames: 16, fill: 0.25)
        input.set(buffer: 0, channel: 1, frame: 3, -0.75)
        let outputList = TestBufferList(channelCounts: [10], frames: 16, fill: 0.5)

        var now = AudioTimeStamp()
        now.mHostTime = 1000
        now.mFlags = [.sampleTimeValid, .hostTimeValid]
        var stamp = now
        stamp.mSampleTime = 512

        for _ in 0..<6 {  // more callbacks than capacity
            CallbackTracer.recordCapture(
                capture.pointer, now: &now, stamp: &stamp, input: UnsafePointer(input.pointer), output: nil)
            CallbackTracer.recordOutput(output.pointer, now: &now, stamp: &stamp, output: outputList.pointer)
        }
        let captureTrace = capture.snapshot()
        #expect(captureTrace.callbacks == 6)
        #expect(captureTrace.nowHost.count == 4)
        #expect(captureTrace.frames.allSatisfy { $0 == 16 })
        #expect(captureTrace.stampSample.first == 512)
        #expect(captureTrace.peak == 0.75)

        let outputTrace = output.snapshot()
        #expect(outputTrace.frames.first == 16)
        #expect(outputList.get(buffer: 0, channel: 5, frame: 7) == 0)  // silence written

        // Invalid timestamps are counted, not recorded.
        var invalid = AudioTimeStamp()
        capture.reset()
        CallbackTracer.recordCapture(capture.pointer, now: &now, stamp: &invalid, input: nil, output: nil)
        let afterReset = capture.snapshot()
        #expect(afterReset.callbacks == 1 && afterReset.invalidStamps == 1 && afterReset.missingBuffers == 1)
        #expect(afterReset.nowHost.isEmpty)
    }
}
