// State shared between the real-time audio thread and the rest of the app.
//
// Threading contract
// ------------------
// * `RenderState` lives in manually allocated memory (see `RenderStateHandle`)
//   so its address never changes and the real-time thread can reach it
//   through a plain pointer: no reference counting, no locks.
// * "Control" values (gain, bypass, output pair) are written by the main
//   thread and read by the real-time thread through atomics.
// * "Meter" values are written by the real-time thread (and the overload
//   listener) and read by the main thread through atomics.
// * Layout tables are filled once in `init` and are read-only afterwards.
// * Fields marked "RT-private" are touched ONLY by the real-time thread.
// * The engine guarantees the IOProc and the overload listener are removed
//   before the `RenderStateHandle` that owns this memory is released.

import CoreAudio
import Synchronization

/// Everything needed to build a `RenderState` (computed on a normal thread).
public struct RenderConfiguration: Sendable {
    /// Buffer layout of the aggregate device's INPUT buffer list.
    public var inputLayout: BufferListLayout
    /// Where the tap's left / right channels are in the input buffer list.
    /// For a mono tap both point at the same channel.
    public var tapLeft: ChannelLocation
    public var tapRight: ChannelLocation
    /// Buffer layout of the aggregate device's OUTPUT buffer list.
    public var outputLayout: BufferListLayout
    /// Current device sample rate (Hz).
    public var sampleRate: Double
    /// Size of the internal processing chunk. IO buffers larger than this
    /// are processed in several chunks, so any IO size works.
    public var chunkFrames: Int
    /// Duration of a gain change (seconds), independent of buffer size.
    public var gainRampSeconds: Double
    /// Duration of the bypass crossfade (seconds).
    public var bypassCrossfadeSeconds: Double

    public init(
        inputLayout: BufferListLayout,
        tapLeft: ChannelLocation,
        tapRight: ChannelLocation,
        outputLayout: BufferListLayout,
        sampleRate: Double,
        chunkFrames: Int = 1024,
        gainRampSeconds: Double = 0.015,
        bypassCrossfadeSeconds: Double = 0.010
    ) {
        self.inputLayout = inputLayout
        self.tapLeft = tapLeft
        self.tapRight = tapRight
        self.outputLayout = outputLayout
        self.sampleRate = sampleRate
        self.chunkFrames = chunkFrames
        self.gainRampSeconds = gainRampSeconds
        self.bypassCrossfadeSeconds = bypassCrossfadeSeconds
    }
}

/// Real-time render state. Non-copyable: exactly one instance exists per
/// running engine, at a fixed address.
public struct RenderState: ~Copyable {
    // MARK: Control (main thread -> real-time thread)

    /// Target linear gain. The real-time thread ramps towards it.
    public let targetGain: Atomic<Float>
    /// When true the output crossfades to the unprocessed (dry) signal.
    /// The DSP chain keeps running so un-bypassing is click-free too.
    public let bypass: Atomic<Bool>
    /// Output channel pair, packed with `OutputChannelPair.packed`.
    public let outputPair: Atomic<UInt32>

    // MARK: Meters (real-time thread -> main thread)

    /// Peak |sample| since the last read, stored as Float bit patterns
    /// (for non-negative floats the bit pattern grows with the value, so an
    /// integer atomic max is a float max). Output peaks are measured BEFORE
    /// the final clamp, so overs above 0 dBFS remain visible.
    public let inputPeakLeftBits: Atomic<UInt32>
    public let inputPeakRightBits: Atomic<UInt32>
    public let outputPeakLeftBits: Atomic<UInt32>
    public let outputPeakRightBits: Atomic<UInt32>
    /// Total output samples whose magnitude exceeded 1.0 (then clamped).
    public let clippedSamples: Atomic<UInt64>
    /// Total samples that were NaN/Inf and were replaced by silence.
    public let nonFiniteSamples: Atomic<UInt64>
    /// IO cycles where the tap input was missing or had an unexpected
    /// layout (output was silenced for that cycle).
    public let invalidInputCycles: Atomic<UInt64>
    /// IO cycles where the output buffer list didn't match the layout
    /// recorded at start (output was silenced for that cycle).
    public let invalidOutputCycles: Atomic<UInt64>
    /// IO cycles rendered so far.
    public let renderedCycles: Atomic<UInt64>
    /// Overload ("xrun") notifications from the device, counted by the
    /// engine's real-time-safe listener (`RenderKernel.recordOverload`).
    public let overloads: Atomic<UInt64>

    // MARK: Layout (read-only after init)

    let audioBuffersOffset: Int
    let inputBufferCount: Int
    let tapLeft: ChannelLocation
    let tapRight: ChannelLocation
    let outputBufferCount: Int
    let outputBufferChannels: UnsafeMutablePointer<Int>
    let outputChannelCount: Int
    let outputLocations: UnsafeMutablePointer<ChannelLocation>

    // MARK: RT-private

    /// Output gain, ramped over a fixed time.
    var gainRamp: LinearRamp
    /// Wet (processed) share of the output: 1 = DSP on, 0 = bypassed.
    var wetMix: LinearRamp
    /// Scratch buffers (one chunk per channel), preallocated:
    /// dry = tap signal, wet = after the DSP chain.
    let dryLeft: UnsafeMutablePointer<Float>
    let dryRight: UnsafeMutablePointer<Float>
    let wetLeft: UnsafeMutablePointer<Float>
    let wetRight: UnsafeMutablePointer<Float>
    let chunkFrames: Int
    /// The DSP chain (stage 3: EQ).
    var processor: DSPProcessor

    public init(configuration: RenderConfiguration, gain: Float, bypass: Bool, outputPair: OutputChannelPair) {
        targetGain = Atomic(gain)
        self.bypass = Atomic(bypass)
        self.outputPair = Atomic(outputPair.packed)

        inputPeakLeftBits = Atomic(0)
        inputPeakRightBits = Atomic(0)
        outputPeakLeftBits = Atomic(0)
        outputPeakRightBits = Atomic(0)
        clippedSamples = Atomic(0)
        nonFiniteSamples = Atomic(0)
        invalidInputCycles = Atomic(0)
        invalidOutputCycles = Atomic(0)
        renderedCycles = Atomic(0)
        overloads = Atomic(0)

        audioBuffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8
        inputBufferCount = configuration.inputLayout.bufferChannelCounts.count
        tapLeft = configuration.tapLeft
        tapRight = configuration.tapRight

        let outCounts = configuration.outputLayout.bufferChannelCounts
        outputBufferCount = outCounts.count
        outputBufferChannels = .allocate(capacity: max(1, outCounts.count))
        outputBufferChannels.initialize(repeating: 0, count: max(1, outCounts.count))
        for (index, count) in outCounts.enumerated() { outputBufferChannels[index] = count }

        let outChannels = configuration.outputLayout.channels
        outputChannelCount = outChannels.count
        outputLocations = .allocate(capacity: max(1, outChannels.count))
        outputLocations.initialize(
            repeating: ChannelLocation(buffer: 0, offset: 0, stride: 1, stream: 0), count: max(1, outChannels.count))
        for (index, location) in outChannels.enumerated() { outputLocations[index] = location }

        let rate = configuration.sampleRate
        gainRamp = LinearRamp(
            value: gain, rampFrames: LinearRamp.frames(seconds: configuration.gainRampSeconds, sampleRate: rate))
        wetMix = LinearRamp(
            value: bypass ? 0 : 1,
            rampFrames: LinearRamp.frames(seconds: configuration.bypassCrossfadeSeconds, sampleRate: rate))

        let chunk = max(16, configuration.chunkFrames)
        chunkFrames = chunk
        func scratch() -> UnsafeMutablePointer<Float> {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
            buffer.initialize(repeating: 0, count: chunk)
            return buffer
        }
        dryLeft = scratch()
        dryRight = scratch()
        wetLeft = scratch()
        wetRight = scratch()
        processor = DSPProcessor(sampleRate: rate)
    }

    deinit {
        outputBufferChannels.deallocate()
        outputLocations.deallocate()
        dryLeft.deallocate()
        dryRight.deallocate()
        wetLeft.deallocate()
        wetRight.deallocate()
    }
}

/// A snapshot of the meters, read (and the peaks reset) by the UI.
public struct MeterSnapshot: Sendable, Equatable {
    /// Peak linear amplitude since the previous snapshot.
    public var inputPeakLeft: Float
    public var inputPeakRight: Float
    public var outputPeakLeft: Float
    public var outputPeakRight: Float
    /// Cumulative counters since the engine started.
    public var clippedSamples: UInt64
    public var nonFiniteSamples: UInt64
    public var invalidInputCycles: UInt64
    public var invalidOutputCycles: UInt64
    public var renderedCycles: UInt64
    public var overloads: UInt64

    /// Cycles silenced because of an input or output layout problem.
    public var invalidCycles: UInt64 { invalidInputCycles &+ invalidOutputCycles }

    public static let silent = MeterSnapshot(
        inputPeakLeft: 0, inputPeakRight: 0, outputPeakLeft: 0, outputPeakRight: 0,
        clippedSamples: 0, nonFiniteSamples: 0, invalidInputCycles: 0, invalidOutputCycles: 0,
        renderedCycles: 0, overloads: 0)

    public init(
        inputPeakLeft: Float, inputPeakRight: Float, outputPeakLeft: Float, outputPeakRight: Float,
        clippedSamples: UInt64, nonFiniteSamples: UInt64, invalidInputCycles: UInt64,
        invalidOutputCycles: UInt64, renderedCycles: UInt64, overloads: UInt64
    ) {
        self.inputPeakLeft = inputPeakLeft
        self.inputPeakRight = inputPeakRight
        self.outputPeakLeft = outputPeakLeft
        self.outputPeakRight = outputPeakRight
        self.clippedSamples = clippedSamples
        self.nonFiniteSamples = nonFiniteSamples
        self.invalidInputCycles = invalidInputCycles
        self.invalidOutputCycles = invalidOutputCycles
        self.renderedCycles = renderedCycles
        self.overloads = overloads
    }
}

/// Owns the memory of one `RenderState` and offers thread-safe accessors for
/// non-real-time code. The real-time callback receives `pointer` directly.
///
/// `@unchecked Sendable`: all shared fields behind `pointer` are atomics;
/// the RT-private fields are only touched by the render kernel.
public final class RenderStateHandle: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<RenderState>
    public let configuration: RenderConfiguration

    public init(configuration: RenderConfiguration, gain: Float, bypass: Bool, outputPair: OutputChannelPair) {
        self.configuration = configuration
        pointer = .allocate(capacity: 1)
        pointer.initialize(
            to: RenderState(configuration: configuration, gain: gain, bypass: bypass, outputPair: outputPair))
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    /// Number of output channels known to the render state.
    public var outputChannelCount: Int { configuration.outputLayout.channelCount }

    public func setGain(linear: Float) {
        pointer.pointee.targetGain.store(linear, ordering: .relaxed)
    }

    public func setBypass(_ enabled: Bool) {
        pointer.pointee.bypass.store(enabled, ordering: .relaxed)
    }

    /// Routes the tap to `pair`. Returns false (and changes nothing) if the
    /// device has no such channels.
    @discardableResult
    public func setOutputPair(_ pair: OutputChannelPair) -> Bool {
        guard pair.right < outputChannelCount else { return false }
        pointer.pointee.outputPair.store(pair.packed, ordering: .relaxed)
        return true
    }

    /// The output pair currently used by the render code.
    public var outputPair: OutputChannelPair {
        OutputChannelPair(left: OutputChannelPair.unpack(pointer.pointee.outputPair.load(ordering: .relaxed)).left)
    }

    /// Counts one device overload (same as the real-time listener does).
    public func recordOverload() {
        RenderKernel.recordOverload(state: pointer)
    }

    /// Reads the meters and resets the peak values.
    public func readMeters() -> MeterSnapshot {
        let state = pointer
        func takePeak(_ atomic: borrowing Atomic<UInt32>) -> Float {
            Float(bitPattern: atomic.exchange(0, ordering: .relaxed))
        }
        return MeterSnapshot(
            inputPeakLeft: takePeak(state.pointee.inputPeakLeftBits),
            inputPeakRight: takePeak(state.pointee.inputPeakRightBits),
            outputPeakLeft: takePeak(state.pointee.outputPeakLeftBits),
            outputPeakRight: takePeak(state.pointee.outputPeakRightBits),
            clippedSamples: state.pointee.clippedSamples.load(ordering: .relaxed),
            nonFiniteSamples: state.pointee.nonFiniteSamples.load(ordering: .relaxed),
            invalidInputCycles: state.pointee.invalidInputCycles.load(ordering: .relaxed),
            invalidOutputCycles: state.pointee.invalidOutputCycles.load(ordering: .relaxed),
            renderedCycles: state.pointee.renderedCycles.load(ordering: .relaxed),
            overloads: state.pointee.overloads.load(ordering: .relaxed)
        )
    }
}
