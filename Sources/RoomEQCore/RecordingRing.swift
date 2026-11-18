// Single-producer / single-consumer ring of stereo frames, for recording.
//
// The producer is a real-time IOProc: it copies one stereo pair out of the
// tap's interleaved buffer and never blocks, allocates or locks. The consumer
// is the recording writer (a normal thread), which drains the ring into the
// silence gate and the WAV file. When the writer falls behind and the ring is
// full, the producer drops the new frames and counts them; the consumer then
// writes the same number of silent frames, so every file keeps its length and
// files of different apps stay aligned.

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
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        let room = capacity - (w - r)
        let count = min(frames, room)
        for frame in 0..<count {
            let index = ((w + frame) & mask) * 2
            storage[index] = source[frame * channelCount + left]
            storage[index + 1] = source[frame * channelCount + right]
        }
        written.store(w + count, ordering: .releasing)
        if count < frames { dropped.add(frames - count, ordering: .relaxed) }
        return count
    }

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
}
