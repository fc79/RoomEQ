// Lock-free tracing of IO callbacks, for the "split" experiment.
//
// Each traced IOProc writes one entry per callback into preallocated arrays
// (single writer = that IOProc's real-time thread). The experiment reads the
// arrays only after IO has been stopped. Real-time rules apply to the
// `record...` functions: no allocation, locks, logging, ARC.

import CoreAudio
import Darwin
import Synchronization

/// Preallocated per-callback storage. Non-copyable, at a fixed address.
public struct CallbackTrace: ~Copyable {
    public let capacity: Int
    /// Byte offset of `mBuffers` in AudioBufferList (computed once here, so
    /// the callbacks only do pointer arithmetic).
    let buffersOffset: Int
    /// inNow.mHostTime of each callback.
    let nowHost: UnsafeMutablePointer<UInt64>
    /// mSampleTime / mHostTime of the traced timestamp (capture: inInputTime,
    /// output: inOutputTime).
    let stampSample: UnsafeMutablePointer<Double>
    let stampHost: UnsafeMutablePointer<UInt64>
    /// Frames delivered/requested in that callback.
    let frames: UnsafeMutablePointer<UInt32>

    /// Entries written (<= capacity).
    public let recorded: Atomic<Int>
    /// Callbacks seen (may exceed capacity).
    public let callbacks: Atomic<Int>
    /// Callbacks whose traced timestamp lacked valid sample/host time.
    public let invalidStamps: Atomic<Int>
    /// Callbacks without usable audio buffers.
    public let missingBuffers: Atomic<Int>
    /// Peak |sample| of captured audio (Float bit pattern).
    public let peakBits: Atomic<UInt32>

    public init(capacity: Int) {
        let size = max(1, capacity)
        self.capacity = size
        buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8
        nowHost = .allocate(capacity: size)
        nowHost.initialize(repeating: 0, count: size)
        stampSample = .allocate(capacity: size)
        stampSample.initialize(repeating: 0, count: size)
        stampHost = .allocate(capacity: size)
        stampHost.initialize(repeating: 0, count: size)
        frames = .allocate(capacity: size)
        frames.initialize(repeating: 0, count: size)
        recorded = Atomic(0)
        callbacks = Atomic(0)
        invalidStamps = Atomic(0)
        missingBuffers = Atomic(0)
        peakBits = Atomic(0)
    }

    deinit {
        nowHost.deallocate()
        stampSample.deallocate()
        stampHost.deallocate()
        frames.deallocate()
    }
}

/// A copy of a trace, taken after IO stopped (normal thread).
public struct CallbackTraceSnapshot: Sendable {
    public var nowHost: [UInt64]
    public var stampSample: [Double]
    public var stampHost: [UInt64]
    public var frames: [UInt32]
    public var callbacks: Int
    public var invalidStamps: Int
    public var missingBuffers: Int
    public var peak: Float

    public init(
        nowHost: [UInt64], stampSample: [Double], stampHost: [UInt64], frames: [UInt32],
        callbacks: Int, invalidStamps: Int = 0, missingBuffers: Int = 0, peak: Float = 0
    ) {
        self.nowHost = nowHost
        self.stampSample = stampSample
        self.stampHost = stampHost
        self.frames = frames
        self.callbacks = callbacks
        self.invalidStamps = invalidStamps
        self.missingBuffers = missingBuffers
        self.peak = peak
    }

    public var isEmpty: Bool { nowHost.isEmpty }
}

/// Owns one trace. Pass `rawPointer` as IOProc client data.
public final class CallbackTraceHandle: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<CallbackTrace>

    public init(capacity: Int) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: CallbackTrace(capacity: capacity))
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    public var rawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(pointer) }

    /// Copies the recorded entries. Call only after the IOProc has stopped.
    public func snapshot() -> CallbackTraceSnapshot {
        let trace = pointer
        let count = min(trace.pointee.recorded.load(ordering: .acquiring), trace.pointee.capacity)
        return CallbackTraceSnapshot(
            nowHost: Array(UnsafeBufferPointer(start: trace.pointee.nowHost, count: count)),
            stampSample: Array(UnsafeBufferPointer(start: trace.pointee.stampSample, count: count)),
            stampHost: Array(UnsafeBufferPointer(start: trace.pointee.stampHost, count: count)),
            frames: Array(UnsafeBufferPointer(start: trace.pointee.frames, count: count)),
            callbacks: trace.pointee.callbacks.load(ordering: .relaxed),
            invalidStamps: trace.pointee.invalidStamps.load(ordering: .relaxed),
            missingBuffers: trace.pointee.missingBuffers.load(ordering: .relaxed),
            peak: Float(bitPattern: trace.pointee.peakBits.load(ordering: .relaxed)))
    }

    /// Clears the trace for a new run. Call only while the IOProc is stopped.
    public func reset() {
        pointer.pointee.recorded.store(0, ordering: .relaxed)
        pointer.pointee.callbacks.store(0, ordering: .relaxed)
        pointer.pointee.invalidStamps.store(0, ordering: .relaxed)
        pointer.pointee.missingBuffers.store(0, ordering: .relaxed)
        pointer.pointee.peakBits.store(0, ordering: .relaxed)
    }
}

/// Real-time recording functions.
public enum CallbackTracer {
    /// Capture side: records timing, frames and peak of the input (Float32
    /// assumed), and silences any output buffers of the capture device.
    public static func recordCapture(
        _ trace: UnsafeMutablePointer<CallbackTrace>,
        now: UnsafePointer<AudioTimeStamp>?,
        stamp: UnsafePointer<AudioTimeStamp>?,
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) {
        let offset = trace.pointee.buffersOffset
        silence(output, buffersOffset: offset)
        var frames = 0
        var peak: Float = 0
        if let input {
            let list = UnsafeMutableRawPointer(mutating: input)
            for index in 0..<Int(list.load(as: UInt32.self)) {
                let buffer = RenderKernel.audioBuffer(list, offset, index).pointee
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData else { continue }
                let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                if frames == 0 { frames = samples / channels }
                let floats = data.assumingMemoryBound(to: Float.self)
                for sample in 0..<samples {
                    let magnitude = floats[sample].magnitude
                    if magnitude > peak { peak = magnitude }
                }
            }
        }
        if frames == 0 { trace.pointee.missingBuffers.wrappingAdd(1, ordering: .relaxed) }
        if peak.isFinite { trace.pointee.peakBits.max(peak.bitPattern, ordering: .relaxed) }
        append(trace, now: now, stamp: stamp, frames: frames)
    }

    /// Output side: writes silence and records timing and frames.
    public static func recordOutput(
        _ trace: UnsafeMutablePointer<CallbackTrace>,
        now: UnsafePointer<AudioTimeStamp>?,
        stamp: UnsafePointer<AudioTimeStamp>?,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) {
        let frames = silence(output, buffersOffset: trace.pointee.buffersOffset)
        if frames == 0 { trace.pointee.missingBuffers.wrappingAdd(1, ordering: .relaxed) }
        append(trace, now: now, stamp: stamp, frames: frames)
    }

    /// Zeroes every output buffer; returns the frame count of the first one.
    @discardableResult
    @inline(__always)
    static func silence(_ output: UnsafeMutablePointer<AudioBufferList>?, buffersOffset: Int) -> Int {
        guard let output else { return 0 }
        let list = UnsafeMutableRawPointer(output)
        var frames = 0
        for index in 0..<Int(list.load(as: UInt32.self)) {
            let buffer = RenderKernel.audioBuffer(list, buffersOffset, index).pointee
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            let channels = Int(buffer.mNumberChannels)
            if frames == 0 && channels > 0 {
                frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            }
        }
        return frames
    }

    @inline(__always)
    static func append(
        _ trace: UnsafeMutablePointer<CallbackTrace>,
        now: UnsafePointer<AudioTimeStamp>?, stamp: UnsafePointer<AudioTimeStamp>?, frames: Int
    ) {
        trace.pointee.callbacks.wrappingAdd(1, ordering: .relaxed)
        let valid: AudioTimeStampFlags = [.sampleTimeValid, .hostTimeValid]
        guard let now, let stamp, stamp.pointee.mFlags.contains(valid) else {
            trace.pointee.invalidStamps.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let index = trace.pointee.recorded.load(ordering: .relaxed)
        guard index < trace.pointee.capacity else { return }
        trace.pointee.nowHost[index] = now.pointee.mHostTime
        trace.pointee.stampSample[index] = stamp.pointee.mSampleTime
        trace.pointee.stampHost[index] = stamp.pointee.mHostTime
        trace.pointee.frames[index] = UInt32(clamping: frames)
        trace.pointee.recorded.store(index + 1, ordering: .releasing)
    }
}
