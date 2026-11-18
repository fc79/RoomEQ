import Foundation
import Testing
@testable import RoomEQCore

/// Collects what the silence gate does, as a list of files.
private struct FileLog: RecordingSink {
    var files: [[Float]] = []
    var isOpen = false
    mutating func open() { #expect(!isOpen); files.append([]); isOpen = true }
    mutating func write(_ samples: UnsafeBufferPointer<Float>) { #expect(isOpen); files[files.count - 1] += samples }
    mutating func close() { #expect(isOpen); isOpen = false }
}

/// `frames` stereo frames, all at `value`.
private func block(_ frames: Int, _ value: Float) -> [Float] { [Float](repeating: value, count: frames * 2) }

@Suite("Recording")
struct RecordingTests {
    // MARK: Ring

    @Test func ringCopiesOneStereoPairAndWrapsAround() {
        let ring = RecordingRing(minimumFrames: 5)
        #expect(ring.capacity == 8)
        // 4-channel interleaved source; record channels 2 and 3.
        var source: [Float] = []
        for frame in 0..<6 { source += [0, 0, Float(frame), -Float(frame)] }
        #expect(source.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 6, channelCount: 4, left: 2, right: 3) } == 6)
        var out = [Float](repeating: 9, count: 8)
        #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxFrames: 4) } == 4)
        #expect(out == [0, 0, 1, -1, 2, -2, 3, -3])
        // Wrap: 6 more frames fit (2 left + 6 = 8).
        #expect(source.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 6, channelCount: 4, left: 2, right: 3) } == 6)
        #expect(ring.available == 8)
        var all = [Float](repeating: 0, count: 16)
        #expect(all.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxFrames: 8) } == 8)
        #expect(Array(all[0..<4]) == [4, -4, 5, -5])
        #expect(Array(all[4..<8]) == [0, 0, 1, -1])
        #expect(ring.takeDroppedFrames() == 0)
    }

    @Test func fullRingDropsAndCountsFrames() {
        let ring = RecordingRing(minimumFrames: 4)
        let source = block(6, 0.5)
        #expect(source.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 6, channelCount: 2, left: 0, right: 1) } == 4)
        #expect(ring.takeDroppedFrames() == 2)
        #expect(ring.takeDroppedFrames() == 0)
    }

    /// Frames lost while the ring was full become silence right where they
    /// were lost: after the frames stored before, and before what the
    /// producer stores while the drain frees room.
    @Test func drainPutsTheSilenceWhereTheFramesWereLost() {
        let ring = RecordingRing(minimumFrames: 4)
        var source: [Float] = []
        for frame in 1...6 { source += [Float(frame), Float(frame)] }
        // 1…4 stored, 5 and 6 dropped.
        #expect(source.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 6, channelCount: 2, left: 0, right: 1) } == 4)
        let later: [Float] = [7, 7, 8, 8]
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { scratch.deallocate() }
        var timeline: [Float] = []
        var producedLater = false
        let dropped = ring.drain(scratch: scratch, scratchFrames: 2) { chunk in
            switch chunk {
            case .audio(let samples):
                timeline += samples.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            case .silence(let frames):
                timeline += [Float](repeating: 0, count: frames)
            }
            if !producedLater {
                // The producer runs while the drain reads (room freed).
                producedLater = true
                #expect(later.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 2, channelCount: 2, left: 0, right: 1) } == 2)
            }
        }
        #expect(dropped == 2)
        #expect(timeline == [1, 2, 3, 4, 0, 0, 7, 8])
        #expect(ring.available == 0)
        #expect(ring.takeDroppedFrames() == 0)
    }

    @Test func drainWithoutLossesIsPlainAudio() {
        let ring = RecordingRing(minimumFrames: 8)
        let source = block(5, 0.25)
        source.withUnsafeBufferPointer { _ = ring.write(interleaved: $0.baseAddress!, frames: 5, channelCount: 2, left: 0, right: 1) }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { scratch.deallocate() }
        var frames = 0
        var silences = 0
        let dropped = ring.drain(scratch: scratch, scratchFrames: 2) { chunk in
            switch chunk {
            case .audio(let samples): frames += samples.count / 2
            case .silence: silences += 1
            }
        }
        #expect(dropped == 0)
        #expect(frames == 5)
        #expect(silences == 0)
    }

    /// A buffer in an unexpected layout becomes silence in its place.
    @Test func silenceIsStoredInOrder() {
        let ring = RecordingRing(minimumFrames: 8)
        // Fill every slot with non-zero audio first, so the silence must
        // really overwrite it.
        let full = block(8, 5)
        full.withUnsafeBufferPointer { _ = ring.write(interleaved: $0.baseAddress!, frames: 8, channelCount: 2, left: 0, right: 1) }
        var sink = [Float](repeating: 0, count: 16)
        _ = sink.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxFrames: 8) }
        let one = block(2, 1)
        one.withUnsafeBufferPointer { _ = ring.write(interleaved: $0.baseAddress!, frames: 2, channelCount: 2, left: 0, right: 1) }
        #expect(ring.writeSilence(frames: 3) == 3)
        one.withUnsafeBufferPointer { _ = ring.write(interleaved: $0.baseAddress!, frames: 2, channelCount: 2, left: 0, right: 1) }
        var out = [Float](repeating: 9, count: 14)
        #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxFrames: 7) } == 7)
        #expect(out.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) == [1, 1, 0, 0, 0, 1, 1])
        #expect(ring.takeSilencedFrames() == 3)
        #expect(ring.writeSilence(frames: 10) == 8)
        #expect(ring.takeDroppedFrames() == 2)
        #expect(ring.takeSilencedFrames() == 8)
    }

    /// Frames lost WHILE a drain runs (the writer stalls inside `emit` on a
    /// slow disk, the ring fills up) still get their silence where they were
    /// lost, not after what the producer stored afterwards.
    @Test func lossDuringADrainIsPlacedWhereItHappened() {
        let ring = RecordingRing(minimumFrames: 4)
        func put(_ values: [Float]) -> Int {
            let samples = values.flatMap { [$0, $0] }
            return samples.withUnsafeBufferPointer {
                ring.write(interleaved: $0.baseAddress!, frames: values.count, channelCount: 2, left: 0, right: 1)
            }
        }
        #expect(put([1, 2, 3, 4]) == 4)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { scratch.deallocate() }
        var timeline: [Float] = []
        var emits = 0
        let dropped = ring.drain(scratch: scratch, scratchFrames: 2) { chunk in
            switch chunk {
            case .audio(let samples): timeline += samples.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            case .silence(let frames): timeline += [Float](repeating: 0, count: frames)
            }
            emits += 1
            if emits == 1 { #expect(put([5, 6, 7]) == 2) }  // 7 lost: the ring is full again
            if emits == 2 { #expect(put([8]) == 1) }  // after the loss
        }
        #expect(dropped == 1)
        #expect(timeline == [1, 2, 3, 4, 5, 6, 0, 8])
    }

    /// After a failed capture attempt nothing it wrote reaches the files.
    @Test func discardAllEmptiesTheRingAndTheLosses() {
        let ring = RecordingRing(minimumFrames: 4)
        let source = block(6, 0.5)
        source.withUnsafeBufferPointer { _ = ring.write(interleaved: $0.baseAddress!, frames: 6, channelCount: 2, left: 0, right: 1) }
        #expect(ring.writeSilence(frames: 1) == 0)  // full: counted as dropped
        let empty = RecordingRing(minimumFrames: 4)
        empty.writeSilence(frames: 2)
        empty.discardAll()
        #expect(empty.takeSilencedFrames() == 0)
        ring.discardAll()
        #expect(ring.available == 0)
        #expect(ring.takeDroppedFrames() == 0)
        #expect(ring.takePeak() == 0)
        #expect(source.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 4, channelCount: 2, left: 0, right: 1) } == 4)
    }

    @Test func ringReportsThePeakOfTheRecordedPairOnly() {
        let ring = RecordingRing(minimumFrames: 8)
        let source: [Float] = [0.9, 0.2, -0.4, 0.1, 0.3, -0.05]  // 3 channels; record 1 and 2
        #expect(source.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: 2, channelCount: 3, left: 1, right: 2) } == 2)
        #expect(ring.takePeak() == 0.4)
        #expect(ring.takePeak() == 0)
    }

    // MARK: Silence gate

    private let settings = SilenceGate.Settings(threshold: 0.01, holdFrames: 20, preRollFrames: 3, tailFrames: 5)

    private func run(_ gate: inout SilenceGate, _ log: inout FileLog, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { gate.process($0, into: &log) }
    }

    @Test func gateOffWritesEverythingInOneFile() {
        var gate = SilenceGate(settings: settings, enabled: false)
        var log = FileLog()
        run(&gate, &log, block(10, 0))
        run(&gate, &log, block(10, 0.5))
        gate.finish(into: &log)
        #expect(log.files.count == 1)
        #expect(log.files[0].count == 40)
        #expect(!log.isOpen)
    }

    @Test func silenceBeforeTheFirstSoundIsSkippedExceptThePreRoll() {
        var gate = SilenceGate(settings: settings, enabled: true)
        var log = FileLog()
        run(&gate, &log, block(10, 0.001))
        #expect(log.files.isEmpty)
        #expect(gate.isPaused)
        run(&gate, &log, block(4, 0.5))
        #expect(log.files.count == 1)
        // 3 pre-roll frames + 4 loud frames.
        #expect(log.files[0] == block(3, 0.001) + block(4, 0.5))
    }

    @Test func shortPauseStaysInTheSameFileWithItsSilence() {
        var gate = SilenceGate(settings: settings, enabled: true)
        var log = FileLog()
        run(&gate, &log, block(4, 0.5))
        run(&gate, &log, block(12, 0))  // < hold (20)
        run(&gate, &log, block(4, 0.5))
        gate.finish(into: &log)
        #expect(log.files.count == 1)
        #expect(log.files[0] == block(4, 0.5) + block(12, 0) + block(4, 0.5))
    }

    @Test func longPauseClosesTheFileKeepingOnlyTheTail() {
        var gate = SilenceGate(settings: settings, enabled: true)
        var log = FileLog()
        run(&gate, &log, block(4, 0.5))
        run(&gate, &log, block(30, 0))  // > hold
        #expect(!log.isOpen)
        #expect(log.files[0] == block(4, 0.5) + block(5, 0))  // tail = 5
        run(&gate, &log, block(2, 0.3))
        gate.finish(into: &log)
        #expect(log.files.count == 2)
        #expect(log.files[1] == block(3, 0) + block(2, 0.3))  // pre-roll from the silence
    }

    @Test func soundRightAfterTheHoldStillGetsItsPreRoll() {
        var gate = SilenceGate(settings: settings, enabled: true)
        var log = FileLog()
        run(&gate, &log, block(4, 0.5))
        run(&gate, &log, block(20, 0.002))  // exactly hold: closes, nothing after it
        #expect(!log.isOpen)
        run(&gate, &log, block(1, 0.5))
        gate.finish(into: &log)
        #expect(log.files.count == 2)
        #expect(log.files[1] == block(3, 0.002) + block(1, 0.5))
    }

    @Test func silenceHeldAcrossBlocksIsWrittenWhenSoundReturns() {
        var gate = SilenceGate(settings: settings, enabled: true)
        var log = FileLog()
        run(&gate, &log, block(2, 0.5))
        run(&gate, &log, block(7, 0))
        run(&gate, &log, block(8, 0))  // 15 silent frames < hold, split over two blocks
        run(&gate, &log, block(1, 0.5))
        gate.finish(into: &log)
        #expect(log.files.count == 1)
        #expect(log.files[0] == block(2, 0.5) + block(15, 0) + block(1, 0.5))
    }

    @Test func recordingIncludesHelpersButNotOtherApps() {
        #expect(RecordingMatch.belongs(processBundleID: "com.brave.Browser", toApp: "com.brave.Browser"))
        #expect(RecordingMatch.belongs(processBundleID: "com.brave.Browser.helper", toApp: "com.brave.browser"))
        #expect(RecordingMatch.belongs(processBundleID: "com.google.Chrome.helper.renderer", toApp: "com.google.Chrome"))
        #expect(!RecordingMatch.belongs(processBundleID: "com.google.Chrome.canary", toApp: "com.google.Chrome"))
        #expect(!RecordingMatch.belongs(processBundleID: "com.google.Chrome.canary.helper", toApp: "com.google.Chrome"))
        #expect(!RecordingMatch.belongs(processBundleID: "com.spotify.client2", toApp: "com.spotify.client"))
    }

    @Test func soundInTheMiddleOfABlockOpensAtTheRightPlace() {
        var gate = SilenceGate(settings: settings, enabled: true)
        var log = FileLog()
        run(&gate, &log, block(5, 0) + block(2, 0.5) + block(25, 0) + block(1, 0.4))
        gate.finish(into: &log)
        #expect(log.files.count == 2)
        #expect(log.files[0] == block(3, 0) + block(2, 0.5) + block(5, 0))
        #expect(log.files[1] == block(3, 0) + block(1, 0.4))
    }

    @Test func standardSettingsMatchTheDesign() {
        let standard = SilenceGate.Settings.standard(sampleRate: 48_000)
        #expect(standard.holdFrames == 96_000)
        #expect(standard.preRollFrames == 24_000)
        #expect(standard.tailFrames == 24_000)
        #expect(abs(Double(standard.threshold) - 0.001) < 1e-6)
    }

    // MARK: WAV

    @Test func headerDescribes24BitStereoPCM() {
        let header = WAVWriter.header(sampleRate: 44_100, dataBytes: 600)
        #expect(header.count == 44)
        #expect(String(decoding: header[0..<4], as: UTF8.self) == "RIFF")
        func u32(_ at: Int) -> UInt32 { header[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        func u16(_ at: Int) -> UInt16 { UInt16(header[at]) | UInt16(header[at + 1]) << 8 }
        #expect(u32(4) == 636)
        #expect(u16(20) == 1 && u16(22) == 2)
        #expect(u32(24) == 44_100 && u32(28) == 44_100 * 6)
        #expect(u16(32) == 6 && u16(34) == 24)
        #expect(String(decoding: header[36..<40], as: UTF8.self) == "data")
        #expect(u32(40) == 600)
    }

    @Test func pack24RoundsAndClips() {
        let samples: [Float] = [0, 1, -1, 2, .nan, 0.5]
        var bytes = [UInt8](repeating: 0, count: samples.count * 3)
        samples.withUnsafeBufferPointer { s in bytes.withUnsafeMutableBufferPointer { WAVWriter.pack24(s, into: $0.baseAddress!) } }
        func value(_ i: Int) -> Int32 { Int32(bitPattern: UInt32(bytes[i * 3]) | UInt32(bytes[i * 3 + 1]) << 8 | UInt32(bytes[i * 3 + 2]) << 16 | (bytes[i * 3 + 2] & 0x80 != 0 ? 0xFF00_0000 : 0)) }
        #expect(value(0) == 0)
        #expect(value(1) == 8_388_607)
        #expect(value(2) == -8_388_607)
        #expect(value(3) == 8_388_607)
        #expect(value(4) == 0)
        #expect(value(5) == 4_194_304)
    }

    @Test func writerProducesAFileWithCorrectSizes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roomeq-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url, sampleRate: 48_000)
        try block(100, 0.25).withUnsafeBufferPointer { try writer.append($0) }
        try writer.appendSilence(frames: 10)
        #expect(writer.frames == 110)
        try writer.close()
        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + 110 * 6)
        #expect(data[40..<44].elementsEqual(withUnsafeBytes(of: UInt32(660).littleEndian) { Array($0) }))
        #expect(throws: (any Error).self) { _ = try WAVWriter(url: url, sampleRate: 48_000) }
    }

    // MARK: Names

    @Test func fileNamesUseTheAppAndTheStartTime() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_795_000_512)  // 2026-11-18 ... UTC
        let name = RecordingNames.fileName(app: "Spotify", date: date, timeZone: utc)
        #expect(name.hasPrefix("Spotify 2026-11-"))
        #expect(name.hasSuffix(".wav"))
        #expect(RecordingNames.fileName(app: "AC/DC: Live", date: date, timeZone: utc).hasPrefix("AC-DC- Live "))
        let folder = URL(fileURLWithPath: "/tmp/x")
        var taken: Set<String> = [name, String(name.dropLast(4)) + " 2.wav"]
        let url = RecordingNames.uniqueURL(in: folder, app: "Spotify", date: date, timeZone: utc) { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == String(name.dropLast(4)) + " 3.wav")
        #expect(RecordingNames.fileName(app: "..Hidden", date: date, timeZone: utc).hasPrefix("Hidden "))
        #expect(RecordingNames.fileName(app: ". .x", date: date, timeZone: utc).hasPrefix("x "))
        #expect(RecordingNames.fileName(app: String(repeating: "x", count: 300), date: date, timeZone: utc).count < 110)
    }

    /// 80 characters of Japanese are 240 bytes: the name is cut by bytes too,
    /// at a whole character, so the file can always be created.
    @Test func longNamesFitTheFileNameLimitInBytes() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_795_000_512)
        let name = RecordingNames.fileName(app: String(repeating: "録", count: 100), date: date, timeZone: utc)
        #expect(name.utf8.count <= 150 + " 2026-11-18 00.00.00 99.wav".utf8.count)
        #expect(name.hasPrefix("録録録"))
        #expect(!name.contains("\u{FFFD}"))
        let emoji = RecordingNames.fileName(app: String(repeating: "👩‍👩‍👧", count: 40), date: date, timeZone: utc)
        #expect(emoji.utf8.count <= 255)
    }
}
