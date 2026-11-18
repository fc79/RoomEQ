// "Skip silence" for recording: decides when an app's file opens and closes.
//
// With the gate on, nothing is written while the app is silent. When a sample
// goes above the threshold a file opens, starting with up to `preRoll` frames
// of what came just before (so attacks are not cut). After the last sound the
// file keeps `tail` frames; if the silence lasts `hold` frames the file is
// closed and the rest of the silence is discarded. When sound returns before
// `hold`, the buffered silence is written and the file continues.
// With the gate off, the file opens with the first frames and everything is
// written.
//
// Pure logic on interleaved stereo frames, driven by the recording writer
// thread (never the real-time thread: it may allocate on first use).

public protocol RecordingSink {
    mutating func open()
    mutating func write(_ samples: UnsafeBufferPointer<Float>)
    mutating func close()
}

public struct SilenceGate {
    public struct Settings: Equatable, Sendable {
        public var threshold: Float
        public var holdFrames: Int
        public var preRollFrames: Int
        public var tailFrames: Int

        /// −60 dBFS, 2 s hold, 0.5 s before and after the sound.
        public static func standard(sampleRate: Double) -> Settings {
            Settings(
                threshold: Float(Decibels.linear(fromDecibels: -60)),
                holdFrames: Int((sampleRate * 2).rounded()),
                preRollFrames: Int((sampleRate * 0.5).rounded()),
                tailFrames: Int((sampleRate * 0.5).rounded()))
        }
    }

    public let settings: Settings
    public let enabled: Bool
    /// A file is open.
    public private(set) var isOpen = false
    /// Frames since the last sample above the threshold (while open).
    private var silentRun = 0
    /// Silence held back after the tail, written only if sound returns.
    private var pending: [Float] = []
    /// Last `preRollFrames` frames seen while closed (interleaved).
    private var preRoll: [Float] = []

    public init(settings: Settings, enabled: Bool) {
        self.settings = settings
        self.enabled = enabled
        // Bounded sizes, reserved once.
        pending.reserveCapacity(max(0, settings.holdFrames - settings.tailFrames) * 2)
        preRoll.reserveCapacity(settings.preRollFrames * 2)
    }

    /// True while the app is silent with no file open (gate on).
    public var isPaused: Bool { enabled && !isOpen }

    /// Feeds interleaved stereo frames.
    public mutating func process<S: RecordingSink>(_ samples: UnsafeBufferPointer<Float>, into sink: inout S) {
        guard enabled else {
            if !isOpen { sink.open(); isOpen = true }
            sink.write(samples)
            return
        }
        let frames = samples.count / 2
        var frame = 0
        while frame < frames {
            if !isOpen {
                // Find the first loud frame; everything before goes to pre-roll.
                guard let loud = firstLoudFrame(samples, from: frame, to: frames) else {
                    keepPreRoll(samples, from: frame, to: frames)
                    return
                }
                keepPreRoll(samples, from: frame, to: loud)
                sink.open()
                isOpen = true
                silentRun = 0
                pending.removeAll(keepingCapacity: true)
                if !preRoll.isEmpty { preRoll.withUnsafeBufferPointer { sink.write($0) } }
                preRoll.removeAll(keepingCapacity: true)
                frame = loud
                continue
            }
            // Open: copy runs, tracking silence.
            var runStart = frame
            while frame < frames {
                if isLoud(samples, frame) {
                    if !pending.isEmpty {
                        flushRun(samples, from: runStart, to: frame, into: &sink)
                        runStart = frame
                        pending.withUnsafeBufferPointer { sink.write($0) }
                        pending.removeAll(keepingCapacity: true)
                    }
                    silentRun = 0
                } else {
                    silentRun += 1
                    if silentRun > settings.tailFrames {
                        // Past the tail: hold back instead of writing.
                        flushRun(samples, from: runStart, to: frame, into: &sink)
                        pending.append(samples[frame * 2])
                        pending.append(samples[frame * 2 + 1])
                        runStart = frame + 1
                        if silentRun >= settings.holdFrames {
                            sink.close()
                            isOpen = false
                            // The end of the dropped silence is the pre-roll of
                            // the next file, so it always starts with its margin.
                            let keep = min(pending.count, settings.preRollFrames * 2)
                            preRoll.append(contentsOf: pending.suffix(keep))
                            pending.removeAll(keepingCapacity: true)
                            frame += 1
                            break
                        }
                    }
                }
                frame += 1
            }
            if isOpen { flushRun(samples, from: runStart, to: frame, into: &sink) }
        }
    }

    /// Closes the file if open (end of recording, or a new file is forced).
    /// Held-back silence is dropped.
    public mutating func finish<S: RecordingSink>(into sink: inout S) {
        if isOpen { sink.close() }
        isOpen = false
        silentRun = 0
        pending.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    private func isLoud(_ samples: UnsafeBufferPointer<Float>, _ frame: Int) -> Bool {
        abs(samples[frame * 2]) > settings.threshold || abs(samples[frame * 2 + 1]) > settings.threshold
    }

    private func firstLoudFrame(_ samples: UnsafeBufferPointer<Float>, from start: Int, to end: Int) -> Int? {
        var frame = start
        while frame < end {
            if isLoud(samples, frame) { return frame }
            frame += 1
        }
        return nil
    }

    private func flushRun<S: RecordingSink>(
        _ samples: UnsafeBufferPointer<Float>, from start: Int, to end: Int, into sink: inout S
    ) {
        guard end > start, let base = samples.baseAddress else { return }
        sink.write(UnsafeBufferPointer(start: base + start * 2, count: (end - start) * 2))
    }

    private mutating func keepPreRoll(_ samples: UnsafeBufferPointer<Float>, from start: Int, to end: Int) {
        let limit = settings.preRollFrames * 2
        guard limit > 0, end > start else { return }
        let first = max(start, end - settings.preRollFrames)
        for frame in first..<end {
            preRoll.append(samples[frame * 2])
            preRoll.append(samples[frame * 2 + 1])
        }
        if preRoll.count > limit { preRoll.removeFirst(preRoll.count - limit) }
    }
}
