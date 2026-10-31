// The link between the capture side and the output side of the split
// engine: a lock-free single-producer / single-consumer ring buffer indexed
// by SAMPLE TIME, plus the measurements needed to read it at a fixed delay.
//
//   capture IOProc (tap-only aggregate)        output IOProc (physical device)
//   ---------------------------------          -------------------------------
//   frames for sample times [s, s+n)    --->    reads [outS - delay, outS - delay + n)
//   written into slot (t mod capacity)          runs the render chain, writes pair
//   publishes "written up to s+n"               (silence + fades where data is missing)
//
// Timelines: the experiment showed both IOProcs report the SAME sample
// timeline (offset 0, drift ~0 ppm). We do not rely on host times to
// relate them: the output IOProc measures directly, every cycle,
//     need = (outS + n) - writtenUpTo
// i.e. how far ahead of the captured data it would read with delay 0. Any
// constant offset between the timelines is part of `need`. The engine fixes
// delay = max(need during warm-up) + margin, and watches `need` over time to
// detect clock drift (which RoomEQ does not compensate: no resampling).
//
// Ring protocol (formal data race on samples, made safe by validation):
//   writer: writeBegin = end (relaxed); release fence; write samples;
//           writtenUpTo = end (release)
//   reader: w = writtenUpTo (acquire); copy samples; acquire fence;
//           b = writeBegin (relaxed); frames older than b - capacity may
//           have been overwritten during the copy -> treated as missing.
// Samples are plain aligned 32-bit floats: on arm64 and x86-64 such loads
// and stores are single-copy atomic (never torn), and any frame that might
// have been rewritten while we copied it is discarded, so the race is benign.
//
// REAL-TIME RULES apply to `SampleRing`, `CaptureKernel`, `SplitOutputKernel`:
// no allocation, locks, logging, ARC.

import CoreAudio
import Darwin
import Synchronization

// MARK: - Sizing

/// Ring and delay limits derived from the configured buffer sizes.
public struct SplitLinkSizing: Sendable, Equatable {
    /// Ring frames per channel (power of two).
    public let ringCapacity: Int
    /// Largest block one output callback may request.
    public let sourceCapacity: Int
    /// Largest read delay allowed (frames).
    public let maximumDelay: Int

    /// - Parameters:
    ///   - maxCallbackFrames: largest block either IOProc can get (buffer
    ///     size, or kAudioDevicePropertyUsesVariableBufferFrameSizes if larger).
    ///   - safetyOffsets: capture input + output safety offsets.
    ///   - delayIncreases: how many one-block increases the engine may make.
    public static func make(maxCallbackFrames: Int, safetyOffsets: Int, delayIncreases: Int) -> SplitLinkSizing {
        let block = max(16, maxCallbackFrames)
        // Expected need ~ safeties + 2 blocks (+1 if callbacks run in the
        // other order) + 1 block margin + the allowed increases + headroom.
        let maximumDelay = max(0, safetyOffsets) + (4 + max(0, delayIncreases)) * block + 512
        var capacity = 1024
        while capacity < 4 * (maximumDelay + block) { capacity <<= 1 }
        return SplitLinkSizing(ringCapacity: capacity, sourceCapacity: block, maximumDelay: maximumDelay)
    }
}

/// Built on a normal thread.
public struct SplitLinkConfiguration: Sendable {
    /// Layout of the capture aggregate's INPUT buffer list (the tap stream).
    public var captureLayout: BufferListLayout
    /// Tap channels used as left/right source.
    public var captureLeft: ChannelLocation
    public var captureRight: ChannelLocation
    public var sizing: SplitLinkSizing
    /// Fade lengths around missing data and delay changes.
    public var fadeInFrames: Int
    public var fadeOutFrames: Int
    /// Per-cycle `need` values kept for the warm-up statistics.
    public var needHistoryCapacity: Int

    public init(
        captureLayout: BufferListLayout, captureLeft: ChannelLocation, captureRight: ChannelLocation,
        sizing: SplitLinkSizing, fadeInFrames: Int = 64, fadeOutFrames: Int = 32, needHistoryCapacity: Int = 2048
    ) {
        self.captureLayout = captureLayout
        self.captureLeft = captureLeft
        self.captureRight = captureRight
        self.sizing = sizing
        self.fadeInFrames = fadeInFrames
        self.fadeOutFrames = fadeOutFrames
        self.needHistoryCapacity = needHistoryCapacity
    }
}

/// 128 bytes (an Apple-silicon cache line): keeps fields written by
/// different threads on different lines (no false sharing).
public typealias CacheLinePad = (
    UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
    UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64
)
let zeroPad: CacheLinePad = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

/// Shared state. Non-copyable, at a fixed address (see `SplitLinkHandle`).
public struct SplitLink: ~Copyable {
    // MARK: Read-only after init
    public let capacity: Int
    let mask: Int64
    let ringLeft: UnsafeMutablePointer<Float>
    let ringRight: UnsafeMutablePointer<Float>
    let buffersOffset: Int
    let captureBufferCount: Int
    let captureLeft: ChannelLocation
    let captureRight: ChannelLocation
    let sourceLeft: UnsafeMutablePointer<Float>
    let sourceRight: UnsafeMutablePointer<Float>
    public let sourceCapacity: Int
    public let maximumDelay: Int
    let fadeInFrames: Int
    let fadeOutFrames: Int
    let needHistory: UnsafeMutablePointer<Int64>
    let needHistoryCapacity: Int

    // MARK: Written by the capture IO thread
    let padCapture: CacheLinePad
    /// End of the range the writer is about to write (announced first).
    public let writeBegin: Atomic<Int64>
    /// End (exclusive) of the frames written so far; `Int64.min` = none yet.
    public let writtenUpTo: Atomic<Int64>
    /// Frames before this sample time are invalid (a gap or a reset).
    public let validFrom: Atomic<Int64>
    var nextExpected: Int64 = .min
    public let captureCycles: Atomic<UInt64>
    public let captureInvalidCycles: Atomic<UInt64>
    public let discontinuities: Atomic<UInt64>
    public let captureOverloads: Atomic<UInt64>
    public let captureFirstSample: Atomic<Int64>
    public let captureFirstHost: Atomic<UInt64>
    public let captureFirstReady: Atomic<Bool>

    // MARK: Written by the output IO thread
    let padOutput: CacheLinePad
    public let outputCycles: Atomic<UInt64>
    /// Invalid timestamp, unexpected block size: whole cycle silenced.
    public let outputInvalidCycles: Atomic<UInt64>
    public let underrunCycles: Atomic<UInt64>
    public let missingFrames: Atomic<UInt64>
    public let overwrittenCycles: Atomic<UInt64>
    public let overwrittenFrames: Atomic<UInt64>
    public let gapCycles: Atomic<UInt64>
    public let gapFrames: Atomic<UInt64>
    /// Running sum / count of `need` (for drift monitoring).
    public let needSum: Atomic<Int64>
    public let needCount: Atomic<Int64>
    /// Number of `need` values written to the history (monotonic).
    public let needHistoryWrites: Atomic<Int>
    public let outputFirstSample: Atomic<Int64>
    public let outputFirstHost: Atomic<UInt64>
    public let outputFirstReady: Atomic<Bool>
    var activeDelay: Int64 = 0
    var fadeInPending = true

    // MARK: Written by the engine
    let padEngine: CacheLinePad
    /// Read delay in frames; 0 = warm-up (silence, measurement only).
    public let delayFrames: Atomic<Int64>
    /// Output silenced immediately (e.g. sample-rate mismatch detected).
    public let muted: Atomic<Bool>
    let padEnd: CacheLinePad

    public init(configuration: SplitLinkConfiguration) {
        let sizing = configuration.sizing
        var size = 16
        while size < sizing.ringCapacity { size <<= 1 }
        capacity = size
        mask = Int64(size - 1)
        ringLeft = .allocate(capacity: size)
        ringLeft.initialize(repeating: 0, count: size)
        ringRight = .allocate(capacity: size)
        ringRight.initialize(repeating: 0, count: size)
        buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8
        captureBufferCount = configuration.captureLayout.bufferChannelCounts.count
        captureLeft = configuration.captureLeft
        captureRight = configuration.captureRight
        sourceCapacity = max(16, sizing.sourceCapacity)
        sourceLeft = .allocate(capacity: sourceCapacity)
        sourceLeft.initialize(repeating: 0, count: sourceCapacity)
        sourceRight = .allocate(capacity: sourceCapacity)
        sourceRight.initialize(repeating: 0, count: sourceCapacity)
        maximumDelay = min(sizing.maximumDelay, size - sourceCapacity - 64)
        fadeInFrames = max(1, configuration.fadeInFrames)
        fadeOutFrames = max(1, configuration.fadeOutFrames)
        needHistoryCapacity = max(16, configuration.needHistoryCapacity)
        needHistory = .allocate(capacity: needHistoryCapacity)
        needHistory.initialize(repeating: 0, count: needHistoryCapacity)

        padCapture = zeroPad
        writeBegin = Atomic(.min)
        writtenUpTo = Atomic(.min)
        validFrom = Atomic(.min)
        captureCycles = Atomic(0)
        captureInvalidCycles = Atomic(0)
        discontinuities = Atomic(0)
        captureOverloads = Atomic(0)
        captureFirstSample = Atomic(0)
        captureFirstHost = Atomic(0)
        captureFirstReady = Atomic(false)

        padOutput = zeroPad
        outputCycles = Atomic(0)
        outputInvalidCycles = Atomic(0)
        underrunCycles = Atomic(0)
        missingFrames = Atomic(0)
        overwrittenCycles = Atomic(0)
        overwrittenFrames = Atomic(0)
        gapCycles = Atomic(0)
        gapFrames = Atomic(0)
        needSum = Atomic(0)
        needCount = Atomic(0)
        needHistoryWrites = Atomic(0)
        outputFirstSample = Atomic(0)
        outputFirstHost = Atomic(0)
        outputFirstReady = Atomic(false)

        padEngine = zeroPad
        delayFrames = Atomic(0)
        muted = Atomic(false)
        padEnd = zeroPad
    }

    deinit {
        ringLeft.deallocate()
        ringRight.deallocate()
        sourceLeft.deallocate()
        sourceRight.deallocate()
        needHistory.deallocate()
    }
}

// MARK: - Sample times

public enum SampleTime {
    /// Integer sample index of a timestamp's mSampleTime, or nil if it is
    /// NaN, infinite or out of range (the cycle is then treated as invalid).
    @inline(__always)
    public static func index(_ sampleTime: Double) -> Int64? {
        guard sampleTime.isFinite, sampleTime.magnitude < 4.0e18 else { return nil }
        return Int64(sampleTime.rounded())
    }
}

// MARK: - Ring operations (real-time safe)

/// Result of a ring read. Frames [first, end) of the block are valid; the
/// rest was zeroed: before `first` because of a gap in the capture
/// (`gapFrames`) or because the writer already overwrote them
/// (`overwrittenFrames`); from `end` on because they were not captured yet
/// (underrun).
public struct RingReadResult: Equatable, Sendable {
    public let first: Int
    public let end: Int
    public let gapFrames: Int
    public let overwrittenFrames: Int
    public var validFrames: Int { max(0, end - first) }

    public init(first: Int, end: Int, gapFrames: Int = 0, overwrittenFrames: Int = 0) {
        self.first = first
        self.end = end
        self.gapFrames = gapFrames
        self.overwrittenFrames = overwrittenFrames
    }
}

public enum SampleRing {
    /// Writes `frames` frames for sample times [start, start + frames).
    /// - continuous: normal case;
    /// - forward jump (gap) or a backward jump larger than this block: the
    ///   frames before `start` become invalid (`validFrom = start`), so the
    ///   reader fades out/in instead of playing stale or silent "valid" audio;
    /// - small backward overlap (<= this block): rewritten in place.
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
        let end = start + Int64(frames)
        let expected = link.pointee.nextExpected
        var newWritten = end
        if expected == .min {
            link.pointee.validFrom.store(start, ordering: .releasing)
        } else if start != expected {
            link.pointee.discontinuities.wrappingAdd(1, ordering: .relaxed)
            let jump = start - expected
            if jump < 0 && -jump <= Int64(frames) {
                newWritten = max(expected, end)  // small overlap: in place
            } else {
                link.pointee.validFrom.store(start, ordering: .releasing)
            }
        }

        // Announce, fence, write, publish.
        link.pointee.writeBegin.store(end, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        let mask = link.pointee.mask
        let ringL = link.pointee.ringLeft, ringR = link.pointee.ringRight
        for frame in 0..<frames {
            let slot = Int((start + Int64(frame)) & mask)
            ringL[slot] = left[(sourceOffset + frame) * leftStride]
            ringR[slot] = right[(sourceOffset + frame) * rightStride]
        }
        link.pointee.nextExpected = newWritten
        link.pointee.writtenUpTo.store(newWritten, ordering: .releasing)
    }

    /// Reads [start, start + frames) into `left` / `right`; anything not
    /// valid is zeroed and classified (see `RingReadResult`).
    @inline(__always)
    public static func read(
        _ link: UnsafeMutablePointer<SplitLink>, start: Int64, frames: Int,
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    ) -> RingReadResult {
        let capacity = Int64(link.pointee.capacity)
        let written = link.pointee.writtenUpTo.load(ordering: .acquiring)
        let blockEnd = start + Int64(frames)
        guard written != .min, start < written else {  // nothing captured for this block yet
            for index in 0..<frames { left[index] = 0; right[index] = 0 }
            return RingReadResult(first: 0, end: 0)
        }
        let validFrom = link.pointee.validFrom.load(ordering: .acquiring)
        var first = min(max(start, max(validFrom, written - capacity)), blockEnd)
        let end = max(first, min(blockEnd, written))
        if end > first {
            let mask = link.pointee.mask
            let ringL = link.pointee.ringLeft, ringR = link.pointee.ringRight
            for time in first..<end {
                let slot = Int(time & mask)
                let index = Int(time - start)
                left[index] = ringL[slot]
                right[index] = ringR[slot]
            }
            // Anything the writer may have started overwriting meanwhile is lost.
            atomicMemoryFence(ordering: .acquiring)
            let announced = link.pointee.writeBegin.load(ordering: .relaxed)
            if announced - capacity > first { first = min(announced - capacity, end) }
        }
        let firstIndex = Int(first - start), endIndex = Int(end - start)
        for index in 0..<firstIndex { left[index] = 0; right[index] = 0 }
        if endIndex < frames { for index in endIndex..<frames { left[index] = 0; right[index] = 0 } }
        let gap = Int(max(0, min(validFrom, first) - start))
        return RingReadResult(
            first: firstIndex, end: endIndex, gapFrames: min(gap, firstIndex),
            overwrittenFrames: firstIndex - min(gap, firstIndex))
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
        guard let inputTime, inputTime.pointee.mFlags.contains(.sampleTimeValid),
            let start = SampleTime.index(inputTime.pointee.mSampleTime), let input,
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
        if !link.pointee.captureFirstReady.load(ordering: .relaxed) {
            link.pointee.captureFirstSample.store(start, ordering: .relaxed)
            let hostValid = inputTime.pointee.mFlags.contains(.hostTimeValid)
            link.pointee.captureFirstHost.store(hostValid ? inputTime.pointee.mHostTime : 0, ordering: .relaxed)
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
    /// One output cycle: measure `need`, read the ring at the fixed delay,
    /// render.
    public static func render(
        state: UnsafeMutablePointer<RenderState>,
        link: UnsafeMutablePointer<SplitLink>,
        outputTime: UnsafePointer<AudioTimeStamp>?,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) {
        link.pointee.outputCycles.wrappingAdd(1, ordering: .relaxed)
        let buffersOffset = link.pointee.buffersOffset
        let frames = RenderKernel.outputFrameCount(output, buffersOffset: buffersOffset)
        guard frames > 0, frames <= link.pointee.sourceCapacity,
            let outputTime, outputTime.pointee.mFlags.contains(.sampleTimeValid),
            let outputStart = SampleTime.index(outputTime.pointee.mSampleTime)
        else {
            link.pointee.outputInvalidCycles.wrappingAdd(1, ordering: .relaxed)
            link.pointee.fadeInPending = true
            RenderKernel.silence(output, buffersOffset: buffersOffset)
            return
        }
        if !link.pointee.outputFirstReady.load(ordering: .relaxed) {
            link.pointee.outputFirstSample.store(outputStart, ordering: .relaxed)
            let hostValid = outputTime.pointee.mFlags.contains(.hostTimeValid)
            link.pointee.outputFirstHost.store(hostValid ? outputTime.pointee.mHostTime : 0, ordering: .relaxed)
            link.pointee.outputFirstReady.store(true, ordering: .releasing)
        }

        // Measure how far ahead of the captured data this block reaches.
        let written = link.pointee.writtenUpTo.load(ordering: .acquiring)
        if written != .min {
            let need = outputStart + Int64(frames) - written
            link.pointee.needSum.wrappingAdd(need, ordering: .relaxed)
            link.pointee.needCount.wrappingAdd(1, ordering: .relaxed)
            let index = link.pointee.needHistoryWrites.load(ordering: .relaxed)
            link.pointee.needHistory[index % link.pointee.needHistoryCapacity] = need
            link.pointee.needHistoryWrites.store(index &+ 1, ordering: .releasing)
        }

        let delay = link.pointee.delayFrames.load(ordering: .acquiring)
        guard delay > 0, !link.pointee.muted.load(ordering: .relaxed) else {
            // Warm-up or muted: silence.
            link.pointee.fadeInPending = true
            RenderKernel.silence(output, buffersOffset: buffersOffset)
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

        let left = link.pointee.sourceLeft, right = link.pointee.sourceRight
        let result = SampleRing.read(link, start: outputStart - readDelay, frames: frames, left: left, right: right)

        if result.first > 0 {  // block starts with missing frames: fade in after them
            link.pointee.fadeInPending = true
            if result.gapFrames > 0 {
                link.pointee.gapCycles.wrappingAdd(1, ordering: .relaxed)
                link.pointee.gapFrames.wrappingAdd(UInt64(result.gapFrames), ordering: .relaxed)
            }
            if result.overwrittenFrames > 0 {
                link.pointee.overwrittenCycles.wrappingAdd(1, ordering: .relaxed)
                link.pointee.overwrittenFrames.wrappingAdd(UInt64(result.overwrittenFrames), ordering: .relaxed)
            }
        }
        if result.validFrames > 0 && link.pointee.fadeInPending {
            fade(left, right, from: result.first, count: min(link.pointee.fadeInFrames, result.validFrames), rising: true)
            link.pointee.fadeInPending = false
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

// MARK: - Engine-side handle

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

/// Counters and timing for the engine, the UI and the logs.
public struct SplitLinkStatus: Sendable, Equatable {
    public var delayFrames: Int64 = 0
    public var muted = false
    public var captureCycles: UInt64 = 0
    public var captureInvalidCycles: UInt64 = 0
    public var discontinuities: UInt64 = 0
    public var captureOverloads: UInt64 = 0
    public var outputCycles: UInt64 = 0
    public var outputInvalidCycles: UInt64 = 0
    public var underrunCycles: UInt64 = 0
    public var missingFrames: UInt64 = 0
    public var overwrittenCycles: UInt64 = 0
    public var overwrittenFrames: UInt64 = 0
    public var gapCycles: UInt64 = 0
    public var gapFrames: UInt64 = 0
    public var needSum: Int64 = 0
    public var needCount: Int64 = 0

    public static let empty = SplitLinkStatus()

    /// Output cycles that could not play (excluding underruns, which the
    /// delay adaptation handles first).
    public var badOutputCycles: UInt64 { outputInvalidCycles &+ overwrittenCycles &+ gapCycles }
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
    public var maximumDelay: Int { pointer.pointee.maximumDelay }
    public var capacity: Int { pointer.pointee.capacity }

    /// Number of `need` values recorded so far (use as a window marker).
    public var needHistoryPosition: Int { pointer.pointee.needHistoryWrites.load(ordering: .acquiring) }

    /// `need` values recorded since `from` (nil if the window was longer
    /// than the history).
    public func needValues(since from: Int) -> [Int64]? {
        let to = needHistoryPosition
        let capacity = pointer.pointee.needHistoryCapacity
        guard to >= from, to - from <= capacity - 32 else { return nil }  // keep clear of the writer
        return (from..<to).map { pointer.pointee.needHistory[$0 % capacity] }
    }

    /// First sample time of each side, and host times when the HAL marked
    /// them valid (host 0 = not valid). Diagnostics only.
    public func firstTimestamps() -> (capture: (sample: Int64, host: UInt64), output: (sample: Int64, host: UInt64))? {
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

    /// Sets the read delay (ends the warm-up the first time). The output
    /// IOProc fades across later changes.
    public func setDelay(_ delay: Int64) {
        pointer.pointee.delayFrames.store(max(1, delay), ordering: .releasing)
    }

    /// Silences the output immediately (real-time flag).
    public func setMuted(_ muted: Bool) {
        pointer.pointee.muted.store(muted, ordering: .relaxed)
    }

    public func status() -> SplitLinkStatus {
        let link = pointer
        var status = SplitLinkStatus()
        status.delayFrames = link.pointee.delayFrames.load(ordering: .relaxed)
        status.muted = link.pointee.muted.load(ordering: .relaxed)
        status.captureCycles = link.pointee.captureCycles.load(ordering: .relaxed)
        status.captureInvalidCycles = link.pointee.captureInvalidCycles.load(ordering: .relaxed)
        status.discontinuities = link.pointee.discontinuities.load(ordering: .relaxed)
        status.captureOverloads = link.pointee.captureOverloads.load(ordering: .relaxed)
        status.outputCycles = link.pointee.outputCycles.load(ordering: .relaxed)
        status.outputInvalidCycles = link.pointee.outputInvalidCycles.load(ordering: .relaxed)
        status.underrunCycles = link.pointee.underrunCycles.load(ordering: .relaxed)
        status.missingFrames = link.pointee.missingFrames.load(ordering: .relaxed)
        status.overwrittenCycles = link.pointee.overwrittenCycles.load(ordering: .relaxed)
        status.overwrittenFrames = link.pointee.overwrittenFrames.load(ordering: .relaxed)
        status.gapCycles = link.pointee.gapCycles.load(ordering: .relaxed)
        status.gapFrames = link.pointee.gapFrames.load(ordering: .relaxed)
        status.needSum = link.pointee.needSum.load(ordering: .relaxed)
        status.needCount = link.pointee.needCount.load(ordering: .relaxed)
        return status
    }
}
