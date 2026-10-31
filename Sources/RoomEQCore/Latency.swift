// Round-trip latency estimate of the passthrough path.
//
// The audio travels: tapped app -> tap -> aggregate input -> our IO callback
// -> aggregate output -> output device -> speakers. Core Audio reports each
// contribution in frames; this file only does the arithmetic so it can be
// unit-tested without hardware.
//
// It is an ESTIMATE: the tapped apps' own buffering is unknown, and the
// tap path does not go through the output device's converters (ADC), so the
// aggregate's input-scope *device* latency (the hardware input's latency) is
// deliberately NOT counted; only what applies to the tap stream is.

import Foundation

/// Raw latency contributions in frames, as reported by Core Audio.
public struct LatencyComponents: Sendable, Equatable {
    /// `kAudioSubTapPropertyExtraLatency` of the aggregate's sub-tap.
    public var inputTapExtraFrames: Int
    /// `kAudioDevicePropertySafetyOffset`, input scope, of the aggregate
    /// (applies to every input stream of the aggregate, tap included).
    public var inputSafetyOffsetFrames: Int
    /// `kAudioStreamPropertyLatency` of the tap's input stream.
    public var inputStreamFrames: Int
    /// `kAudioDevicePropertyBufferFrameSize` (one IO buffer; the same size
    /// is used on the capture and the output side).
    public var bufferFrames: Int
    /// Split engine: time the audio waits in the ring buffer between the
    /// capture and the output callback (the chosen delay minus the safety
    /// offsets and buffers already counted). 0 for a single-device path.
    public var ringFrames: Int
    /// `kAudioDevicePropertyLatency`, output scope.
    public var outputDeviceFrames: Int
    /// `kAudioDevicePropertySafetyOffset`, output scope.
    public var outputSafetyOffsetFrames: Int
    /// `kAudioStreamPropertyLatency` of the output stream we write to.
    public var outputStreamFrames: Int

    public init(
        inputTapExtraFrames: Int = 0,
        inputSafetyOffsetFrames: Int = 0,
        inputStreamFrames: Int = 0,
        bufferFrames: Int = 0,
        ringFrames: Int = 0,
        outputDeviceFrames: Int = 0,
        outputSafetyOffsetFrames: Int = 0,
        outputStreamFrames: Int = 0
    ) {
        self.inputTapExtraFrames = inputTapExtraFrames
        self.inputSafetyOffsetFrames = inputSafetyOffsetFrames
        self.inputStreamFrames = inputStreamFrames
        self.bufferFrames = bufferFrames
        self.ringFrames = ringFrames
        self.outputDeviceFrames = outputDeviceFrames
        self.outputSafetyOffsetFrames = outputSafetyOffsetFrames
        self.outputStreamFrames = outputStreamFrames
    }
}

extension LatencyComponents {
    /// Components for the split engine. `delayFrames` is the read delay on
    /// the shared sample timeline (output sample time - capture sample time
    /// of the same audio); it already spans the capture safety offset, both
    /// buffers and the output safety offset, so the ring share is what is
    /// left of it. Total = tap extra + tap stream + delay + output device
    /// latency + output stream latency.
    public static func split(
        delayFrames: Int, tapExtraFrames: Int, tapStreamFrames: Int, captureSafetyOffsetFrames: Int,
        bufferFrames: Int, outputSafetyOffsetFrames: Int, outputDeviceFrames: Int, outputStreamFrames: Int
    ) -> LatencyComponents {
        LatencyComponents(
            inputTapExtraFrames: tapExtraFrames,
            inputSafetyOffsetFrames: captureSafetyOffsetFrames,
            inputStreamFrames: tapStreamFrames,
            bufferFrames: bufferFrames,
            ringFrames: delayFrames - captureSafetyOffsetFrames - 2 * bufferFrames - outputSafetyOffsetFrames,
            outputDeviceFrames: outputDeviceFrames,
            outputSafetyOffsetFrames: outputSafetyOffsetFrames,
            outputStreamFrames: outputStreamFrames)
    }
}

/// Latency grouped into input side, buffering and output side, in frames
/// and milliseconds at a given sample rate.
public struct LatencyBreakdown: Sendable, Equatable {
    public let components: LatencyComponents
    public let sampleRate: Double

    public init(components: LatencyComponents, sampleRate: Double) {
        self.components = components
        self.sampleRate = sampleRate
    }

    /// Input side (tap path): sub-tap extra latency + safety offset + tap stream latency.
    public var inputFrames: Int {
        components.inputTapExtraFrames + components.inputSafetyOffsetFrames + components.inputStreamFrames
    }

    /// Buffering: one buffer to receive the input, one to deliver the output.
    public var bufferingFrames: Int { 2 * components.bufferFrames }

    /// Output side: device latency + safety offset + stream latency.
    public var outputFrames: Int {
        components.outputDeviceFrames + components.outputSafetyOffsetFrames + components.outputStreamFrames
    }

    public var totalFrames: Int { inputFrames + bufferingFrames + components.ringFrames + outputFrames }

    /// Converts frames to milliseconds at `sampleRate` (0 if the rate is unknown).
    public func milliseconds(_ frames: Int) -> Double {
        sampleRate > 0 ? Double(frames) * 1000 / sampleRate : 0
    }

    public var inputMilliseconds: Double { milliseconds(inputFrames) }
    public var bufferingMilliseconds: Double { milliseconds(bufferingFrames) }
    public var outputMilliseconds: Double { milliseconds(outputFrames) }
    public var ringMilliseconds: Double { milliseconds(components.ringFrames) }
    public var totalMilliseconds: Double { milliseconds(totalFrames) }

    /// One-line Italian summary for the UI, e.g.
    /// "Stima 12.3 ms (ingresso 1.2 + buffer 5.8 + uscita 5.3) a 44100 Hz".
    public var summary: String {
        String(
            format: "Stima %.1f ms (ingresso %.1f + buffer %.1f + anello %.1f + uscita %.1f) a %.0f Hz",
            totalMilliseconds, inputMilliseconds, bufferingMilliseconds, ringMilliseconds, outputMilliseconds,
            sampleRate
        )
    }

    /// Detailed breakdown in frames, for logs and diagnostics.
    public var detail: String {
        let c = components
        return "input \(c.inputTapExtraFrames)+\(c.inputSafetyOffsetFrames)+\(c.inputStreamFrames) "
            + "(tap extra+safety+tap stream), buffer 2x\(c.bufferFrames), ring \(c.ringFrames), "
            + "output \(c.outputDeviceFrames)+\(c.outputSafetyOffsetFrames)+\(c.outputStreamFrames) "
            + "(device+safety+stream) = \(totalFrames) frames"
    }
}
