// The real-time render function, called once per IO cycle by Core Audio.
//
// REAL-TIME RULES (this whole file runs on the HAL IO thread):
//   no allocation, no locks, no logging/print, no file I/O, no Swift arrays,
//   no class references, no Objective-C. Only pointers, atomics and math.
//
// What one cycle does:
//   1. silence every output buffer (all channels we don't write stay at 0);
//   2. check the output and input buffer lists match the layout recorded at
//      start (else stay silent and count an invalid cycle);
//   3. for each chunk: copy the tap's L/R into the dry and wet scratch
//      buffers (input peak), run the DSP chain on the wet copy, crossfade
//      dry/wet (bypass), apply the gain (fixed-time ramp), replace NaN/Inf
//      with silence, count clipping, measure the output peak, clamp to
//      [-1, 1] and write L/R into the selected output channel pair;
//   4. publish meters with atomics.

import CoreAudio
import Darwin
import Synchronization

public enum RenderKernel {
    /// Renders one IO cycle. `input` / `output` are the buffer lists Core
    /// Audio passes to the IOProc (treated as possibly NULL).
    public static func render(
        state: UnsafeMutablePointer<RenderState>,
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) {
        state.pointee.renderedCycles.wrappingAdd(1, ordering: .relaxed)
        guard let output else {
            state.pointee.invalidOutputCycles.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let buffersOffset = state.pointee.audioBuffersOffset
        let outList = UnsafeMutableRawPointer(output)

        // 1. Silence all outputs; find how many frames the output expects.
        let outBufferCount = Int(outList.load(as: UInt32.self))
        var outputFrames = Int.max
        for index in 0..<outBufferCount {
            let buffer = audioBuffer(outList, buffersOffset, index)
            if let data = buffer.pointee.mData {
                memset(data, 0, Int(buffer.pointee.mDataByteSize))
            }
            let channels = Int(buffer.pointee.mNumberChannels)
            if channels > 0 {
                outputFrames = min(outputFrames, Int(buffer.pointee.mDataByteSize) / (channels * floatSize))
            }
        }

        // 2a. Validate the output against the layout recorded at start.
        // The output pair may change at any time from the main thread.
        let pair = OutputChannelPair.unpack(state.pointee.outputPair.load(ordering: .relaxed))
        guard outputFrames != Int.max, outputFrames > 0,
            outBufferCount == state.pointee.outputBufferCount,
            pair.left < state.pointee.outputChannelCount,
            pair.right < state.pointee.outputChannelCount,
            let outL = destinationSamples(outList, buffersOffset, state.pointee.outputLocations[pair.left],
                                          expectedChannels: state.pointee.outputBufferChannels),
            let outR = destinationSamples(outList, buffersOffset, state.pointee.outputLocations[pair.right],
                                          expectedChannels: state.pointee.outputBufferChannels)
        else {
            state.pointee.invalidOutputCycles.wrappingAdd(1, ordering: .relaxed)
            return
        }

        // 2b. Validate the input (tap) buffers.
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
        let frames = min(min(outputFrames, min(tapL.frames, tapR.frames)), min(outL.frames, outR.frames))
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
        var nonFinite: UInt64 = 0

        // 3. Process in chunks.
        var done = 0
        while done < frames {
            let count = min(chunk, frames - done)

            // De-interleave the tap into the dry and wet scratch buffers.
            for frame in 0..<count {
                let left = tapL.samples[(done + frame) * tapL.stride]
                let right = tapR.samples[(done + frame) * tapR.stride]
                dryL[frame] = left
                dryR[frame] = right
                wetL[frame] = left
                wetR[frame] = right
                let absL = left.magnitude, absR = right.magnitude
                if absL > inPeakL { inPeakL = absL }
                if absR > inPeakR { inPeakR = absR }
            }

            // The DSP chain always runs (keeps its state warm while bypassed).
            state.pointee.processor.process(left: wetL, right: wetR, frameCount: count)

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
                // Count, then clamp: never send more than full scale.
                if absL > 1 { clipped &+= 1; left = left > 0 ? 1 : -1 }
                if absR > 1 { clipped &+= 1; right = right > 0 ? 1 : -1 }
                outL.samples[(done + frame) * outL.stride] = left
                outR.samples[(done + frame) * outR.stride] = right
            }
            done += count
        }
        state.pointee.gainRamp = gainRamp
        state.pointee.wetMix = wetMix

        // 4. Publish meters.
        state.pointee.inputPeakLeftBits.max(inPeakL.bitPattern, ordering: .relaxed)
        state.pointee.inputPeakRightBits.max(inPeakR.bitPattern, ordering: .relaxed)
        state.pointee.outputPeakLeftBits.max(outPeakL.bitPattern, ordering: .relaxed)
        state.pointee.outputPeakRightBits.max(outPeakR.bitPattern, ordering: .relaxed)
        if clipped > 0 { state.pointee.clippedSamples.wrappingAdd(clipped, ordering: .relaxed) }
        if nonFinite > 0 { state.pointee.nonFiniteSamples.wrappingAdd(nonFinite, ordering: .relaxed) }
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
