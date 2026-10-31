// Clip indicator model: what clipped, by how much, and whether RoomEQ's
// processing (the EQ) caused it.
//
// The render kernel keeps CUMULATIVE counters per session (never reset by
// the main thread) and max levels (reset with one atomic exchange, like the
// meter peaks). "Since the last reset" = current counters minus a baseline
// taken at reset, kept by the controller.

import Foundation

/// Raw values read from the render state (cumulative counts, max levels).
public struct ClipCounters: Sendable, Equatable {
    /// Tap samples with |x| > 1 (the source itself is over full scale).
    public var inputOvers: UInt64
    /// Output samples with |y| > 1 before the clamp (all causes).
    public var outputOvers: UInt64
    /// Output overs on samples whose input was within full scale: caused
    /// by RoomEQ's processing (EQ; the preamp never boosts).
    public var processingOvers: UInt64
    /// Largest |x| of the tap / |y| before the clamp / |y| of a
    /// processing-caused over, linear (1.0 = 0 dBFS).
    public var maxInputLevel: Float
    public var maxOutputLevel: Float
    public var maxProcessingOverLevel: Float

    public init(
        inputOvers: UInt64 = 0, outputOvers: UInt64 = 0, processingOvers: UInt64 = 0,
        maxInputLevel: Float = 0, maxOutputLevel: Float = 0, maxProcessingOverLevel: Float = 0
    ) {
        self.inputOvers = inputOvers
        self.outputOvers = outputOvers
        self.processingOvers = processingOvers
        self.maxInputLevel = maxInputLevel
        self.maxOutputLevel = maxOutputLevel
        self.maxProcessingOverLevel = maxProcessingOverLevel
    }

    public static let zero = ClipCounters()
}

/// Clipping since the last reset, for the UI.
public struct ClipStatus: Sendable, Equatable {
    /// Source samples over full scale (Spotify, YouTube… already clipping).
    public var inputClippedSamples: UInt64
    /// Output samples over full scale (clamped to ±1 before the device).
    public var outputClippedSamples: UInt64
    /// Output overs whose input sample was within full scale.
    public var processingClippedSamples: UInt64
    /// dB above full scale of the largest input / output sample, nil when
    /// nothing went over 0 dBFS.
    public var maxInputOverDecibels: Double?
    public var maxOutputOverDecibels: Double?
    /// dB above full scale of the largest processing-caused over.
    public var maxProcessingOverDecibels: Double?

    public static let none = ClipStatus(counters: .zero, baseline: .zero)

    /// `counters` minus `baseline` (counts); max levels as read (they are
    /// reset at the source).
    public init(counters: ClipCounters, baseline: ClipCounters) {
        func since(_ now: UInt64, _ then: UInt64) -> UInt64 { now >= then ? now - then : now }  // new session: no baseline
        inputClippedSamples = since(counters.inputOvers, baseline.inputOvers)
        outputClippedSamples = since(counters.outputOvers, baseline.outputOvers)
        processingClippedSamples = since(counters.processingOvers, baseline.processingOvers)
        maxInputOverDecibels = Self.overDecibels(counters.maxInputLevel)
        maxOutputOverDecibels = Self.overDecibels(counters.maxOutputLevel)
        maxProcessingOverDecibels = processingClippedSamples > 0 ? Self.overDecibels(counters.maxProcessingOverLevel) : nil
    }

    /// Output clipped since the last reset (the CLIP badge).
    public var isClipping: Bool { outputClippedSamples > 0 }

    /// RoomEQ's processing made samples clip that were fine in the source:
    /// lowering the preamp fixes it. (Even an all-cut EQ can raise peaks: a
    /// filter changes the phase of the frequencies near it, so a waveform
    /// already close to 0 dBFS can come out a little higher.)
    public var eqCausedClipping: Bool { processingClippedSamples > 0 }

    /// The source itself is over full scale: no preamp setting in RoomEQ
    /// can make it clean at the input (it is clamped like any other over).
    public var sourceClipping: Bool { inputClippedSamples > 0 }

    /// Preamp that would have avoided the processing-caused overs measured
    /// at `currentPreamp`: currentPreamp - maxOver, rounded down to 0,1 dB,
    /// at least -24 dB. Nil unless the EQ caused clipping.
    public func suggestedPreamp(currentPreamp: Double) -> Double? {
        guard eqCausedClipping, let over = maxProcessingOverDecibels, over > 0, over.isFinite else { return nil }
        let target = ((currentPreamp - over) * 10 + 1e-6).rounded(.down) / 10
        return Preamp.clamp(target)
    }

    static func overDecibels(_ level: Float) -> Double? {
        guard level > 1 else { return nil }
        return 20 * log10(Double(level))
    }
}
