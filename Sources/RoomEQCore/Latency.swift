// Round-trip latency estimate of the passthrough path.
//
// The audio travels: tapped app -> tap -> aggregate input -> our IO callback
// -> aggregate output -> output device -> speakers. Core Audio reports each
// contribution in frames; this file only does the arithmetic so it can be
// unit-tested without hardware.

import Foundation

/// Raw latency contributions in frames, as reported by Core Audio.
public struct LatencyComponents: Sendable, Equatable {
    /// `kAudioDevicePropertyLatency`, input scope, of the aggregate device.
    public var inputDeviceFrames: Int
    /// `kAudioDevicePropertySafetyOffset`, input scope.
    public var inputSafetyOffsetFrames: Int
    /// `kAudioStreamPropertyLatency` of the tap's input stream.
    public var inputStreamFrames: Int
    /// `kAudioDevicePropertyBufferFrameSize` (one IO buffer).
    public var bufferFrames: Int
    /// `kAudioDevicePropertyLatency`, output scope.
    public var outputDeviceFrames: Int
    /// `kAudioDevicePropertySafetyOffset`, output scope.
    public var outputSafetyOffsetFrames: Int
    /// `kAudioStreamPropertyLatency` of the output stream we write to.
    public var outputStreamFrames: Int

    public init(
        inputDeviceFrames: Int = 0,
        inputSafetyOffsetFrames: Int = 0,
        inputStreamFrames: Int = 0,
        bufferFrames: Int = 0,
        outputDeviceFrames: Int = 0,
        outputSafetyOffsetFrames: Int = 0,
        outputStreamFrames: Int = 0
    ) {
        self.inputDeviceFrames = inputDeviceFrames
        self.inputSafetyOffsetFrames = inputSafetyOffsetFrames
        self.inputStreamFrames = inputStreamFrames
        self.bufferFrames = bufferFrames
        self.outputDeviceFrames = outputDeviceFrames
        self.outputSafetyOffsetFrames = outputSafetyOffsetFrames
        self.outputStreamFrames = outputStreamFrames
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

    /// Input side: device latency + safety offset + stream latency.
    public var inputFrames: Int {
        components.inputDeviceFrames + components.inputSafetyOffsetFrames + components.inputStreamFrames
    }

    /// Buffering: one buffer to receive the input, one to deliver the output.
    public var bufferingFrames: Int { 2 * components.bufferFrames }

    /// Output side: device latency + safety offset + stream latency.
    public var outputFrames: Int {
        components.outputDeviceFrames + components.outputSafetyOffsetFrames + components.outputStreamFrames
    }

    public var totalFrames: Int { inputFrames + bufferingFrames + outputFrames }

    /// Converts frames to milliseconds at `sampleRate` (0 if the rate is unknown).
    public func milliseconds(_ frames: Int) -> Double {
        sampleRate > 0 ? Double(frames) * 1000 / sampleRate : 0
    }

    public var inputMilliseconds: Double { milliseconds(inputFrames) }
    public var bufferingMilliseconds: Double { milliseconds(bufferingFrames) }
    public var outputMilliseconds: Double { milliseconds(outputFrames) }
    public var totalMilliseconds: Double { milliseconds(totalFrames) }

    /// One-line Italian summary for the UI, e.g.
    /// "12.3 ms (ingresso 1.2 + buffer 5.8 + uscita 5.3) a 44100 Hz".
    public var summary: String {
        String(
            format: "%.1f ms (ingresso %.1f + buffer %.1f + uscita %.1f) a %.0f Hz",
            totalMilliseconds, inputMilliseconds, bufferingMilliseconds, outputMilliseconds, sampleRate
        )
    }

    /// Detailed breakdown in frames, for logs and diagnostics.
    public var detail: String {
        let c = components
        return "input \(c.inputDeviceFrames)+\(c.inputSafetyOffsetFrames)+\(c.inputStreamFrames) "
            + "(device+safety+stream), buffer 2x\(c.bufferFrames), "
            + "output \(c.outputDeviceFrames)+\(c.outputSafetyOffsetFrames)+\(c.outputStreamFrames) "
            + "(device+safety+stream) = \(totalFrames) frames"
    }
}
