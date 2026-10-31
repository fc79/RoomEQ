import CoreAudio
import Testing
@testable import RoomEQCore

/// A heap-allocated AudioBufferList for tests. A buffer with `hasData == false`
/// gets a NULL mData, like a stream disabled with kAudioDevicePropertyIOProcStreamUsage.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int
    private var storage: [UnsafeMutablePointer<Float>?] = []

    init(channelCounts: [Int], frames: Int, hasData: [Bool]? = nil, fill: Float = 0) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
        for (index, channels) in channelCounts.enumerated() {
            let present = hasData?[index] ?? true
            var data: UnsafeMutablePointer<Float>? = nil
            if present {
                data = .allocate(capacity: channels * frames)
                data!.initialize(repeating: fill, count: channels * frames)
            }
            storage.append(data)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                mData: data.map { UnsafeMutableRawPointer($0) })
        }
    }

    deinit {
        storage.forEach { $0?.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func set(buffer: Int, channel: Int, frame: Int, _ value: Float) {
        let channels = Int(list[buffer].mNumberChannels)
        storage[buffer]![frame * channels + channel] = value
    }

    func get(buffer: Int, channel: Int, frame: Int) -> Float {
        let channels = Int(list[buffer].mNumberChannels)
        return storage[buffer]![frame * channels + channel]
    }

    var pointer: UnsafeMutablePointer<AudioBufferList> { list.unsafeMutablePointer }
}

/// Aggregate-like input: 18-channel hardware stream (disabled, NULL data) + stereo tap.
private let inputLayout = BufferListLayout(streams: [
    StreamFormatInfo(channels: 18, isInterleaved: true),
    StreamFormatInfo(channels: 2, isInterleaved: true),
])
private let tapLocations = inputLayout.locations(ofStream: 1)

private func makeInput(frames: Int, left: (Int) -> Float, right: (Int) -> Float) -> TestBufferList {
    let input = TestBufferList(channelCounts: [18, 2], frames: frames, hasData: [false, true])
    for frame in 0..<frames {
        input.set(buffer: 1, channel: 0, frame: frame, left(frame))
        input.set(buffer: 1, channel: 1, frame: frame, right(frame))
    }
    return input
}

private func makeHandle(
    output: BufferListLayout, gain: Float = 1, pair: OutputChannelPair = .firstPair, chunk: Int = 1024
) -> RenderStateHandle {
    let config = RenderConfiguration(
        inputLayout: inputLayout, tapLeft: tapLocations[0], tapRight: tapLocations[1],
        outputLayout: output, sampleRate: 44100, chunkFrames: chunk)
    return RenderStateHandle(configuration: config, gain: gain, bypass: false, outputPair: pair)
}

@Suite("Render kernel")
struct RenderKernelTests {
    let interleaved10 = BufferListLayout(streams: [StreamFormatInfo(channels: 10, isInterleaved: true)])

    @Test func routesTapToFirstPairAndZeroesTheRest() {
        let frames = 64
        let input = makeInput(frames: frames, left: { Float($0) / 100 }, right: { -Float($0) / 100 })
        let output = TestBufferList(channelCounts: [10], frames: frames, fill: 0.77)  // garbage
        let handle = makeHandle(output: interleaved10)

        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)

        for frame in 0..<frames {
            #expect(output.get(buffer: 0, channel: 0, frame: frame) == Float(frame) / 100)
            #expect(output.get(buffer: 0, channel: 1, frame: frame) == -Float(frame) / 100)
            for channel in 2..<10 {
                #expect(output.get(buffer: 0, channel: channel, frame: frame) == 0)
            }
        }
        let meters = handle.readMeters()
        #expect(meters.invalidInputCycles == 0)
        #expect(meters.renderedCycles == 1)
        #expect(abs(meters.inputPeakLeft - 0.63) < 1e-6)
        #expect(abs(meters.outputPeakRight - 0.63) < 1e-6)
        // Peaks are reset by reading.
        #expect(handle.readMeters().outputPeakLeft == 0)
    }

    @Test func outputPairCanChangeLive() {
        let frames = 32
        let input = makeInput(frames: frames, left: { _ in 0.25 }, right: { _ in 0.5 })
        let output = TestBufferList(channelCounts: [10], frames: frames)
        let handle = makeHandle(output: interleaved10)

        #expect(handle.setOutputPair(OutputChannelPair(left: 4)))
        #expect(!handle.setOutputPair(OutputChannelPair(left: 10)))  // channels 11-12 don't exist
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)

        #expect(output.get(buffer: 0, channel: 0, frame: 5) == 0)
        #expect(output.get(buffer: 0, channel: 4, frame: 5) == 0.25)
        #expect(output.get(buffer: 0, channel: 5, frame: 5) == 0.5)
    }

    @Test func nonInterleavedOutput() {
        let frames = 16
        let layout = BufferListLayout(streams: [StreamFormatInfo(channels: 4, isInterleaved: false)])
        let input = makeInput(frames: frames, left: { _ in 0.1 }, right: { _ in 0.2 })
        let output = TestBufferList(channelCounts: [1, 1, 1, 1], frames: frames, fill: 0.9)
        let handle = makeHandle(output: layout, pair: OutputChannelPair(left: 2))

        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)

        #expect(output.get(buffer: 0, channel: 0, frame: 3) == 0)
        #expect(output.get(buffer: 1, channel: 0, frame: 3) == 0)
        #expect(output.get(buffer: 2, channel: 0, frame: 3) == 0.1)
        #expect(output.get(buffer: 3, channel: 0, frame: 3) == 0.2)
    }

    @Test func missingInputGivesSilence() {
        let output = TestBufferList(channelCounts: [10], frames: 32, fill: 0.5)
        let handle = makeHandle(output: interleaved10)

        RenderKernel.render(state: handle.pointer, input: nil, output: output.pointer)
        #expect(output.get(buffer: 0, channel: 0, frame: 0) == 0)

        // Wrong number of input buffers (layout changed under us) -> silence too.
        let wrong = TestBufferList(channelCounts: [2], frames: 32, fill: 0.5)
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(wrong.pointer), output: output.pointer)
        #expect(output.get(buffer: 0, channel: 1, frame: 7) == 0)
        #expect(handle.readMeters().invalidInputCycles == 2)
    }

    @Test func gainAndRamp() {
        let frames = 64
        let input = makeInput(frames: frames, left: { _ in 1 }, right: { _ in 1 })
        let output = TestBufferList(channelCounts: [10], frames: frames)
        let handle = makeHandle(output: interleaved10, gain: 0.5)

        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
        #expect(output.get(buffer: 0, channel: 0, frame: 10) == 0.5)

        // Change gain: next cycle ramps smoothly from 0.5 to 1.0.
        handle.setGain(linear: 1)
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
        let first = output.get(buffer: 0, channel: 0, frame: 0)
        let middle = output.get(buffer: 0, channel: 0, frame: 31)
        let last = output.get(buffer: 0, channel: 0, frame: frames - 1)
        #expect(first > 0.5 && first < 0.52)
        #expect(middle > first && middle < last)
        #expect(abs(last - 1) < 1e-5)

        // Afterwards the gain is steady at 1.0.
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
        #expect(output.get(buffer: 0, channel: 0, frame: 0) == 1)
    }

    @Test func clippingAndNonFiniteSamples() {
        let frames = 8
        let input = makeInput(
            frames: frames,
            left: { $0 == 3 ? 1.5 : 0.1 },
            right: { $0 == 4 ? Float.nan : 0.1 })
        let output = TestBufferList(channelCounts: [10], frames: frames)
        let handle = makeHandle(output: interleaved10)

        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
        let meters = handle.readMeters()
        #expect(meters.clippedSamples == 1)
        #expect(meters.nonFiniteSamples == 1)
        #expect(output.get(buffer: 0, channel: 1, frame: 4) == 0)  // NaN replaced by silence
        #expect(meters.outputPeakLeft == 1.5)
    }

    @Test func buffersLargerThanChunkAreProcessedCompletely() {
        let frames = 100
        let input = makeInput(frames: frames, left: { Float($0) }, right: { Float($0) * 2 })
        let output = TestBufferList(channelCounts: [10], frames: frames)
        let handle = makeHandle(output: interleaved10, chunk: 16)

        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
        for frame in [0, 15, 16, 17, 63, 99] {
            #expect(output.get(buffer: 0, channel: 0, frame: frame) == Float(frame))
            #expect(output.get(buffer: 0, channel: 1, frame: frame) == Float(frame) * 2)
        }
    }

    @Test func overloadCounter() {
        let handle = makeHandle(output: interleaved10)
        handle.recordOverload()
        handle.recordOverload()
        #expect(handle.readMeters().overloads == 2)
    }
}
