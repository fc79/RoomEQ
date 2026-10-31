import CoreAudio
import Testing
@testable import RoomEQCore

private let stereoLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 2, isInterleaved: true)])

private func makeLink(capacity: Int = 16, layout: BufferListLayout = stereoLayout, left: Int = 0, right: Int = 1)
    -> SplitLinkHandle
{
    let channels = layout.locations(ofStream: 0)
    return SplitLinkHandle(
        configuration: SplitLinkConfiguration(
            captureLayout: layout, captureLeft: channels[left], captureRight: channels[right],
            ringCapacity: capacity, maxOutputFrames: 512))
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
        write(link, start: 10, frames: 10) { Float($0) }  // slots 10..15, 0..3
        write(link, start: 20, frames: 10) { Float($0) }  // wraps again; written up to 30
        // Oldest still available is 30 - 16 = 14: frames 12 and 13 are gone.
        let (overwritten, left, _) = read(link, start: 12, frames: 18)
        #expect(overwritten == RingReadResult(first: 2, end: 18))
        #expect(left[0] == 0 && left[1] == 0)
        #expect(left[2] == 14 && left[17] == 29)

        let (valid, values, negated) = read(link, start: 14, frames: 16)
        #expect(valid.validFrames == 16)
        #expect(values == (14..<30).map(Float.init))
        #expect(negated[3] == -17)
    }

    @Test func partialAvailabilityIsAnUnderrunAtTheEnd() {
        let link = makeLink(capacity: 64)
        write(link, start: 0, frames: 30) { Float($0) }
        let (result, left, _) = read(link, start: 25, frames: 10)
        #expect(result == RingReadResult(first: 0, end: 5))
        #expect(left[4] == 29)
        #expect(left[5...].allSatisfy { $0 == 0 })
        // Entirely in the future: nothing valid.
        #expect(read(link, start: 40, frames: 8).0.validFrames == 0)
        #expect(read(link, start: 40, frames: 8).0.end == 0)
    }

    @Test func emptyRingIsAnUnderrun() {
        let link = makeLink()
        let (result, left, _) = read(link, start: 0, frames: 4)
        #expect(result == RingReadResult(first: 0, end: 0))
        #expect(left == [0, 0, 0, 0])
    }

    @Test func sampleTimeJumpsZeroStaleAudio() {
        let link = makeLink(capacity: 16)
        write(link, start: 0, frames: 16) { _ in 1 }
        write(link, start: 16, frames: 4) { _ in 2 }
        write(link, start: 24, frames: 4) { _ in 3 }  // gap [20, 24) -> slots that held 1
        let (gap, left, _) = read(link, start: 20, frames: 4)
        #expect(gap.validFrames == 4)
        #expect(left == [0, 0, 0, 0])
        #expect(link.status().discontinuities == 1)

        // Backwards jump: the whole ring is cleared.
        write(link, start: 0, frames: 4) { _ in 5 }
        #expect(link.status().discontinuities == 2)
        let (history, old, _) = read(link, start: -12, frames: 12)
        #expect(history.validFrames == 12)
        #expect(old.allSatisfy { $0 == 0 })
    }

    @Test func writesLargerThanTheRingKeepTheNewestFrames() {
        let link = makeLink(capacity: 16)
        write(link, start: 0, frames: 40) { Float($0) }
        let (result, left, _) = read(link, start: 24, frames: 16)
        #expect(result.validFrames == 16)
        #expect(left.first == 24 && left.last == 39)
    }
}

@Suite("Split timeline")
struct SplitTimelineTests {
    @Test func offsetFromTimestamps() {
        let ticks = 24_000_000.0
        // Output stamp 10 ms after the capture stamp, same timeline.
        let same = SplitTimeline.offset(
            capture: (1000, 24_000_000), output: (1441, 24_240_000), sampleRate: 44100, ticksPerSecond: ticks)
        #expect(same == 0)
        // Capture timeline 5 frames ahead.
        let ahead = SplitTimeline.offset(
            capture: (1005, 24_000_000), output: (1441, 24_240_000), sampleRate: 44100, ticksPerSecond: ticks)
        #expect(ahead == 5)
    }

    @Test func delayFromNeedOffsetAndMargin() {
        #expect(SplitTimeline.delay(maxNeed: 192, offset: 0, margin: 32, minimum: 1, maximum: 4000) == 224)
        #expect(SplitTimeline.delay(maxNeed: 192, offset: 5, margin: 32, minimum: 1, maximum: 4000) == 229)
        #expect(SplitTimeline.delay(maxNeed: -50, offset: 0, margin: 32, minimum: 64, maximum: 4000) == 64)
        #expect(SplitTimeline.delay(maxNeed: 9000, offset: 0, margin: 32, minimum: 1, maximum: 4000) == 4000)
    }
}

/// Full path with synthetic timestamps: a 10-channel tap (source = channels
/// 3/4) captured into the ring, warm-up measurement, fixed delay, then the
/// output IOProc routes the delayed audio to output pair 1-2.
@Suite("Split engine kernels")
struct SplitKernelTests {
    let period = 64
    let lead: Int64 = 192  // output sample time runs this far ahead of the capture

    final class Rig {
        let link: SplitLinkHandle
        let state: RenderStateHandle
        let input: TestBufferList
        let output: TestBufferList
        var cycle: Int64 = 0
        let period: Int
        let lead: Int64

        init(period: Int, lead: Int64) {
            self.period = period
            self.lead = lead
            let captureLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 10, isInterleaved: true)])
            let tap = TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (3, 4))
            link = makeLink(capacity: 8192, layout: captureLayout, left: tap.left, right: tap.right)
            let outputLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 10, isInterleaved: true)])
            let taps = captureLayout.locations(ofStream: 0)
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
        func step() -> Int64 {
            let captureStart = cycle * Int64(period)
            for frame in 0..<period {
                for channel in 0..<10 { input.set(buffer: 0, channel: channel, frame: frame, 0.9) }
                input.set(buffer: 0, channel: 2, frame: frame, Rig.value(captureStart + Int64(frame)))
                input.set(buffer: 0, channel: 3, frame: frame, -Rig.value(captureStart + Int64(frame)))
            }
            var captureTime = stamp(sample: Double(captureStart), host: UInt64(1000 + cycle))
            CaptureKernel.capture(link.pointer, now: &captureTime, input: UnsafePointer(input.pointer), inputTime: &captureTime)
            let outputStart = captureStart + lead
            var outputTime = stamp(sample: Double(outputStart), host: UInt64(1000 + cycle))
            SplitOutputKernel.render(state: state.pointer, link: link.pointer, outputTime: &outputTime, output: output.pointer)
            cycle += 1
            return outputStart
        }
    }

    @Test func warmupMeasuresTheNeededDelayAndOutputsSilence() throws {
        let rig = Rig(period: period, lead: lead)
        for _ in 0..<10 { rig.step() }
        #expect(rig.output.get(buffer: 0, channel: 0, frame: 10) == 0)  // silence while warming up
        let measurement = rig.link.warmupMeasurement()
        #expect(measurement.maxNeed == lead)  // (outS + n) - (captureS + n)
        #expect(measurement.samples == 10)
        let stamps = try #require(rig.link.firstTimestamps())
        #expect(stamps.capture.0 == 0 && stamps.output.0 == lead)
    }

    @Test func playsTheCapturedAudioAtTheFixedDelay() {
        let rig = Rig(period: period, lead: lead)
        for _ in 0..<5 { rig.step() }
        let delay = SplitTimeline.delay(
            maxNeed: rig.link.warmupMeasurement().maxNeed!, offset: 0, margin: 32, minimum: 1, maximum: 4000)
        rig.link.start(offset: 0, delay: delay)

        rig.step()  // first block fades in
        let fadedFirst = rig.output.get(buffer: 0, channel: 0, frame: 0)
        #expect(fadedFirst == 0)

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
        let rig = Rig(period: period, lead: lead)
        for _ in 0..<3 { rig.step() }
        rig.link.start(offset: 0, delay: lead + 32)
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
        #expect(status.missingFrames == UInt64(lead - 150))
        // The missing tail is silent.
        #expect(rig.output.get(buffer: 0, channel: 0, frame: 63) == 0)
    }

    @Test func timelineOffsetIsApplied() {
        let rig = Rig(period: period, lead: lead)
        for _ in 0..<3 { rig.step() }
        // Pretend the capture timeline is 10 frames ahead: delay grows by 10
        // and the read position moves by +10, so the audio is the same.
        rig.link.start(offset: 10, delay: lead + 32 + 10)
        rig.step()
        let outputStart = rig.step()
        let source = outputStart + 10 - (lead + 32 + 10)
        #expect(rig.output.get(buffer: 0, channel: 0, frame: 5) == Rig.value(source + 5))
    }
}
