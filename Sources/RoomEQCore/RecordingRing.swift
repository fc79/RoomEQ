// Single-producer / single-consumer ring of stereo frames, for recording.
//
// The producer is a real-time IOProc: it copies one stereo pair out of the
// tap's interleaved buffer and never blocks, allocates or locks. The consumer
// is the recording writer (a normal thread), which drains the ring into the
// silence gate and the WAV file. When the writer falls behind and the ring is
// full, the producer drops the new frames and counts them; the consumer then
// writes the same number of silent frames where they were lost (`drain`), so
// every file keeps its length and files of different apps stay aligned.

import Synchronization

public final class RecordingRing: @unchecked Sendable {
    /// Capacity in frames (a power of two).
    public let capacity: Int
    private let mask: Int
    /// Interleaved L/R samples, `capacity * 2` floats.
    private let storage: UnsafeMutablePointer<Float>
    /// Total frames ever written / read (monotonic; the ring index is & mask).
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    /// Highest absolute sample written since the last `takePeak()` (Float bits).
    private let peak = Atomic<UInt32>(0)

    /// - Parameter minimumFrames: rounded up to a power of two.
    public init(minimumFrames: Int) {
        var size = 1
        while size < max(minimumFrames, 2) { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size * 2)
        storage.initialize(repeating: 0, count: size * 2)
    }

    deinit { storage.deallocate() }

    // MARK: Producer (real-time thread)

    /// Copies `frames` frames of channels `left` and `right` from an
    /// interleaved buffer with `channelCount` channels. Returns the frames
    /// stored; the rest are counted as dropped.
    @discardableResult
    public func write(
        interleaved source: UnsafePointer<Float>, frames: Int, channelCount: Int, left: Int, right: Int
    ) -> Int {
        guard frames > 0, channelCount > 0, left < channelCount, right < channelCount else { return 0 }
        let writeCount = written.load(ordering: .relaxed)
        let room = capacity - (writeCount - read.load(ordering: .acquiring))
        let count = min(frames, room)
        var blockPeak: Float = 0
        for frame in 0..<count {
            let index = ((writeCount + frame) & mask) * 2
            let leftSample = source[frame * channelCount + left]
            let rightSample = source[frame * channelCount + right]
            storage[index] = leftSample
            storage[index + 1] = rightSample
            // NaN/inf don't count (max() would keep NaN out anyway).
            if leftSample.isFinite { blockPeak = max(blockPeak, abs(leftSample)) }
            if rightSample.isFinite { blockPeak = max(blockPeak, abs(rightSample)) }
        }
        written.store(writeCount + count, ordering: .releasing)
        if count < frames { dropped.add(frames - count, ordering: .relaxed) }
        if blockPeak > 0 {
            // Positive floats order like their bit patterns: an integer max.
            peak.max(blockPeak.bitPattern, ordering: .relaxed)
        }
        return count
    }

    /// Counts `frames` that could not be stored (e.g. a buffer in an
    /// unexpected layout), so the writer replaces them with silence.
    public func addDropped(_ frames: Int) {
        if frames > 0 { dropped.add(frames, ordering: .relaxed) }
    }

    /// Highest absolute sample since the last call (and resets it), for the
    /// level meters.
    public func takePeak() -> Float { Float(bitPattern: peak.exchange(0, ordering: .relaxed)) }

    // MARK: Consumer (writer thread)

    /// Frames ready to read.
    public var available: Int { written.load(ordering: .acquiring) - read.load(ordering: .relaxed) }

    /// Copies up to `maxFrames` frames (interleaved L/R) into `destination`.
    /// Returns the frames copied.
    public func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let r = read.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        let count = min(maxFrames, w - r)
        guard count > 0 else { return 0 }
        for frame in 0..<count {
            let index = ((r + frame) & mask) * 2
            destination[frame * 2] = storage[index]
            destination[frame * 2 + 1] = storage[index + 1]
        }
        read.store(r + count, ordering: .releasing)
        return count
    }

    /// Frames dropped since the last call (and resets the count).
    public func takeDroppedFrames() -> Int { dropped.exchange(0, ordering: .relaxed) }

    /// A piece of a drain, in time order.
    public enum DrainChunk {
        /// Interleaved L/R samples (valid only during the `emit` call).
        case audio(UnsafeBufferPointer<Float>)
        /// Frames that were dropped: write this much silence.
        case silence(frames: Int)
    }

    /// Moves everything in the ring to `emit`, in time order, through
    /// `scratch` (`scratchFrames` stereo frames). Frames dropped since the
    /// last drain are reported as silence where they were lost: frames are
    /// dropped only while the ring is full, so they come after everything
    /// stored when the drain starts, and before what the producer stores
    /// while this drain frees room. Returns the frames dropped.
    @discardableResult
    public func drain(
        scratch: UnsafeMutablePointer<Float>, scratchFrames: Int, emit: (DrainChunk) -> Void
    ) -> Int {
        let lost = takeDroppedFrames()
        var beforeGap = lost > 0 ? available : 0
        while beforeGap > 0 {
            let count = read(into: scratch, maxFrames: min(beforeGap, scratchFrames))
            if count == 0 { break }
            emit(.audio(UnsafeBufferPointer(start: scratch, count: count * 2)))
            beforeGap -= count
        }
        if lost > 0 { emit(.silence(frames: lost)) }
        while true {
            let count = read(into: scratch, maxFrames: scratchFrames)
            if count == 0 { break }
            emit(.audio(UnsafeBufferPointer(start: scratch, count: count * 2)))
        }
        return lost
    }
}
