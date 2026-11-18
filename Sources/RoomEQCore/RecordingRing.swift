// Single-producer / single-consumer ring of stereo frames, for recording.
//
// The producer is a real-time IOProc: it copies one stereo pair out of the
// tap's interleaved buffer and never blocks, allocates or locks. The consumer
// is the recording writer (a normal thread), which drains the ring into the
// silence gate and the WAV file. When the writer falls behind and the ring is
// full, the producer drops the new frames, counts them and notes where the
// loss began; the consumer then writes the same number of silent frames at
// that point (`drain`), so every file keeps its length and files of
// different apps stay aligned.

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
    /// Frames dropped since the consumer last took the count.
    private let dropped = Atomic<Int>(0)
    /// Where the current loss happened: the `written` count when the first
    /// frame of it was dropped (frames before it came before the loss).
    private let dropPosition = Atomic<Int>(0)
    /// Frames stored as silence instead of the audio (`writeSilence`).
    private let silenced = Atomic<Int>(0)
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
        if count < frames { noteDropped(frames - count, at: writeCount + count) }
        if blockPeak > 0 {
            // Positive floats order like their bit patterns: an integer max.
            peak.max(blockPeak.bitPattern, ordering: .relaxed)
        }
        return count
    }

    /// Stores `frames` silent frames (e.g. for a buffer in an unexpected
    /// layout, so the file keeps its length and its order). Returns the
    /// frames stored; the rest are counted as dropped.
    @discardableResult
    public func writeSilence(frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let writeCount = written.load(ordering: .relaxed)
        let room = capacity - (writeCount - read.load(ordering: .acquiring))
        let count = min(frames, room)
        for frame in 0..<count {
            let index = ((writeCount + frame) & mask) * 2
            storage[index] = 0
            storage[index + 1] = 0
        }
        written.store(writeCount + count, ordering: .releasing)
        silenced.add(count, ordering: .relaxed)
        if count < frames { noteDropped(frames - count, at: writeCount + count) }
        return count
    }

    /// Counts a loss; the first one since the consumer took the count also
    /// records where it happened (released with the count).
    @inline(__always)
    private func noteDropped(_ frames: Int, at position: Int) {
        if dropped.load(ordering: .relaxed) == 0 { dropPosition.store(position, ordering: .relaxed) }
        dropped.add(frames, ordering: .releasing)
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
    public func takeDroppedFrames() -> Int { dropped.exchange(0, ordering: .acquiring) }

    /// Frames stored as silence by `writeSilence` since the last call (and
    /// resets the count): audio that was lost too, to be reported.
    public func takeSilencedFrames() -> Int { silenced.exchange(0, ordering: .relaxed) }

    /// Throws away everything stored, any loss not yet taken and the peak
    /// (after a failed capture attempt: nothing it wrote may reach the files
    /// or the meters). Consumer side only: a producer that still runs (an
    /// IOProc that could not be stopped) just keeps writing after it.
    public func discardAll() {
        read.store(written.load(ordering: .acquiring), ordering: .releasing)
        _ = dropped.exchange(0, ordering: .acquiring)
        _ = silenced.exchange(0, ordering: .relaxed)
        _ = peak.exchange(0, ordering: .relaxed)
    }

    /// A piece of a drain, in time order.
    public enum DrainChunk {
        /// Interleaved L/R samples (valid only during the `emit` call).
        case audio(UnsafeBufferPointer<Float>)
        /// Frames that were dropped: write this much silence.
        case silence(frames: Int)
    }

    /// Moves everything in the ring to `emit`, in time order, through
    /// `scratch` (`scratchFrames` stereo frames). Frames dropped (also
    /// while this drain runs, e.g. when `emit` stalls on a slow disk) are
    /// reported as silence at the point where they were lost: after the
    /// frames stored before the loss, before those stored after it. Returns
    /// the frames dropped.
    @discardableResult
    public func drain(
        scratch: UnsafeMutablePointer<Float>, scratchFrames: Int, emit: (DrainChunk) -> Void
    ) -> Int {
        var total = 0
        var lost = 0
        var lossAt = 0
        while true {
            if lost == 0 {
                lost = takeDroppedFrames()
                if lost > 0 {
                    lossAt = dropPosition.load(ordering: .relaxed)
                    total += lost
                }
            }
            var maxFrames = scratchFrames
            if lost > 0 {
                let beforeLoss = lossAt - read.load(ordering: .relaxed)
                if beforeLoss <= 0 {
                    emit(.silence(frames: lost))
                    lost = 0
                    continue
                }
                maxFrames = min(maxFrames, beforeLoss)
            }
            let count = read(into: scratch, maxFrames: maxFrames)
            if count == 0 {
                if lost > 0 {  // not expected: the loss point is never past `written`
                    emit(.silence(frames: lost))
                    lost = 0
                    continue
                }
                break
            }
            emit(.audio(UnsafeBufferPointer(start: scratch, count: count * 2)))
        }
        return total
    }
}
