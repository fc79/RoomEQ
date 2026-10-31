// State shared between the real-time audio thread and the rest of the app.
//
// Threading contract
// ------------------
// * `RenderState` lives in manually allocated memory (see `RenderStateHandle`)
//   so its address never changes and the real-time thread can reach it
//   through a plain pointer: no reference counting, no locks.
// * "Control" values (preamp gain, bypass, output pair) are written by the
//   main thread and read by the real-time thread through atomics.
// * EQ filter sets are handed over through a lock-free triple buffer
//   (`filterMailbox` + three preallocated slots): the writer (main thread,
//   serialised by a mutex in `RenderStateHandle`, never taken by the RT
//   thread) fills its private slot and atomically swaps it with the
//   "latest" slot; the RT thread swaps the latest slot with its own when the
//   dirty flag is set. The latest set always wins; none is ever torn.
// * "Meter" values are written by the real-time thread (and the overload
//   listener) and read by the main thread through atomics.
// * Layout tables are filled once in `init` and are read-only afterwards.
// * Fields marked "RT-private" are touched ONLY by the real-time thread.
// * The engine guarantees the IOProc and the overload listener are removed
//   before the `RenderStateHandle` that owns this memory is released.

import CoreAudio
import Synchronization

/// Triple-buffer bookkeeping for EQ filter sets (see the threading contract).
/// Computed properties returning literals: no lazily initialised globals
/// (swift_once) on the real-time thread.
enum FilterMailbox {
    /// Low bits: index (0...2) of the slot holding the latest set.
    @inline(__always) static var slotMask: Int { 0b11 }
    /// Set by the writer when the latest slot holds a set the RT thread has
    /// not taken yet.
    @inline(__always) static var dirtyFlag: Int { 0b100 }
    @inline(__always) static var slotCount: Int { 3 }
}

/// Everything needed to build a `RenderState` (computed on a normal thread).
public struct RenderConfiguration: Sendable {
    /// Buffer layout of the INPUT buffer list holding the tap (the capture
    /// aggregate's; used by `RenderKernel.render(input:)`).
    public var inputLayout: BufferListLayout
    /// Where the tap's left / right channels are in the input buffer list.
    /// For a mono tap both point at the same channel.
    public var tapLeft: ChannelLocation
    public var tapRight: ChannelLocation
    /// Buffer layout of the output device's OUTPUT buffer list.
    public var outputLayout: BufferListLayout
    /// Current device sample rate (Hz).
    public var sampleRate: Double
    /// Size of the internal processing chunk. IO buffers larger than this
    /// are processed in several chunks, so any IO size works.
    public var chunkFrames: Int
    /// Duration of a preamp change (seconds), independent of buffer size.
    public var gainRampSeconds: Double
    /// Duration of the bypass (EQ on/off) crossfade (seconds).
    public var bypassCrossfadeSeconds: Double
    /// Duration of an EQ parameter ramp (seconds), see DSPProcessor.swift.
    public var eqRampSeconds: Double

    public init(
        inputLayout: BufferListLayout,
        tapLeft: ChannelLocation,
        tapRight: ChannelLocation,
        outputLayout: BufferListLayout,
        sampleRate: Double,
        chunkFrames: Int = 1024,
        gainRampSeconds: Double = 0.015,
        bypassCrossfadeSeconds: Double = 0.010,
        eqRampSeconds: Double = 0.030
    ) {
        self.inputLayout = inputLayout
        self.tapLeft = tapLeft
        self.tapRight = tapRight
        self.outputLayout = outputLayout
        self.sampleRate = sampleRate
        self.chunkFrames = chunkFrames
        self.gainRampSeconds = gainRampSeconds
        self.bypassCrossfadeSeconds = bypassCrossfadeSeconds
        self.eqRampSeconds = eqRampSeconds
    }
}

/// Real-time render state. Non-copyable: exactly one instance exists per
/// running engine, at a fixed address.
public struct RenderState: ~Copyable {
    // MARK: Control (main thread -> real-time thread)

    /// Target linear gain (preamp, 0...1: never a boost). The real-time
    /// thread ramps towards it. Applied after the dry/wet mix, so it acts
    /// both with the EQ on and off.
    public let targetGain: Atomic<Float>
    /// When true (EQ off) the output crossfades to the unprocessed (dry)
    /// signal. The DSP chain keeps running so switching back is click-free.
    public let bypass: Atomic<Bool>
    /// Latest-slot index + dirty flag of the filter-set triple buffer.
    public let filterMailbox: Atomic<Int>
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
    /// Second set of peaks, read only by the engine's level diagnostics, so
    /// that diagnostics don't steal peaks from the UI meters.
    public let diagnosticInputPeakBits: Atomic<UInt32>
    public let diagnosticOutputPeakBits: Atomic<UInt32>
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

    // MARK: Filter-set slots (written by the writer only in its own slot)

    /// `FilterMailbox.slotCount` slots of `DSPProcessor.maximumSections`.
    let filterSlots: UnsafeMutablePointer<FilterSection>
    let filterSlotCounts: UnsafeMutablePointer<Int>

    // MARK: RT-private

    /// Preamp gain, ramped over a fixed time.
    var gainRamp: LinearRamp
    /// Wet (processed) share of the output: 1 = DSP on, 0 = bypassed.
    var wetMix: LinearRamp
    /// Scratch buffers (one chunk per channel), preallocated:
    /// dry = tap signal, wet = after the DSP chain (EQ).
    let dryLeft: UnsafeMutablePointer<Float>
    let dryRight: UnsafeMutablePointer<Float>
    let wetLeft: UnsafeMutablePointer<Float>
    let wetRight: UnsafeMutablePointer<Float>
    let chunkFrames: Int
    /// Slot the RT thread currently owns (filter-set triple buffer).
    var filterReadSlot: Int
    /// The DSP chain: the EQ filter banks.
    var processor: DSPProcessor

    /// `gain` is clamped to 0...1. `filters` is the initial EQ set (already
    /// computed for `configuration.sampleRate`); it is active immediately.
    public init(
        configuration: RenderConfiguration, gain: Float, bypass: Bool, outputPair: OutputChannelPair,
        filters: [FilterSection] = []
    ) {
        let gain = RenderStateHandle.clampGain(gain) ?? 1  // NaN: unity (the default preamp)
        targetGain = Atomic(gain)
        self.bypass = Atomic(bypass)
        self.outputPair = Atomic(outputPair.packed)
        // Slot 0: RT-owned, slot 1: latest (nothing new), slot 2: writer's.
        filterMailbox = Atomic(1)
        filterReadSlot = 0
        let slotCapacity = FilterMailbox.slotCount * DSPProcessor.maximumSections
        filterSlots = .allocate(capacity: slotCapacity)
        filterSlots.initialize(
            repeating: FilterSection(
                coefficients: .identity, bandIDHigh: 0, bandIDLow: 0, logFrequency: 0, gainDecibels: 0, logQ: 0),
            count: slotCapacity)
        filterSlotCounts = .allocate(capacity: FilterMailbox.slotCount)
        filterSlotCounts.initialize(repeating: 0, count: FilterMailbox.slotCount)

        inputPeakLeftBits = Atomic(0)
        inputPeakRightBits = Atomic(0)
        outputPeakLeftBits = Atomic(0)
        outputPeakRightBits = Atomic(0)
        diagnosticInputPeakBits = Atomic(0)
        diagnosticOutputPeakBits = Atomic(0)
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
        processor = DSPProcessor(
            sampleRate: rate, maximumFrames: chunk, rampSeconds: configuration.eqRampSeconds, sections: filters)
    }

    deinit {
        filterSlots.deallocate()
        filterSlotCounts.deallocate()
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

    /// Writer side of the filter-set triple buffer. Only non-RT code takes
    /// this mutex; it serialises writers (normally just the main thread).
    private struct FilterWriter {
        var slot: Int
        var lastPublished: [FilterSection]
    }
    private let filterWriter: Mutex<FilterWriter>

    public init(
        configuration: RenderConfiguration, gain: Float, bypass: Bool, outputPair: OutputChannelPair,
        filters: [FilterSection] = []
    ) {
        self.configuration = configuration
        pointer = .allocate(capacity: 1)
        pointer.initialize(
            to: RenderState(
                configuration: configuration, gain: gain, bypass: bypass, outputPair: outputPair, filters: filters))
        filterWriter = Mutex(FilterWriter(slot: 2, lastPublished: Array(filters.prefix(DSPProcessor.maximumSections))))
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    /// Number of output channels known to the render state.
    public var outputChannelCount: Int { configuration.outputLayout.channelCount }

    /// Linear preamp / fade gain, clamped to 0...1 (never a boost). Same
    /// rules as `Preamp.clamp`: NaN is ignored (the previous gain stays),
    /// +inf -> 1, -inf or negative -> 0.
    public func setGain(linear: Float) {
        guard let gain = Self.clampGain(linear) else { return }
        pointer.pointee.targetGain.store(gain, ordering: .relaxed)
    }

    /// Preamp in dB, clamped to `Preamp.range` (-24...0 dB); NaN is ignored.
    public func setPreamp(decibels: Double) {
        guard let gain = Preamp.linearGain(decibels: decibels) else { return }
        setGain(linear: gain)
    }

    /// The target gain currently set (linear).
    public var targetGain: Float { pointer.pointee.targetGain.load(ordering: .relaxed) }

    /// `true` = EQ off (dry signal), `false` = EQ on.
    public func setBypass(_ enabled: Bool) {
        pointer.pointee.bypass.store(enabled, ordering: .relaxed)
    }

    /// Hands a new EQ filter set (computed for `configuration.sampleRate`)
    /// to the real-time thread, which ramps every band to it. Lock-free
    /// for the RT thread; returns false if `sections` equals the set
    /// published last (nothing to do). At most `maximumSections` are used.
    @discardableResult
    public func publishFilters(_ sections: [FilterSection]) -> Bool {
        let sections = Array(sections.prefix(DSPProcessor.maximumSections))
        let state = pointer
        return filterWriter.withLock { writer in
            guard writer.lastPublished != sections else { return false }
            let base = writer.slot * DSPProcessor.maximumSections
            for (index, section) in sections.enumerated() { state.pointee.filterSlots[base + index] = section }
            state.pointee.filterSlotCounts[writer.slot] = sections.count
            // Release: the slot contents are visible before the new index.
            let previous = state.pointee.filterMailbox.exchange(
                writer.slot | FilterMailbox.dirtyFlag, ordering: .acquiringAndReleasing)
            writer.slot = previous & FilterMailbox.slotMask
            writer.lastPublished = sections
            return true
        }
    }

    /// nil for NaN; otherwise limited to 0...1 (infinities included).
    static func clampGain(_ linear: Float) -> Float? {
        guard !linear.isNaN else { return nil }
        return min(max(linear, 0), 1)
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

    /// Peak |sample| of the tap input and of the output (both channels)
    /// since the previous call, for level diagnostics. Independent of
    /// `readMeters()`.
    public func readDiagnosticPeaks() -> (input: Float, output: Float) {
        (
            Float(bitPattern: pointer.pointee.diagnosticInputPeakBits.exchange(0, ordering: .relaxed)),
            Float(bitPattern: pointer.pointee.diagnosticOutputPeakBits.exchange(0, ordering: .relaxed))
        )
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
