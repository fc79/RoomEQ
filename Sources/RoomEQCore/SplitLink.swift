// The link between the capture side and the output side of the split
// engine: a lock-free single-producer / single-consumer ring buffer indexed
// by SAMPLE TIME, plus the timing data needed to read it at a fixed delay.
//
//   capture IOProc (tap-only aggregate)        output IOProc (physical device)
//   ---------------------------------          -------------------------------
//   frames for sample times [s, s+n)    --->    reads [outS + offset - delay, +n)
//   written into slot (t mod capacity)          runs the render chain, writes pair
//   publishes "written up to s+n"               (silence + fade where data missing)
//
// Measured (split experiment): both IOProcs run on the same device clock and
// report the SAME sample timeline (offset 0, drift ~0 ppm). The engine still
// measures the offset at start from the first timestamps.
//
// Delay: during a warm-up phase (delay = 0) the output IOProc outputs
// silence and records, for every cycle, how far ahead of the captured data
// it would need to read: need = (outS + n) - writtenUpTo. The engine then
// fixes delay = max(need) + offset + margin for the whole session (and only
// increases it, with a fade, if underruns happen).
//
// REAL-TIME RULES apply to `CaptureKernel` and `SplitOutputKernel`: no
// allocation, locks, logging, ARC.

import CoreAudio
import Darwin
import Synchronization

/// Built on a normal thread.
public struct SplitLinkConfiguration: Sendable {
    /// Layout of the capture aggregate's INPUT buffer list (the tap stream).
    public var captureLayout: BufferListLayout
    /// Tap channels used as left/right source.
    public var captureLeft: ChannelLocation
    public var captureRight: ChannelLocation
    /// Frames per channel kept in the ring (rounded up to a power of two).
    public var ringCapacity: Int
    /// Largest output buffer handled per cycle (device maximum is 4096).
    public var maxOutputFrames: Int
    /// Fade lengths around missing data and delay changes.
    public var fadeInFrames: Int
    public var fadeOutFrames: Int

    public init(
        captureLayout: BufferListLayout, captureLeft: ChannelLocation, captureRight: ChannelLocation,
        ringCapacity: Int = 8192, maxOutputFrames: Int = 4096, fadeInFrames: Int = 64, fadeOutFrames: Int = 32
    ) {
        self.captureLayout = captureLayout
        self.captureLeft = captureLeft
        self.captureRight = captureRight
        self.ringCapacity = ringCapacity
        self.maxOutputFrames = maxOutputFrames
        self.fadeInFrames = fadeInFrames
        self.fadeOutFrames = fadeOutFrames
    }
}

/// Shared state. Non-copyable, at a fixed address (see `SplitLinkHandle`).
public struct SplitLink: ~Copyable {
    // MARK: Ring (written by capture, read by output)
    public let capacity: Int
    let mask: Int64
    let ringLeft: UnsafeMutablePointer<Float>
    let ringRight: UnsafeMutablePointer<Float>
    /// End (exclusive) of the frames written so far, in capture sample time;
    /// `Int64.min` until the first write. Stored with release semantics.
    public let writtenUpTo: Atomic<Int64>
    /// Capture-private: where the next block is expected to start.
    var nextExpected: Int64 = .min

    // MARK: Capture layout (read-only)
    let buffersOffset: Int
    let captureBufferCount: Int
    let captureLeft: ChannelLocation
    let captureRight: ChannelLocation

    // MARK: First timestamps (each written once by its IOProc)
    public let captureFirstSample: Atomic<Int64>
    public let captureFirstHost: Atomic<UInt64>
    public let captureFirstReady: Atomic<Bool>
    public let outputFirstSample: Atomic<Int64>
    public let outputFirstHost: Atomic<UInt64>
    public let outputFirstReady: Atomic<Bool>

    // MARK: Control (engine -> output IOProc)
    /// capture sample time = output sample time + offset (same instant).
    public let timelineOffset: Atomic<Int64>
    /// Read delay in frames; 0 = warm-up (silence + measurement).
    public let delayFrames: Atomic<Int64>

    // MARK: Warm-up measurement (output IOProc -> engine)
    public let warmupMaxNeed: Atomic<Int64>
    public let warmupSamples: Atomic<Int>

    // MARK: Counters
    public let captureCycles: Atomic<UInt64>
    public let captureInvalidCycles: Atomic<UInt64>
    public let discontinuities: Atomic<UInt64>
    public let captureOverloads: Atomic<UInt64>
    public let outputCycles: Atomic<UInt64>
    public let outputInvalidStamps: Atomic<UInt64>
    public let underrunCycles: Atomic<UInt64>
    public let missingFrames: Atomic<UInt64>
    public let overwrittenFrames: Atomic<UInt64>

    // MARK: Output-private
    var activeDelay: Int64 = 0
    var fadeInPending = true
    let sourceLeft: UnsafeMutablePointer<Float>
    let sourceRight: UnsafeMutablePointer<Float>
    let sourceCapacity: Int
    let fadeInFrames: Int
    let fadeOutFrames: Int

    public init(configuration: SplitLinkConfiguration) {
        var size = 1
        while size < max(16, configuration.ringCapacity) { size <<= 1 }
        capacity = size
        mask = Int64(size - 1)
        ringLeft = .allocate(capacity: size)
        ringLeft.initialize(repeating: 0, count: size)
        ringRight = .allocate(capacity: size)
        ringRight.initialize(repeating: 0, count: size)
        writtenUpTo = Atomic(.min)

        buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8
        captureBufferCount = configuration.captureLayout.bufferChannelCounts.count
        captureLeft = configuration.captureLeft
        captureRight = configuration.captureRight

        captureFirstSample = Atomic(0)
        captureFirstHost = Atomic(0)
        captureFirstReady = Atomic(false)
        outputFirstSample = Atomic(0)
        outputFirstHost = Atomic(0)
        outputFirstReady = Atomic(false)
        timelineOffset = Atomic(0)
        delayFrames = Atomic(0)
        warmupMaxNeed = Atomic(.min)
        warmupSamples = Atomic(0)

        captureCycles = Atomic(0)
        captureInvalidCycles = Atomic(0)
        discontinuities = Atomic(0)
        captureOverloads = Atomic(0)
        outputCycles = Atomic(0)
        outputInvalidStamps = Atomic(0)
        underrunCycles = Atomic(0)
        missingFrames = Atomic(0)
        overwrittenFrames = Atomic(0)

        sourceCapacity = max(16, configuration.maxOutputFrames)
        sourceLeft = .allocate(capacity: sourceCapacity)
        sourceLeft.initialize(repeating: 0, count: sourceCapacity)
        sourceRight = .allocate(capacity: sourceCapacity)
        sourceRight.initialize(repeating: 0, count: sourceCapacity)
        fadeInFrames = max(1, configuration.fadeInFrames)
        fadeOutFrames = max(1, configuration.fadeOutFrames)
    }

    deinit {
        ringLeft.deallocate()
        ringRight.deallocate()
        sourceLeft.deallocate()
        sourceRight.deallocate()
    }
}

// MARK: - Ring operations (real-time safe)

/// Result of a ring read: frames [first, end) of the block are valid; the
/// rest was zeroed (before `first`: overwritten; from `end`: not yet written).
public struct RingReadResult: Equatable, Sendable {
    public let first: Int
    public let end: Int
    public var validFrames: Int { max(0, end - first) }
}

public enum SampleRing {
    /// Writes `frames` frames for sample times [start, start + frames).
    /// A jump in sample time zeroes the skipped region (or the whole ring),
    /// so stale audio from a previous lap can never be played.
    @inline(__always)
    public static func write(
        _ link: UnsafeMutablePointer<SplitLink>, start: Int64, frames: Int,
        left: UnsafePointer<Float>, leftStride: Int, right: UnsafePointer<Float>, rightStride: Int
    ) {
        guard frames > 0 else { return }
        let capacity = link.pointee.capacity
        var start = start, frames = frames, sourceOffset = 0
        if frames > capacity {  // keep only the most recent `capacity` frames
            sourceOffset = frames - capacity
            start += Int64(sourceOffset)
            frames = capacity
        }
        let expected = link.pointee.nextExpected
        if expected != .min && start != expected {
            link.pointee.discontinuities.wrappingAdd(1, ordering: .relaxed)
            let gap = start - expected
            if gap > 0 && gap < Int64(capacity) {
                zero(link, from: expected, count: Int(gap))
            } else {
                zero(link, from: 0, count: capacity)
            }
        }
        let mask = link.pointee.mask
        let ringL = link.pointee.ringLeft, ringR = link.pointee.ringRight
        for frame in 0..<frames {
            let slot = Int((start + Int64(frame)) & mask)
            ringL[slot] = left[(sourceOffset + frame) * leftStride]
            ringR[slot] = right[(sourceOffset + frame) * rightStride]
        }
        let end = start + Int64(frames)
        link.pointee.nextExpected = end
        link.pointee.writtenUpTo.store(end, ordering: .releasing)
    }

    /// Reads [start, start + frames) into `left` / `right`; anything not
    /// available (not yet written, or already overwritten — including
    /// during the copy) is zeroed.
    @inline(__always)
    public static func read(
        _ link: UnsafeMutablePointer<SplitLink>, start: Int64, frames: Int,
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    ) -> RingReadResult {
        let capacity = Int64(link.pointee.capacity)
        let written = link.pointee.writtenUpTo.load(ordering: .acquiring)
        guard written != .min else {  // nothing captured yet: all missing (underrun)
            for index in 0..<frames { left[index] = 0; right[index] = 0 }
            return RingReadResult(first: 0, end: 0)
        }
        let blockEnd = start + Int64(frames)
        var validStart = max(start, written - capacity)
        let validEnd = min(blockEnd, written)
        if validEnd > validStart {
            let mask = link.pointee.mask
            let ringL = link.pointee.ringLeft, ringR = link.pointee.ringRight
            for time in validStart..<validEnd {
                let slot = Int(time & mask)
                let index = Int(time - start)
                left[index] = ringL[slot]
                right[index] = ringR[slot]
            }
            // Did the writer lap us during the copy?
            let after = link.pointee.writtenUpTo.load(ordering: .acquiring)
            if after - capacity > validStart { validStart = min(after - capacity, validEnd) }
        } else {
            validStart = validEnd
        }
        let first = max(0, Int(validStart - start))
        let end = max(first, Int(validEnd - start))
        for index in 0..<first { left[index] = 0; right[index] = 0 }
        if end < frames { for index in end..<frames { left[index] = 0; right[index] = 0 } }
        return RingReadResult(first: first, end: end)
    }

    @inline(__always)
    static func zero(_ link: UnsafeMutablePointer<SplitLink>, from start: Int64, count: Int) {
        let mask = link.pointee.mask
        for offset in 0..<min(count, link.pointee.capacity) {
            let slot = Int((start + Int64(offset)) & mask)
            link.pointee.ringLeft[slot] = 0
            link.pointee.ringRight[slot] = 0
        }
    }
}

// MARK: - Capture IOProc kernel

public enum CaptureKernel {
    /// Writes the tap's source channels into the ring at their sample time.
    public static func capture(
        _ link: UnsafeMutablePointer<SplitLink>,
        now: UnsafePointer<AudioTimeStamp>?,
        input: UnsafePointer<AudioBufferList>?,
        inputTime: UnsafePointer<AudioTimeStamp>?
    ) {
        link.pointee.captureCycles.wrappingAdd(1, ordering: .relaxed)
        let offset = link.pointee.buffersOffset
        guard let inputTime, inputTime.pointee.mFlags.contains(.sampleTimeValid), let input,
            let left = RenderKernel.sourceSamples(
                UnsafeRawPointer(input), offset, link.pointee.captureLeft,
                expectedBuffers: link.pointee.captureBufferCount),
            let right = RenderKernel.sourceSamples(
                UnsafeRawPointer(input), offset, link.pointee.captureRight,
                expectedBuffers: link.pointee.captureBufferCount)
        else {
            link.pointee.captureInvalidCycles.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let start = Int64(inputTime.pointee.mSampleTime.rounded())
        if !link.pointee.captureFirstReady.load(ordering: .relaxed) {
            link.pointee.captureFirstSample.store(start, ordering: .relaxed)
            link.pointee.captureFirstHost.store(inputTime.pointee.mHostTime, ordering: .relaxed)
            link.pointee.captureFirstReady.store(true, ordering: .releasing)
        }
        SampleRing.write(
            link, start: start, frames: min(left.frames, right.frames),
            left: UnsafePointer(left.samples), leftStride: left.stride,
            right: UnsafePointer(right.samples), rightStride: right.stride)
    }

    /// Counts a capture-device overload (C listener, IO thread).
    @inline(__always)
    public static func recordOverload(_ link: UnsafeMutablePointer<SplitLink>) {
        link.pointee.captureOverloads.wrappingAdd(1, ordering: .relaxed)
    }
}

// MARK: - Output IOProc kernel

public enum SplitOutputKernel {
    /// One output cycle: read the ring at the fixed delay and render.
    public static func render(
        state: UnsafeMutablePointer<RenderState>,
        link: UnsafeMutablePointer<SplitLink>,
        outputTime: UnsafePointer<AudioTimeStamp>?,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) {
        link.pointee.outputCycles.wrappingAdd(1, ordering: .relaxed)
        let buffersOffset = link.pointee.buffersOffset
        let requested = RenderKernel.outputFrameCount(output, buffersOffset: buffersOffset)
        guard requested > 0, let outputTime, outputTime.pointee.mFlags.contains(.sampleTimeValid) else {
            link.pointee.outputInvalidStamps.wrappingAdd(1, ordering: .relaxed)
            RenderKernel.silence(output, buffersOffset: buffersOffset)
            return
        }
        let outputStart = Int64(outputTime.pointee.mSampleTime.rounded())
        if !link.pointee.outputFirstReady.load(ordering: .relaxed) {
            link.pointee.outputFirstSample.store(outputStart, ordering: .relaxed)
            link.pointee.outputFirstHost.store(outputTime.pointee.mHostTime, ordering: .relaxed)
            link.pointee.outputFirstReady.store(true, ordering: .releasing)
        }

        let delay = link.pointee.delayFrames.load(ordering: .acquiring)
        guard delay > 0 else {
            // Warm-up: silence, and measure how far ahead we would read.
            RenderKernel.silence(output, buffersOffset: buffersOffset)
            let written = link.pointee.writtenUpTo.load(ordering: .acquiring)
            if written != .min {
                link.pointee.warmupMaxNeed.max(outputStart + Int64(requested) - written, ordering: .relaxed)
                link.pointee.warmupSamples.wrappingAdd(1, ordering: .relaxed)
            }
            return
        }

        // A delay change is applied across two cycles: this block is read at
        // the old delay and faded out, the next one fades in at the new delay.
        var readDelay = delay
        var fadeOutBlock = false
        if link.pointee.activeDelay == 0 {
            link.pointee.activeDelay = delay
            link.pointee.fadeInPending = true
        } else if link.pointee.activeDelay != delay {
            readDelay = link.pointee.activeDelay
            fadeOutBlock = true
        }

        let frames = min(requested, link.pointee.sourceCapacity)
        let left = link.pointee.sourceLeft, right = link.pointee.sourceRight
        let offset = link.pointee.timelineOffset.load(ordering: .relaxed)
        let result = SampleRing.read(
            link, start: outputStart + offset - readDelay, frames: frames, left: left, right: right)

        if result.validFrames > 0 && link.pointee.fadeInPending {
            fade(left, right, from: result.first, count: min(link.pointee.fadeInFrames, result.validFrames), rising: true)
            link.pointee.fadeInPending = false
        }
        if result.first > 0 {  // overwritten (reader fell behind by a full ring)
            link.pointee.overwrittenFrames.wrappingAdd(UInt64(result.first), ordering: .relaxed)
        }
        if result.end < frames {  // underrun: data not captured yet
            link.pointee.underrunCycles.wrappingAdd(1, ordering: .relaxed)
            link.pointee.missingFrames.wrappingAdd(UInt64(frames - result.end), ordering: .relaxed)
            let count = min(link.pointee.fadeOutFrames, result.validFrames)
            fade(left, right, from: result.end - count, count: count, rising: false)
            link.pointee.fadeInPending = true
        }
        if result.validFrames == 0 { link.pointee.fadeInPending = true }
        if fadeOutBlock {
            fade(left, right, from: result.first, count: result.validFrames, rising: false)
            link.pointee.activeDelay = delay
            link.pointee.fadeInPending = true
        }

        RenderKernel.renderFromSource(
            state: state, sourceLeft: UnsafePointer(left), sourceRight: UnsafePointer(right), frames: frames,
            output: output)
    }

    /// Linear fade over [from, from + count): rising 0 -> 1 or falling 1 -> 0.
    @inline(__always)
    static func fade(
        _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, from: Int, count: Int, rising: Bool
    ) {
        guard count > 0, from >= 0 else { return }
        let step = 1 / Float(count)
        for index in 0..<count {
            let gain = rising ? Float(index) * step : Float(count - 1 - index) * step
            left[from + index] *= gain
            right[from + index] *= gain
        }
    }
}

// MARK: - Engine-side handle and pure timeline math

/// Counters and timing for the UI / logs.
public struct SplitLinkStatus: Sendable, Equatable {
    public var delayFrames: Int64
    public var timelineOffset: Int64
    public var captureCycles: UInt64
    public var captureInvalidCycles: UInt64
    public var discontinuities: UInt64
    public var captureOverloads: UInt64
    public var outputCycles: UInt64
    public var outputInvalidStamps: UInt64
    public var underrunCycles: UInt64
    public var missingFrames: UInt64
    public var overwrittenFrames: UInt64

    public static let empty = SplitLinkStatus(
        delayFrames: 0, timelineOffset: 0, captureCycles: 0, captureInvalidCycles: 0, discontinuities: 0,
        captureOverloads: 0, outputCycles: 0, outputInvalidStamps: 0, underrunCycles: 0, missingFrames: 0,
        overwrittenFrames: 0)
}

/// Client data of the output IOProc: it needs both the render state and the
/// link, but Core Audio passes a single pointer.
public struct SplitOutputContext {
    public let state: UnsafeMutablePointer<RenderState>
    public let link: UnsafeMutablePointer<SplitLink>

    public init(state: UnsafeMutablePointer<RenderState>, link: UnsafeMutablePointer<SplitLink>) {
        self.state = state
        self.link = link
    }
}

/// Owns one `SplitLink`. `rawPointer` is the capture IOProc's client data;
/// the output IOProc gets a `SplitOutputContext`.
public final class SplitLinkHandle: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<SplitLink>

    public init(configuration: SplitLinkConfiguration) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: SplitLink(configuration: configuration))
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    public var rawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(pointer) }

    /// Largest usable delay: the ring must still hold a whole output block
    /// behind the read position (capacity - largest block - 64 frames).
    public var maximumDelay: Int64 {
        Int64(pointer.pointee.capacity - pointer.pointee.sourceCapacity - 64)
    }

    /// Restarts the warm-up measurement window.
    public func resetWarmupMeasurement() {
        pointer.pointee.warmupMaxNeed.store(.min, ordering: .relaxed)
        pointer.pointee.warmupSamples.store(0, ordering: .relaxed)
    }

    /// Largest read-ahead need seen in the window and how many cycles measured it.
    public func warmupMeasurement() -> (maxNeed: Int64?, samples: Int) {
        let samples = pointer.pointee.warmupSamples.load(ordering: .relaxed)
        let need = pointer.pointee.warmupMaxNeed.load(ordering: .relaxed)
        return (need == .min ? nil : need, samples)
    }

    /// First (sample time, host time) of each side, once both have run.
    public func firstTimestamps() -> (capture: (Int64, UInt64), output: (Int64, UInt64))? {
        guard pointer.pointee.captureFirstReady.load(ordering: .acquiring),
            pointer.pointee.outputFirstReady.load(ordering: .acquiring)
        else { return nil }
        return (
            (pointer.pointee.captureFirstSample.load(ordering: .relaxed),
             pointer.pointee.captureFirstHost.load(ordering: .relaxed)),
            (pointer.pointee.outputFirstSample.load(ordering: .relaxed),
             pointer.pointee.outputFirstHost.load(ordering: .relaxed))
        )
    }

    /// Ends the warm-up: the offset is published first, then the delay
    /// (release), so the output IOProc sees both together.
    public func start(offset: Int64, delay: Int64) {
        pointer.pointee.timelineOffset.store(offset, ordering: .relaxed)
        pointer.pointee.delayFrames.store(max(1, delay), ordering: .releasing)
    }

    /// Changes the delay while playing (the output IOProc fades across it).
    public func setDelay(_ delay: Int64) {
        pointer.pointee.delayFrames.store(max(1, delay), ordering: .releasing)
    }

    public func status() -> SplitLinkStatus {
        let link = pointer
        return SplitLinkStatus(
            delayFrames: link.pointee.delayFrames.load(ordering: .relaxed),
            timelineOffset: link.pointee.timelineOffset.load(ordering: .relaxed),
            captureCycles: link.pointee.captureCycles.load(ordering: .relaxed),
            captureInvalidCycles: link.pointee.captureInvalidCycles.load(ordering: .relaxed),
            discontinuities: link.pointee.discontinuities.load(ordering: .relaxed),
            captureOverloads: link.pointee.captureOverloads.load(ordering: .relaxed),
            outputCycles: link.pointee.outputCycles.load(ordering: .relaxed),
            outputInvalidStamps: link.pointee.outputInvalidStamps.load(ordering: .relaxed),
            underrunCycles: link.pointee.underrunCycles.load(ordering: .relaxed),
            missingFrames: link.pointee.missingFrames.load(ordering: .relaxed),
            overwrittenFrames: link.pointee.overwrittenFrames.load(ordering: .relaxed))
    }
}

public enum SplitTimeline {
    /// Offset such that capture sample time = output sample time + offset at
    /// the same instant, from one timestamp of each side. The host-time gap
    /// between the two stamps is bridged at `sampleRate` (small gap, so the
    /// nominal rate is accurate enough).
    public static func offset(
        capture: (sample: Int64, host: UInt64), output: (sample: Int64, host: UInt64),
        sampleRate: Double, ticksPerSecond: Double
    ) -> Int64 {
        let gapSeconds = Double(Int64(bitPattern: output.host &- capture.host)) / ticksPerSecond
        let captureAtOutputHost = Double(capture.sample) + gapSeconds * sampleRate
        return Int64((captureAtOutputHost - Double(output.sample)).rounded())
    }

    /// Delay so that the output never reads ahead of the capture:
    /// measured need (output timeline) + offset + margin, clamped.
    public static func delay(maxNeed: Int64, offset: Int64, margin: Int64, minimum: Int64, maximum: Int64) -> Int64 {
        min(max(maxNeed + offset + margin, minimum), maximum)
    }
}
