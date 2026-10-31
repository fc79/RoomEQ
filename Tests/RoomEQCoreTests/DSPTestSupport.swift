import CoreAudio
import Foundation
@testable import RoomEQCore

/// Helpers to drive the real-time EQ code (DSPProcessor and the full render
/// kernel) from the tests.
enum DSPTest {
    static let stereoLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 2, isInterleaved: true)])

    static func sine(frequency: Double, sampleRate: Double, amplitude: Double = 0.5, count: Int) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    /// Runs `input` (same signal on L and R) through `processor` in blocks
    /// of `block` frames. Returns (left, right).
    static func run(_ processor: inout DSPProcessor, _ input: [Float], block: Int = 256) -> ([Float], [Float]) {
        var left = [Float](repeating: 0, count: input.count)
        var right = left
        input.withUnsafeBufferPointer { source in
            left.withUnsafeMutableBufferPointer { outLeft in
                right.withUnsafeMutableBufferPointer { outRight in
                    var done = 0
                    while done < source.count {
                        let count = min(block, source.count - done)
                        processor.process(
                            inputLeft: source.baseAddress! + done, inputRight: source.baseAddress! + done,
                            outputLeft: outLeft.baseAddress! + done, outputRight: outRight.baseAddress! + done,
                            frameCount: count)
                        done += count
                    }
                }
            }
        }
        return (left, right)
    }

    /// A render state for a stereo device, with `filters` active from the start.
    static func makeHandle(
        sampleRate: Double, filters: [FilterSection], bypass: Bool = false, gain: Float = 1, chunk: Int = 1024
    ) -> RenderStateHandle {
        let tap = stereoLayout.locations(ofStream: 0)
        let configuration = RenderConfiguration(
            inputLayout: stereoLayout, tapLeft: tap[0], tapRight: tap[1], outputLayout: stereoLayout,
            sampleRate: sampleRate, chunkFrames: chunk)
        return RenderStateHandle(
            configuration: configuration, gain: gain, bypass: bypass, outputPair: .firstPair, filters: filters)
    }

    /// One IO cycle through the full kernel (`renderFromSource`, as the
    /// split engine calls it). Returns the output (left, right).
    static func renderCycle(_ handle: RenderStateHandle, left: [Float], right: [Float]) -> ([Float], [Float]) {
        let frames = left.count
        let output = TestBufferList(channelCounts: [2], frames: frames)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                RenderKernel.renderFromSource(
                    state: handle.pointer, sourceLeft: l.baseAddress!, sourceRight: r.baseAddress!, frames: frames,
                    output: output.pointer)
            }
        }
        return (
            (0..<frames).map { output.get(buffer: 0, channel: 0, frame: $0) },
            (0..<frames).map { output.get(buffer: 0, channel: 1, frame: $0) }
        )
    }

    /// Feeds `input` through the kernel in IO cycles of `block` frames;
    /// `beforeCycle(index, startFrame)` runs before each cycle.
    static func render(
        _ handle: RenderStateHandle, _ input: [Float], block: Int = 256,
        beforeCycle: (Int, Int) -> Void = { _, _ in }
    ) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(input.count)
        var start = 0
        var cycle = 0
        while start < input.count {
            beforeCycle(cycle, start)
            let slice = Array(input[start..<min(input.count, start + block)])
            result += renderCycle(handle, left: slice, right: slice).0
            start += block
            cycle += 1
        }
        return result
    }

    static func peak(_ samples: ArraySlice<Float>) -> Double {
        Double(samples.map { $0.magnitude }.max() ?? 0)
    }

    static func decibels(_ linear: Double) -> Double { 20 * log10(linear) }
}

/// Deterministic random numbers for the fuzz tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Copyable views of the (non-copyable) processor state, for #expect.
extension RenderStateHandle {
    var eqIsRamping: Bool { pointer.pointee.processor.isRamping }
    var eqActiveTargets: [FilterSection] { pointer.pointee.processor.activeTargets }
    var eqAppliedSets: Int { pointer.pointee.processor.appliedSets }
    var eqActiveSlotCount: Int { pointer.pointee.processor.activeSlotCount }
}
