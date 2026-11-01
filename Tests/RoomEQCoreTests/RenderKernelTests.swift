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
    output: BufferListLayout, gain: Float = 1, pair: OutputChannelPair = .firstPair, chunk: Int = 1024,
    sampleRate: Double = 44100, gainRampSeconds: Double = 0.015, crossfadeSeconds: Double = 0.010,
    bypass: Bool = false
) -> RenderStateHandle {
    let config = RenderConfiguration(
        inputLayout: inputLayout, tapLeft: tapLocations[0], tapRight: tapLocations[1],
        outputLayout: output, sampleRate: sampleRate, chunkFrames: chunk,
        gainRampSeconds: gainRampSeconds, bypassCrossfadeSeconds: crossfadeSeconds)
    return RenderStateHandle(configuration: config, gain: gain, bypass: bypass, outputPair: pair)
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

    @Test func steadyGain() {
        let frames = 64
        let input = makeInput(frames: frames, left: { _ in 1 }, right: { _ in 1 })
        let output = TestBufferList(channelCounts: [10], frames: frames)
        let handle = makeHandle(output: interleaved10, gain: 0.5)

        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
        #expect(output.get(buffer: 0, channel: 0, frame: 10) == 0.5)
    }

    /// The gain ramp lasts a fixed TIME (here 16 ms = 16 samples at 1 kHz)
    /// and continues across IO buffers smaller than the ramp.
    @Test func gainRampIsFixedTimeAcrossSmallBuffers() {
        let frames = 4
        let input = makeInput(frames: frames, left: { _ in 1 }, right: { _ in 1 })
        let output = TestBufferList(channelCounts: [10], frames: frames)
        let handle = makeHandle(output: interleaved10, gain: 0, sampleRate: 1000, gainRampSeconds: 0.016)

        handle.setGain(linear: 1)
        var lastValues: [Float] = []
        for _ in 0..<5 {
            RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
            lastValues.append(output.get(buffer: 0, channel: 0, frame: frames - 1))
        }
        // After 4, 8, 12, 16 samples: 1/4, 2/4, 3/4, exactly 1; then steady.
        #expect(abs(lastValues[0] - 0.25) < 1e-6)
        #expect(abs(lastValues[1] - 0.5) < 1e-6)
        #expect(abs(lastValues[2] - 0.75) < 1e-6)
        #expect(lastValues[3] == 1)
        #expect(lastValues[4] == 1)
    }

    /// Bypass crossfades over a fixed time (10 ms = 10 samples at 1 kHz)
    /// across IO cycles; with no EQ bands (bit-exact passthrough) the output
    /// must not change at all while crossfading.
    @Test func bypassCrossfadesOverFixedTime() {
        let frames = 4
        let input = makeInput(frames: frames, left: { _ in 0.5 }, right: { _ in -0.5 })
        let output = TestBufferList(channelCounts: [10], frames: frames)
        let handle = makeHandle(output: interleaved10, sampleRate: 1000, crossfadeSeconds: 0.010)
        #expect(handle.pointer.pointee.wetMix.value == 1)

        handle.setBypass(true)
        var mixes: [Float] = []
        for _ in 0..<4 {
            RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
            mixes.append(handle.pointer.pointee.wetMix.value)
            for frame in 0..<frames {
                #expect(output.get(buffer: 0, channel: 0, frame: frame) == 0.5)
                #expect(output.get(buffer: 0, channel: 1, frame: frame) == -0.5)
            }
        }
        #expect(abs(mixes[0] - 0.6) < 1e-6)
        #expect(abs(mixes[1] - 0.2) < 1e-6)
        #expect(mixes[2] == 0)
        #expect(mixes[3] == 0)

        // And back: the DSP side fades in again.
        handle.setBypass(false)
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
        #expect(abs(handle.pointer.pointee.wetMix.value - 0.4) < 1e-6)
    }

    @Test func invalidOutputCyclesAreCountedAndSilent() {
        let frames = 16
        let input = makeInput(frames: frames, left: { _ in 0.3 }, right: { _ in 0.3 })
        let handle = makeHandle(output: interleaved10)

        // Device now delivers two 2-channel buffers instead of one 10-channel one.
        let changed = TestBufferList(channelCounts: [2, 2], frames: frames, fill: 0.9)
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: changed.pointer)
        #expect(changed.get(buffer: 0, channel: 0, frame: 3) == 0)
        #expect(changed.get(buffer: 1, channel: 1, frame: 3) == 0)

        // Same buffer count but different channel count.
        let narrower = TestBufferList(channelCounts: [8], frames: frames, fill: 0.9)
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: narrower.pointer)
        #expect(narrower.get(buffer: 0, channel: 0, frame: 0) == 0)

        // No output list at all.
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: nil)

        let meters = handle.readMeters()
        #expect(meters.invalidOutputCycles == 3)
        #expect(meters.invalidInputCycles == 0)
        #expect(meters.renderedCycles == 3)
        #expect(meters.invalidCycles == 3)
    }

    @Test func outputIsClampedToFullScale() {
        let frames = 8
        let input = makeInput(frames: frames, left: { _ in 1.5 }, right: { _ in -2 })
        let output = TestBufferList(channelCounts: [10], frames: frames)
        let handle = makeHandle(output: interleaved10)

        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
        for frame in 0..<frames {
            #expect(output.get(buffer: 0, channel: 0, frame: frame) == 1)
            #expect(output.get(buffer: 0, channel: 1, frame: frame) == -1)
        }
        let meters = handle.readMeters()
        #expect(meters.clippedSamples == UInt64(2 * frames))
        // Peaks are measured before the clamp, so the overs are visible.
        #expect(meters.outputPeakLeft == 1.5)
        #expect(meters.outputPeakRight == 2)
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
        let input = makeInput(frames: frames, left: { Float($0) / 256 }, right: { -Float($0) / 128 })
        let output = TestBufferList(channelCounts: [10], frames: frames)
        let handle = makeHandle(output: interleaved10, chunk: 16)

        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)
        for frame in [0, 15, 16, 17, 63, 99] {
            #expect(output.get(buffer: 0, channel: 0, frame: frame) == Float(frame) / 256)
            #expect(output.get(buffer: 0, channel: 1, frame: frame) == -Float(frame) / 128)
        }
    }

    /// First launch: no filters. Switching the correction on must play the
    /// audio unchanged (flat), with no warnings and no invalid cycles.
    @Test func noFiltersPassAudioThroughUnchanged() {
        let settings = AppSettings.defaults()
        let design = EQDesign(bands: settings.bands, sampleRate: 48_000)
        #expect(design.sections.isEmpty && design.warnings.isEmpty)
        #expect(EQCurve.maximumBoostDecibels(design: design) == 0)
        let gain = Preamp.linearGain(decibels: settings.preampDecibels)!
        let handle = DSPTest.makeHandle(sampleRate: 48_000, filters: design.sections, gain: gain)
        handle.publishWorkingState(bands: settings.bands, preampDecibels: settings.preampDecibels)
        let input = DSPTest.sine(frequency: 1000, sampleRate: 48_000, amplitude: 0.8, count: 4096)
        let output = DSPTest.render(handle, input, block: 64)
        let error = zip(input, output).map { Double(abs($0 - $1)) }.max() ?? 1
        #expect(error < 1e-7)
        let meters = handle.readMeters()
        #expect(meters.invalidCycles == 0 && meters.nonFiniteSamples == 0 && meters.clippedSamples == 0)
    }

    @Test func overloadCounter() {
        let handle = makeHandle(output: interleaved10)
        handle.recordOverload()
        handle.recordOverload()
        #expect(handle.readMeters().overloads == 2)
    }
}
