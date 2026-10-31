// The real-time render function, called once per IO cycle by Core Audio.
//
// REAL-TIME RULES (this whole file runs on the HAL IO thread):
//   no allocation, no locks, no logging/print, no file I/O, no Swift arrays,
//   no class references, no Objective-C. Only pointers, atomics and math.
//
// What one cycle does:
//   1. silence every output buffer (all channels we don't write stay at 0);
//   2. check the output (and, for `render`, input) buffer lists match the
//      layout recorded at start (else stay silent and count an invalid cycle);
//   3. for each chunk: copy the tap's L/R into the dry scratch buffers
//      (input peak); take a new EQ filter set from the mailbox if one is
//      waiting (the bands start ramping to it); run the EQ (DSPProcessor)
//      from dry into wet; crossfade dry/wet (bypass = EQ off), apply the
//      preamp (fixed-time ramp, never above unity), replace NaN/Inf with
//      silence, count clipping, measure the output peak, clamp to [-1, 1]
//      and write L/R into the selected output channel pair;
//   4. publish meters with atomics.

import CoreAudio
import Darwin
import Synchronization

public enum RenderKernel {
    /// Renders one IO cycle reading the tap directly from `input` (input
    /// and output in the same IO cycle). The split engine uses
    /// `renderFromSource` instead; this entry point remains for the unit
    /// tests of the processing chain.
    public static func render(
        state: UnsafeMutablePointer<RenderState>,
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) {
        guard let destination = prepareOutput(state: state, output: output) else { return }

        // Validate the input (tap) buffers.
        let buffersOffset = state.pointee.audioBuffersOffset
        guard let input,
            let tapL = sourceSamples(UnsafeRawPointer(input), buffersOffset, state.pointee.tapLeft,
                                     expectedBuffers: state.pointee.inputBufferCount),
            let tapR = sourceSamples(UnsafeRawPointer(input), buffersOffset, state.pointee.tapRight,
                                     expectedBuffers: state.pointee.inputBufferCount)
        else {
            state.pointee.invalidInputCycles.wrappingAdd(1, ordering: .relaxed)
            return
        }
        // Two-argument min only: the variadic min(a, b, c, ...) builds an
        // array (runtime calls on the real-time thread).
        let frames = min(destination.frames, min(tapL.frames, tapR.frames))
        process(
            state: state, sourceLeft: UnsafePointer(tapL.samples), leftStride: tapL.stride,
            sourceRight: UnsafePointer(tapR.samples), rightStride: tapR.stride, frames: frames,
            outL: destination.left, outR: destination.right)
    }

    /// Renders one IO cycle from contiguous (de-interleaved) source samples,
    /// e.g. read from the capture ring buffer. `frames` source frames.
    public static func renderFromSource(
        state: UnsafeMutablePointer<RenderState>,
        sourceLeft: UnsafePointer<Float>,
        sourceRight: UnsafePointer<Float>,
        frames: Int,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) {
        guard let destination = prepareOutput(state: state, output: output) else { return }
        process(
            state: state, sourceLeft: sourceLeft, leftStride: 1, sourceRight: sourceRight, rightStride: 1,
            frames: min(destination.frames, frames), outL: destination.left, outR: destination.right)
    }

    /// Frames requested by an output buffer list (0 if none/invalid).
    @inline(__always)
    public static func outputFrameCount(_ output: UnsafeMutablePointer<AudioBufferList>?, buffersOffset: Int) -> Int {
        guard let output else { return 0 }
        let list = UnsafeMutableRawPointer(output)
        var frames = Int.max
        for index in 0..<Int(list.load(as: UInt32.self)) {
            let buffer = audioBuffer(list, buffersOffset, index)
            let channels = Int(buffer.pointee.mNumberChannels)
            if channels > 0 {
                frames = min(frames, Int(buffer.pointee.mDataByteSize) / (channels * floatSize))
            }
        }
        return frames == Int.max ? 0 : frames
    }

    /// Zeroes every buffer of `output`.
    @inline(__always)
    public static func silence(_ output: UnsafeMutablePointer<AudioBufferList>?, buffersOffset: Int) {
        guard let output else { return }
        let list = UnsafeMutableRawPointer(output)
        for index in 0..<Int(list.load(as: UInt32.self)) {
            let buffer = audioBuffer(list, buffersOffset, index)
            if let data = buffer.pointee.mData { memset(data, 0, Int(buffer.pointee.mDataByteSize)) }
        }
    }

    /// Steps 1-2 of a cycle: count it, silence all outputs, validate the
    /// output against the layout recorded at start and locate the selected
    /// pair. Nil (and an invalid-output count) if the layout doesn't match.
    @inline(__always)
    static func prepareOutput(
        state: UnsafeMutablePointer<RenderState>, output: UnsafeMutablePointer<AudioBufferList>?
    ) -> (left: ChannelSamples, right: ChannelSamples, frames: Int)? {
        state.pointee.renderedCycles.wrappingAdd(1, ordering: .relaxed)
        guard let output else {
            state.pointee.invalidOutputCycles.wrappingAdd(1, ordering: .relaxed)
            return nil
        }
        let buffersOffset = state.pointee.audioBuffersOffset
        let outList = UnsafeMutableRawPointer(output)
        let outBufferCount = Int(outList.load(as: UInt32.self))
        silence(output, buffersOffset: buffersOffset)
        let outputFrames = outputFrameCount(output, buffersOffset: buffersOffset)

        // The output pair may change at any time from the main thread.
        let pair = OutputChannelPair.unpack(state.pointee.outputPair.load(ordering: .relaxed))
        guard outputFrames > 0,
            outBufferCount == state.pointee.outputBufferCount,
            pair.left < state.pointee.outputChannelCount,
            pair.right < state.pointee.outputChannelCount,
            let outL = destinationSamples(outList, buffersOffset, state.pointee.outputLocations[pair.left],
                                          expectedChannels: state.pointee.outputBufferChannels),
            let outR = destinationSamples(outList, buffersOffset, state.pointee.outputLocations[pair.right],
                                          expectedChannels: state.pointee.outputBufferChannels)
        else {
            state.pointee.invalidOutputCycles.wrappingAdd(1, ordering: .relaxed)
            return nil
        }
        return (outL, outR, min(outputFrames, min(outL.frames, outR.frames)))
    }

    /// Step 3-4: for each chunk, copy the source into the dry scratch
    /// buffers (input peak), pick up a new filter set, run the EQ from dry
    /// into wet, crossfade dry/wet (bypass), apply the preamp (fixed-time
    /// ramp), replace NaN/Inf with silence, count clipping, measure the
    /// output peak, clamp to [-1, 1] and write L/R; then publish the meters.
    @inline(__always)
    static func process(
        state: UnsafeMutablePointer<RenderState>,
        sourceLeft: UnsafePointer<Float>, leftStride: Int,
        sourceRight: UnsafePointer<Float>, rightStride: Int,
        frames: Int, outL: ChannelSamples, outR: ChannelSamples
    ) {
        let dryL = state.pointee.dryLeft, dryR = state.pointee.dryRight
        let wetL = state.pointee.wetLeft, wetR = state.pointee.wetRight
        let chunk = state.pointee.chunkFrames

        // Ramps: local copies for the loop, written back at the end, so the
        // ramp continues seamlessly into the next IO cycle.
        var gainRamp = state.pointee.gainRamp
        var wetMix = state.pointee.wetMix
        gainRamp.setTarget(state.pointee.targetGain.load(ordering: .relaxed))
        wetMix.setTarget(state.pointee.bypass.load(ordering: .relaxed) ? 0 : 1)

        var inPeakL: Float = 0, inPeakR: Float = 0, outPeakL: Float = 0, outPeakR: Float = 0
        var clipped: UInt64 = 0
        var inputOvers: UInt64 = 0
        var processingOvers: UInt64 = 0
        var processingOverPeak: Float = 0
        var nonFinite: UInt64 = 0

        var done = 0
        while done < frames {
            let count = min(chunk, frames - done)

            for frame in 0..<count {
                let left = sourceLeft[(done + frame) * leftStride]
                let right = sourceRight[(done + frame) * rightStride]
                dryL[frame] = left
                dryR[frame] = right
                let absL = left.magnitude, absR = right.magnitude
                if absL > inPeakL { inPeakL = absL }
                if absR > inPeakR { inPeakR = absR }
                // The source itself over full scale.
                if absL > 1 { inputOvers &+= 1 }
                if absR > 1 { inputOvers &+= 1 }
            }

            // The EQ always runs (keeps its state warm while bypassed).
            // A new filter set is taken as soon as it is published; the
            // bands ramp to it from wherever they are.
            acceptPublishedFilters(state)
            state.pointee.processor.process(
                inputLeft: UnsafePointer(dryL), inputRight: UnsafePointer(dryR), outputLeft: wetL, outputRight: wetR,
                frameCount: count)

            for frame in 0..<count {
                let mix = wetMix.next()
                let gain = gainRamp.next()
                var left = (dryL[frame] + mix * (wetL[frame] - dryL[frame])) * gain
                var right = (dryR[frame] + mix * (wetR[frame] - dryR[frame])) * gain
                if !left.isFinite { left = 0; nonFinite &+= 1 }
                if !right.isFinite { right = 0; nonFinite &+= 1 }
                let absL = left.magnitude, absR = right.magnitude
                if absL > outPeakL { outPeakL = absL }
                if absR > outPeakR { outPeakR = absR }
                // Count, then clamp: never send more than full scale. An over
                // whose input sample was within full scale was caused by the
                // processing (EQ); the preamp never boosts.
                if absL > 1 {
                    clipped &+= 1
                    if dryL[frame].magnitude <= 1 {
                        processingOvers &+= 1
                        if absL > processingOverPeak { processingOverPeak = absL }
                    }
                    left = left > 0 ? 1 : -1
                }
                if absR > 1 {
                    clipped &+= 1
                    if dryR[frame].magnitude <= 1 {
                        processingOvers &+= 1
                        if absR > processingOverPeak { processingOverPeak = absR }
                    }
                    right = right > 0 ? 1 : -1
                }
                outL.samples[(done + frame) * outL.stride] = left
                outR.samples[(done + frame) * outR.stride] = right
            }
            done += count
        }
        state.pointee.gainRamp = gainRamp
        state.pointee.wetMix = wetMix

        state.pointee.inputPeakLeftBits.max(inPeakL.bitPattern, ordering: .relaxed)
        state.pointee.inputPeakRightBits.max(inPeakR.bitPattern, ordering: .relaxed)
        state.pointee.outputPeakLeftBits.max(outPeakL.bitPattern, ordering: .relaxed)
        state.pointee.outputPeakRightBits.max(outPeakR.bitPattern, ordering: .relaxed)
        state.pointee.diagnosticInputPeakBits.max(max(inPeakL, inPeakR).bitPattern, ordering: .relaxed)
        state.pointee.diagnosticOutputPeakBits.max(max(outPeakL, outPeakR).bitPattern, ordering: .relaxed)
        if clipped > 0 { state.pointee.clippedSamples.wrappingAdd(clipped, ordering: .relaxed) }
        if inputOvers > 0 { state.pointee.inputOverSamples.wrappingAdd(inputOvers, ordering: .relaxed) }
        if processingOvers > 0 {
            state.pointee.processingOverSamples.wrappingAdd(processingOvers, ordering: .relaxed)
            state.pointee.maxProcessingOverLevelBits.max(processingOverPeak.bitPattern, ordering: .relaxed)
        }
        // Max levels for the clip indicator (separate from the meter peaks,
        // which the UI resets 25 times per second).
        state.pointee.maxInputLevelBits.max(max(inPeakL, inPeakR).bitPattern, ordering: .relaxed)
        state.pointee.maxOutputLevelBits.max(max(outPeakL, outPeakR).bitPattern, ordering: .relaxed)
        if nonFinite > 0 { state.pointee.nonFiniteSamples.wrappingAdd(nonFinite, ordering: .relaxed) }
    }

    /// If the main thread published a filter set the RT thread hasn't taken
    /// yet, swaps it in (triple buffer, see RenderState.swift) and makes it
    /// the processor's new target.
    @inline(__always)
    static func acceptPublishedFilters(_ state: UnsafeMutablePointer<RenderState>) {
        guard state.pointee.filterMailbox.load(ordering: .relaxed) & FilterMailbox.dirtyFlag != 0 else { return }
        // Acquire: everything the writer stored in the slot is visible.
        let previous = state.pointee.filterMailbox.exchange(
            state.pointee.filterReadSlot, ordering: .acquiringAndReleasing)
        let slot = previous & FilterMailbox.slotMask
        state.pointee.filterReadSlot = slot
        state.pointee.processor.apply(
            UnsafePointer(state.pointee.filterSlots + slot * DSPProcessor.maximumSections),
            count: state.pointee.filterSlotCounts[slot])
    }

    /// Counts one device overload. Real-time safe (one atomic increment);
    /// called from the overload listener, which Core Audio invokes on the
    /// IO thread.
    @inline(__always)
    public static func recordOverload(state: UnsafeMutablePointer<RenderState>) {
        state.pointee.overloads.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Helpers (all real-time safe)

    /// Bytes per sample (Float32). Computed property, not a stored static,
    /// so there is no lazy global initialisation on the real-time thread.
    @inline(__always) static var floatSize: Int { MemoryLayout<Float>.size }

    /// Samples of one channel: base pointer already offset to the channel,
    /// distance between consecutive samples, and number of frames.
    struct ChannelSamples {
        let samples: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    @inline(__always)
    static func audioBuffer(_ list: UnsafeMutableRawPointer, _ buffersOffset: Int, _ index: Int)
        -> UnsafeMutablePointer<AudioBuffer>
    {
        (list + buffersOffset + index * MemoryLayout<AudioBuffer>.stride).assumingMemoryBound(to: AudioBuffer.self)
    }

    /// Locates an input channel, checking the list has the expected number of
    /// buffers and the buffer has the expected channel count and data.
    @inline(__always)
    static func sourceSamples(
        _ list: UnsafeRawPointer, _ buffersOffset: Int, _ location: ChannelLocation, expectedBuffers: Int
    ) -> ChannelSamples? {
        let bufferCount = Int(list.load(as: UInt32.self))
        guard bufferCount == expectedBuffers, location.buffer < bufferCount else { return nil }
        let buffer = audioBuffer(UnsafeMutableRawPointer(mutating: list), buffersOffset, location.buffer)
        return channelSamples(buffer, location)
    }

    /// Locates an output channel, checking the buffer still has the channel
    /// count recorded when the engine started.
    @inline(__always)
    static func destinationSamples(
        _ list: UnsafeMutableRawPointer, _ buffersOffset: Int, _ location: ChannelLocation,
        expectedChannels: UnsafeMutablePointer<Int>
    ) -> ChannelSamples? {
        guard expectedChannels[location.buffer] == location.stride else { return nil }
        return channelSamples(audioBuffer(list, buffersOffset, location.buffer), location)
    }

    @inline(__always)
    static func channelSamples(_ buffer: UnsafeMutablePointer<AudioBuffer>, _ location: ChannelLocation)
        -> ChannelSamples?
    {
        let channels = Int(buffer.pointee.mNumberChannels)
        guard channels == location.stride, location.offset < channels, let data = buffer.pointee.mData else {
            return nil
        }
        let frames = Int(buffer.pointee.mDataByteSize) / (channels * floatSize)
        guard frames > 0 else { return nil }
        let base = data.assumingMemoryBound(to: Float.self) + location.offset
        return ChannelSamples(samples: base, stride: channels, frames: frames)
    }
}
