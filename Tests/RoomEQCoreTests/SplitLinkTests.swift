import CoreAudio
import Testing
@testable import RoomEQCore

private let stereoLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 2, isInterleaved: true)])

private func makeLink(
    capacity: Int = 16, layout: BufferListLayout = stereoLayout, left: Int = 0, right: Int = 1,
    sourceCapacity: Int = 16
) -> SplitLinkHandle {
    let channels = layout.locations(ofStream: 0)
    return SplitLinkHandle(
        configuration: SplitLinkConfiguration(
            captureLayout: layout, captureLeft: channels[left], captureRight: channels[right],
            sizing: SplitLinkSizing(ringCapacity: capacity, sourceCapacity: sourceCapacity, maximumDelay: capacity)))
}

/// Writes `frames` frames whose value is `value(sampleTime)` (right = -left).
private func write(_ link: SplitLinkHandle, start: Int64, frames: Int, value: (Int64) -> Float) {
    var left = [Float](), right = [Float]()
    for frame in 0..<frames {
        left.append(value(start + Int64(frame)))
        right.append(-value(start + Int64(frame)))
    }
    left.withUnsafeBufferPointer { l in
        right.withUnsafeBufferPointer { r in
            SampleRing.write(
                link.pointer, start: start, frames: frames, left: l.baseAddress!, leftStride: 1, right: r.baseAddress!,
                rightStride: 1)
        }
    }
}

private func read(_ link: SplitLinkHandle, start: Int64, frames: Int) -> (RingReadResult, [Float], [Float]) {
    var left = [Float](repeating: 99, count: frames), right = [Float](repeating: 99, count: frames)
    let result = left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            SampleRing.read(link.pointer, start: start, frames: frames, left: l.baseAddress!, right: r.baseAddress!)
        }
    }
    return (result, left, right)
}

private func stamp(sample: Double, host: UInt64 = 0) -> AudioTimeStamp {
    var time = AudioTimeStamp()
    time.mSampleTime = sample
    time.mHostTime = host
    time.mFlags = [.sampleTimeValid, .hostTimeValid]
    return time
}

@Suite("Sample ring")
struct SampleRingTests {
    @Test func wrapAroundAndOverwriteDetection() {
        let link = makeLink(capacity: 16)
        write(link, start: 10, frames: 10) { Float($0) }
        write(link, start: 20, frames: 10) { Float($0) }  // written up to 30
        // Oldest still available is 30 - 16 = 14: frames 12 and 13 are gone.
        let (overwritten, left, _) = read(link, start: 12, frames: 18)
        #expect(overwritten == RingReadResult(first: 2, end: 18, gapFrames: 0, overwrittenFrames: 2))
        #expect(left[0] == 0 && left[1] == 0)
        #expect(left[2] == 14 && left[17] == 29)

        let (valid, values, negated) = read(link, start: 14, frames: 16)
        #expect(valid.validFrames == 16)
        #expect(values == (14..<30).map(Float.init))
        #expect(negated[3] == -17)
    }

    @Test func framesBeingOverwrittenDuringTheCopyAreInvalidated() {
        let link = makeLink(capacity: 16)
        write(link, start: 0, frames: 16) { Float($0) }
        // The writer has announced [16, 20) (slots of frames 0..3) but not
        // published it yet: those 4 frames may be torn -> invalid.
        link.pointer.pointee.writeBegin.store(20, ordering: .relaxed)
        let (result, left, _) = read(link, start: 0, frames: 16)
        #expect(result == RingReadResult(first: 4, end: 16, gapFrames: 0, overwrittenFrames: 4))
        #expect(left[0...3].allSatisfy { $0 == 0 })
        #expect(left[4] == 4)
    }

    @Test func partialAvailabilityIsAnUnderrunAtTheEnd() {
        let link = makeLink(capacity: 64)
        write(link, start: 0, frames: 30) { Float($0) }
        let (result, left, _) = read(link, start: 25, frames: 10)
        #expect(result == RingReadResult(first: 0, end: 5))
        #expect(left[4] == 29)
        #expect(left[5...].allSatisfy { $0 == 0 })
        #expect(read(link, start: 40, frames: 8).0 == RingReadResult(first: 0, end: 0))
    }

    @Test func emptyRingIsAnUnderrun() {
        let link = makeLink()
        let (result, left, _) = read(link, start: 0, frames: 4)
        #expect(result == RingReadResult(first: 0, end: 0))
        #expect(left == [0, 0, 0, 0])
    }

    @Test func forwardGapIsInvalidNotSilentValid() {
        let link = makeLink(capacity: 64)
        write(link, start: 0, frames: 16) { _ in 1 }
        write(link, start: 16, frames: 4) { _ in 2 }
        write(link, start: 24, frames: 4) { _ in 3 }  // frames 20..23 never captured
        let (result, left, _) = read(link, start: 20, frames: 8)
        #expect(result == RingReadResult(first: 4, end: 8, gapFrames: 4, overwrittenFrames: 0))
        #expect(left[0...3].allSatisfy { $0 == 0 })
        #expect(left[4...].allSatisfy { $0 == 3 })
        #expect(link.status().discontinuities == 1)
    }

    @Test func smallBackwardOverlapIsRewrittenInPlace() {
        let link = makeLink(capacity: 64)
        write(link, start: 0, frames: 8) { _ in 1 }
        write(link, start: 6, frames: 8) { _ in 2 }  // steps back 2 frames (<= block)
        let (result, left, _) = read(link, start: 0, frames: 14)
        #expect(result.validFrames == 14)  // nothing invalidated
        #expect(left[5] == 1 && left[6] == 2 && left[13] == 2)
        #expect(link.status().discontinuities == 1)
    }

    @Test func largeBackwardJumpResetsTheValidRegion() {
        let link = makeLink(capacity: 64)
        write(link, start: 100, frames: 8) { _ in 1 }
        write(link, start: 0, frames: 8) { _ in 2 }
        #expect(read(link, start: 0, frames: 8).0.validFrames == 8)
        #expect(read(link, start: 100, frames: 8).0.validFrames == 0)  // now in the "future"
    }

    @Test func writesLargerThanTheRingKeepTheNewestFrames() {
        let link = makeLink(capacity: 16)
        write(link, start: 0, frames: 40) { Float($0) }
        let (result, left, _) = read(link, start: 24, frames: 16)
        #expect(result.validFrames == 16)
        #expect(left.first == 24 && left.last == 39)
    }
}

@Suite("Split sizing and timing")
struct SplitSizingTests {
    @Test func ringIsSizedFromTheConfiguredBuffer() {
        let small = SplitLinkSizing.make(maxCallbackFrames: 64, safetyOffsets: 28, delayIncreases: 4)
        #expect(small.sourceCapacity == 64)
        #expect(small.maximumDelay == 28 + 8 * 64 + 512)
        #expect(small.ringCapacity >= 4 * (small.maximumDelay + 64))
        #expect(small.ringCapacity & (small.ringCapacity - 1) == 0)

        // A device with 8192-frame buffers no longer yields a zero/negative maximum delay.
        let large = SplitLinkSizing.make(maxCallbackFrames: 8192, safetyOffsets: 100, delayIncreases: 4)
        #expect(large.maximumDelay > 8 * 8192)
        #expect(large.ringCapacity >= 4 * (large.maximumDelay + 8192))
        let link = SplitLinkHandle(
            configuration: SplitLinkConfiguration(
                captureLayout: stereoLayout, captureLeft: stereoLayout.channels[0],
                captureRight: stereoLayout.channels[1], sizing: large))
        #expect(link.maximumDelay == large.maximumDelay)
    }

    @Test func initialDelayFailsInsteadOfClamping() {
        #expect(DelayPolicy.initialDelay(maxNeed: 156, block: 64, maximum: 1052) == .success(220))
        #expect(DelayPolicy.initialDelay(maxNeed: -500, block: 64, maximum: 1052) == .success(1))
        guard case .failure(let error) = DelayPolicy.initialDelay(maxNeed: 2000, block: 64, maximum: 1052) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.needed == 2064)
        #expect(error.message.contains("supera il massimo"))
    }

    @Test func badSampleTimesAreRejected() {
        #expect(SampleTime.index(12.4) == 12)
        #expect(SampleTime.index(-3.6) == -4)
        #expect(SampleTime.index(.nan) == nil)
        #expect(SampleTime.index(.infinity) == nil)
        #expect(SampleTime.index(1e19) == nil)
    }
}

/// Full path with synthetic timestamps: a 10-channel tap (source = channels
/// 3/4) captured into the ring, warm-up measurement, fixed delay, then the
/// output IOProc routes the delayed audio to output pair 1-2.
@Suite("Split engine kernels")
struct SplitKernelTests {
    static let period = 64
    static let lead: Int64 = 192  // output sample time runs this far ahead of the capture

    final class Rig {
        let link: SplitLinkHandle
        let state: RenderStateHandle
        let input: TestBufferList
        let output: TestBufferList
        var cycle: Int64 = 0
        var captureSampleOverride: Double?
        var outputSampleOverride: Double?

        init() {
            let captureLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 10, isInterleaved: true)])
            let taps = captureLayout.locations(ofStream: 0)
            let sizing = SplitLinkSizing.make(maxCallbackFrames: period, safetyOffsets: 0, delayIncreases: 4)
            link = SplitLinkHandle(
                configuration: SplitLinkConfiguration(
                    captureLayout: captureLayout, captureLeft: taps[2], captureRight: taps[3], sizing: sizing))
            let outputLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 10, isInterleaved: true)])
            state = RenderStateHandle(
                configuration: RenderConfiguration(
                    inputLayout: captureLayout, tapLeft: taps[2], tapRight: taps[3], outputLayout: outputLayout,
                    sampleRate: 44100),
                gain: 1, bypass: false, outputPair: .firstPair)
            input = TestBufferList(channelCounts: [10], frames: period)
            output = TestBufferList(channelCounts: [10], frames: period, fill: 0.5)
        }

        static func value(_ sample: Int64) -> Float { Float(sample) / 100_000 }

        /// One IO cycle: capture first, then output.
        @discardableResult
        func step(capture: Bool = true) -> Int64 {
            let captureStart = cycle * Int64(period)
            if capture {
                for frame in 0..<period {
                    for channel in 0..<10 { input.set(buffer: 0, channel: channel, frame: frame, 0.9) }
                    input.set(buffer: 0, channel: 2, frame: frame, Rig.value(captureStart + Int64(frame)))
                    input.set(buffer: 0, channel: 3, frame: frame, -Rig.value(captureStart + Int64(frame)))
                }
                var captureTime = stamp(sample: captureSampleOverride ?? Double(captureStart))
                CaptureKernel.capture(
                    link.pointer, now: &captureTime, input: UnsafePointer(input.pointer), inputTime: &captureTime)
            }
            let outputStart = captureStart + lead
            var outputTime = stamp(sample: outputSampleOverride ?? Double(outputStart))
            SplitOutputKernel.render(state: state.pointer, link: link.pointer, outputTime: &outputTime, output: output.pointer)
            cycle += 1
            return outputStart
        }
    }

    @Test func warmupMeasuresTheNeedAndOutputsSilence() throws {
        let rig = Rig()
        let marker = rig.link.needHistoryPosition
        for _ in 0..<10 { rig.step() }
        #expect(rig.output.get(buffer: 0, channel: 0, frame: 10) == 0)  // silence while warming up
        let needs = try #require(rig.link.needValues(since: marker))
        #expect(needs.count == 10)
        #expect(needs.allSatisfy { $0 == Self.lead })  // (outS + n) - (captureS + n)
        let stats = try #require(WarmupAnalysis.statistics(needs))
        #expect(stats.min == Self.lead && stats.median == Self.lead && stats.max == Self.lead)
        let status = rig.link.status()
        #expect(status.needCount == 10 && status.needSum == 10 * Self.lead)
    }

    @Test func playsTheCapturedAudioAtTheFixedDelay() throws {
        let rig = Rig()
        for _ in 0..<5 { rig.step() }
        let delay = try DelayPolicy.initialDelay(maxNeed: Self.lead, block: Self.period, maximum: rig.link.maximumDelay).get()
        rig.link.setDelay(delay)

        rig.step()  // first block fades in
        #expect(rig.output.get(buffer: 0, channel: 0, frame: 0) == 0)

        let outputStart = rig.step()
        for frame in [0, 31, 63] {
            let source = outputStart - delay + Int64(frame)
            #expect(rig.output.get(buffer: 0, channel: 0, frame: frame) == Rig.value(source))
            #expect(rig.output.get(buffer: 0, channel: 1, frame: frame) == -Rig.value(source))
            for channel in 2..<10 { #expect(rig.output.get(buffer: 0, channel: channel, frame: frame) == 0) }
        }
        #expect(rig.link.status().underrunCycles == 0)
    }

    @Test func tooSmallDelayUnderrunsWithSilenceAndIsCounted() {
        let rig = Rig()
        for _ in 0..<3 { rig.step() }
        rig.link.setDelay(Self.lead + 64)
        for _ in 0..<3 { rig.step() }
        #expect(rig.link.status().underrunCycles == 0)

        // Shrinking the delay below the need: one faded block at the old
        // delay, then every cycle is (192 - 150) = 42 frames short.
        rig.link.setDelay(150)
        rig.step()
        #expect(rig.link.status().underrunCycles == 0)
        rig.step()
        let status = rig.link.status()
        #expect(status.underrunCycles == 1)
        #expect(status.missingFrames == UInt64(Self.lead - 150))
        #expect(rig.output.get(buffer: 0, channel: 0, frame: 63) == 0)
    }

    @Test func captureGapFadesBackIn() {
        let rig = Rig()
        for _ in 0..<3 { rig.step() }
        rig.link.setDelay(Self.lead + 64)
        for _ in 0..<4 { rig.step() }
        rig.step(capture: false)  // one capture cycle missing -> gap of 64 frames
        for _ in 0..<4 { rig.step() }
        let status = rig.link.status()
        #expect(status.discontinuities == 1)
        #expect(status.gapCycles >= 1)
        #expect(status.gapFrames >= 1)
    }

    @Test func nanSampleTimesAreInvalidCycles() {
        let rig = Rig()
        rig.captureSampleOverride = .nan
        rig.outputSampleOverride = .nan
        rig.step()
        let status = rig.link.status()
        #expect(status.captureInvalidCycles == 1)
        #expect(status.outputInvalidCycles == 1)
        #expect(rig.output.get(buffer: 0, channel: 0, frame: 0) == 0)
    }

    @Test func muteSilencesImmediately() {
        let rig = Rig()
        for _ in 0..<3 { rig.step() }
        rig.link.setDelay(Self.lead + 64)
        for _ in 0..<3 { rig.step() }
        #expect(rig.output.get(buffer: 0, channel: 0, frame: 10) != 0)
        rig.link.setMuted(true)
        rig.step()
        #expect(rig.output.get(buffer: 0, channel: 0, frame: 10) == 0)
    }
}
