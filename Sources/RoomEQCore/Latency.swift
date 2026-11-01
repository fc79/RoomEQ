// Latency estimate of the split engine (pure arithmetic, unit-tested).
//
// The audio travels: app -> device tap -> capture IOProc -> ring buffer ->
// output IOProc -> output device -> speakers.
//
// Decision (documented): the read delay is measured on the tap's sample
// timeline against the output's sample timeline (both the device's clock).
// A tap sample stamped t is played at output sample time t + delay, so the
// delay is exactly the time RoomEQ adds, and it ALREADY contains the
// capture safety offset, both IO buffers and the output safety offset —
// those are reported for information but never added again. On top of the
// delay we add what Core Audio declares outside the two timelines:
//   - the tap path's own latency (sub-tap extra latency + tap stream
//     latency; both 0 on the devices measured so far),
//   - the output device latency and output stream latency (converters,
//     Apple's speaker DSP...), which apply after our output.
// It is an ESTIMATE: the tapped apps' own buffering is unknown.

import Foundation

/// Raw latency contributions in frames, as reported by Core Audio.
public struct LatencyComponents: Sendable, Equatable {
    /// Read delay (output sample time - tap sample time of the same audio).
    public var delayFrames: Int
    /// `kAudioSubTapPropertyExtraLatency` of the capture aggregate's sub-tap.
    public var tapExtraFrames: Int
    /// `kAudioStreamPropertyLatency` of the tap stream.
    public var tapStreamFrames: Int
    /// `kAudioDevicePropertyLatency`, output scope, of the output device.
    public var outputDeviceFrames: Int
    /// `kAudioStreamPropertyLatency` of the output stream we write to.
    public var outputStreamFrames: Int

    // Informational only: contained in `delayFrames`, never added.
    public var bufferFrames: Int
    public var captureSafetyOffsetFrames: Int
    public var outputSafetyOffsetFrames: Int

    public init(
        delayFrames: Int = 0, tapExtraFrames: Int = 0, tapStreamFrames: Int = 0, outputDeviceFrames: Int = 0,
        outputStreamFrames: Int = 0, bufferFrames: Int = 0, captureSafetyOffsetFrames: Int = 0,
        outputSafetyOffsetFrames: Int = 0
    ) {
        self.delayFrames = delayFrames
        self.tapExtraFrames = tapExtraFrames
        self.tapStreamFrames = tapStreamFrames
        self.outputDeviceFrames = outputDeviceFrames
        self.outputStreamFrames = outputStreamFrames
        self.bufferFrames = bufferFrames
        self.captureSafetyOffsetFrames = captureSafetyOffsetFrames
        self.outputSafetyOffsetFrames = outputSafetyOffsetFrames
    }
}

/// Latency in frames and milliseconds at a given sample rate.
public struct LatencyBreakdown: Sendable, Equatable {
    public let components: LatencyComponents
    public let sampleRate: Double

    public init(components: LatencyComponents, sampleRate: Double) {
        self.components = components
        self.sampleRate = sampleRate
    }

    /// What RoomEQ adds: delay + the tap path's declared latency (>= 0).
    public var roomEQFrames: Int {
        max(0, components.delayFrames) + max(0, components.tapExtraFrames) + max(0, components.tapStreamFrames)
    }

    /// After our output: device + stream latency (>= 0).
    public var outputFrames: Int { max(0, components.outputDeviceFrames) + max(0, components.outputStreamFrames) }

    public var totalFrames: Int { roomEQFrames + outputFrames }

    /// Converts frames to milliseconds at `sampleRate` (0 if the rate is unknown).
    public func milliseconds(_ frames: Int) -> Double {
        AudioFormatText.isKnownRate(sampleRate) ? Double(frames) * 1000 / sampleRate : 0
    }

    public var roomEQMilliseconds: Double { milliseconds(roomEQFrames) }
    public var outputMilliseconds: Double { milliseconds(outputFrames) }
    public var totalMilliseconds: Double { milliseconds(totalFrames) }

    /// One-line (localized) summary for the UI, e.g.
    /// "Stima 5,7 ms (RoomEQ 5,0 + uscita 0,7) a 44,1 kHz"; "—" when the
    /// sample rate is unknown (no milliseconds can be computed).
    public var summary: String {
        guard AudioFormatText.isKnownRate(sampleRate) else { return "—" }
        let number: (Double) -> String = AudioFormatText.oneDecimal
        let total = number(totalMilliseconds), roomEQ = number(roomEQMilliseconds)
        let output = number(outputMilliseconds), rate = AudioFormatText.kilohertz(sampleRate)
        return String(localized: "Stima \(total) ms (RoomEQ \(roomEQ) + uscita \(output)) a \(rate)")
    }

    /// Detailed breakdown in frames, for logs and diagnostics.
    public var detail: String {
        let c = components
        return "delay \(c.delayFrames) (contains safety in \(c.captureSafetyOffsetFrames) + 2x buffer \(c.bufferFrames) "
            + "+ safety out \(c.outputSafetyOffsetFrames) + ring), tap extra \(c.tapExtraFrames) + tap stream "
            + "\(c.tapStreamFrames), output device \(c.outputDeviceFrames) + stream \(c.outputStreamFrames) "
            + "= \(totalFrames) frames"
    }
}
