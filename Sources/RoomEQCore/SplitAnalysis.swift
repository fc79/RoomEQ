// Offline analysis of the split experiment's callback traces.
//
// Questions answered:
//  1. Do the capture side (tap aggregate) and the output side (physical
//     device) run on the same clock? -> effective rates and drift in ppm.
//  2. How much ring-buffer delay is needed so the output never reads audio
//     that hasn't been captured yet? -> event simulation on host times.
//  3. What end-to-end latency would that give? -> sum of the parts.

/// Linear fit sampleTime = intercept + rate * seconds(host - host0).
public struct ClockEstimate: Sendable, Equatable {
    /// Least-squares frames per second.
    public let rate: Double
    /// (last - first) / duration, for comparison.
    public let firstLastRate: Double
    public let durationSeconds: Double
    public let points: Int
    let host0: UInt64
    let intercept: Double
    let ticksPerSecond: Double

    /// Sample time this side reports at host time `host` (from the fit).
    public func sampleTime(atHost host: UInt64) -> Double {
        intercept + rate * Double(Int64(bitPattern: host &- host0)) / ticksPerSecond
    }
}

/// What a ring buffer between capture and output would add.
public struct RingEstimate: Sendable, Equatable {
    /// Read-pointer alignment (frames behind the capture's cumulative count)
    /// needed so the output never reads ahead, for this window.
    public let alignmentFrames: Int
    /// Time between a sample becoming available (capture callback) and the
    /// output reading it, with that alignment: mean and worst, in frames at
    /// `sampleRate` (this is the latency the ring adds).
    public let meanDelayFrames: Double
    public let maxDelayFrames: Double
    /// Output callbacks evaluated (after warm-up).
    public let outputEvents: Int
}

public enum SplitAnalysis {
    /// Least-squares fit of the traced timestamps (sample time vs host time).
    /// `skip` leading entries are ignored (start-up). Nil if < 2 points.
    public static func clock(_ trace: CallbackTraceSnapshot, ticksPerSecond: Double, skip: Int = 0) -> ClockEstimate? {
        let count = min(trace.stampSample.count, trace.stampHost.count)
        guard count - skip >= 2, ticksPerSecond > 0 else { return nil }
        let host0 = trace.stampHost[skip]
        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
        let sample0 = trace.stampSample[skip]
        for index in skip..<count {
            let x = Double(Int64(bitPattern: trace.stampHost[index] &- host0)) / ticksPerSecond
            let y = trace.stampSample[index] - sample0  // centred for precision
            sumX += x; sumY += y; sumXX += x * x; sumXY += x * y
        }
        let n = Double(count - skip)
        let denominator = n * sumXX - sumX * sumX
        guard denominator > 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n + sample0
        let duration = Double(Int64(bitPattern: trace.stampHost[count - 1] &- host0)) / ticksPerSecond
        let firstLast = duration > 0 ? (trace.stampSample[count - 1] - sample0) / duration : 0
        return ClockEstimate(
            rate: slope, firstLastRate: firstLast, durationSeconds: duration, points: count - skip,
            host0: host0, intercept: intercept, ticksPerSecond: ticksPerSecond)
    }

    /// Relative drift of the capture clock against the output clock, in ppm.
    public static func driftPPM(capture: Double, output: Double) -> Double {
        output > 0 ? (capture / output - 1) * 1_000_000 : .nan
    }

    /// Simulates a FIFO between the two callbacks using their inNow host
    /// times (the moment data is available / needed). Only callbacks after
    /// `max(first capture, first output) + warmupTicks` count. Ties count
    /// the output first (conservative).
    ///
    /// The read position is aligned as early as possible without ever
    /// reading uncaptured frames (alignment = max over output callbacks of
    /// consumed - captured). For each output callback, the last frame it
    /// reads was captured by some capture callback; the host-time gap
    /// between the two is the delay the ring adds. With drift the delay
    /// changes over the run, so the worst case is reported too.
    public static func ring(
        capture: CallbackTraceSnapshot, output: CallbackTraceSnapshot, warmupTicks: UInt64,
        ticksPerSecond: Double, sampleRate: Double
    ) -> RingEstimate? {
        guard let firstCapture = capture.nowHost.first, let firstOutput = output.nowHost.first,
            ticksPerSecond > 0
        else { return nil }
        let start = max(firstCapture, firstOutput) &+ warmupTicks

        // Capture: cumulative frames after each callback in the window.
        var captureTimes: [UInt64] = [], captureTotals: [Int] = []
        var total = 0
        for (index, time) in capture.nowHost.enumerated() where time >= start {
            total += Int(capture.frames[index])
            captureTimes.append(time)
            captureTotals.append(total)
        }
        // Output: cumulative frames consumed and captured-so-far at each callback.
        var outputTimes: [UInt64] = [], consumedTotals: [Int] = [], capturedAt: [Int] = []
        var consumed = 0, captureIndex = 0
        for (index, time) in output.nowHost.enumerated() where time >= start {
            while captureIndex < captureTimes.count && captureTimes[captureIndex] < time { captureIndex += 1 }
            consumed += Int(output.frames[index])
            outputTimes.append(time)
            consumedTotals.append(consumed)
            capturedAt.append(captureIndex == 0 ? 0 : captureTotals[captureIndex - 1])
        }
        guard !outputTimes.isEmpty, !captureTimes.isEmpty else { return nil }
        let alignment = zip(consumedTotals, capturedAt).map { $0 - $1 }.max() ?? 0

        var delays: [Double] = []
        for (index, time) in outputTimes.enumerated() {
            let lastRead = consumedTotals[index] - alignment  // in capture frame count
            guard lastRead > 0 else { continue }
            // First capture callback whose cumulative total reaches lastRead.
            var low = 0, high = captureTotals.count - 1
            while low < high {
                let middle = (low + high) / 2
                if captureTotals[middle] >= lastRead { high = middle } else { low = middle + 1 }
            }
            let gap = Double(Int64(bitPattern: time &- captureTimes[low])) / ticksPerSecond
            delays.append(gap * sampleRate)
        }
        guard !delays.isEmpty else { return nil }
        return RingEstimate(
            alignmentFrames: alignment,
            meanDelayFrames: delays.reduce(0, +) / Double(delays.count),
            maxDelayFrames: delays.max() ?? 0,
            outputEvents: delays.count)
    }

    /// Smallest / largest / mean frames per callback.
    public static func frameStats(_ trace: CallbackTraceSnapshot) -> (min: Int, max: Int, mean: Double)? {
        guard let low = trace.frames.min(), let high = trace.frames.max() else { return nil }
        let mean = Double(trace.frames.reduce(0) { $0 + Int($1) }) / Double(trace.frames.count)
        return (Int(low), Int(high), mean)
    }

    /// Projected end-to-end latency (ms) of a split design:
    /// capture side (tap stream latency + capture safety offset) + capture
    /// buffer + ring delay + output buffer + output safety offset + output
    /// device latency + output stream latency.
    public static func projectedLatencyMilliseconds(
        sampleRate: Double, tapStreamLatency: Int, captureSafetyOffset: Int, captureBuffer: Int, ringFrames: Int,
        outputBuffer: Int, outputSafetyOffset: Int, outputDeviceLatency: Int, outputStreamLatency: Int
    ) -> Double {
        guard sampleRate > 0 else { return 0 }
        let frames =
            tapStreamLatency + captureSafetyOffset + captureBuffer + ringFrames + outputBuffer + outputSafetyOffset
            + outputDeviceLatency + outputStreamLatency
        return Double(frames) * 1000 / sampleRate
    }
}
