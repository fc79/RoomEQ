// Per-app recording: one WAV file per chosen app, the apps' own sound before
// RoomEQ's correction.
//
// For each app a private, UNMUTED process tap includes that app's processes
// (matched by bundle ID prefix, so browser helpers such as
// "com.brave.Browser.helper" are found) on the same output stream the
// correction uses: the device's own rate and channels, no mixdown, no
// sample-rate conversion. All taps sit in ONE private aggregate, so the files
// share one clock and stay aligned. The aggregate is separate from the
// correction's: recording works with the correction on, off or paused, and
// adds nothing to its path.
//
// Threads:
//   - the IOProc (real time) only copies the chosen stereo pair of each tap
//     into that app's `RecordingRing`;
//   - `queue` (serial) does everything else: building and tearing down the
//     taps, and every 50 ms draining the rings through the silence gates into
//     the WAV files (header refreshed about once a second).
// The output device can change while recording: the taps are rebuilt on the
// new device; at the same sample rate the files continue, at a different one
// they are closed and new files start (never converted).

import CoreAudio
import Foundation
import RoomEQCore
import Synchronization

final class RecordingSession: @unchecked Sendable {
    struct Target: Equatable, Sendable {
        let bundleID: String
        let name: String
    }

    struct AppStatus: Equatable, Sendable {
        let name: String
        /// Peak since the previous snapshot (linear).
        let peak: Float
        /// "Skip silence" is waiting for the app to play.
        let isPaused: Bool
    }

    struct Snapshot: Equatable, Sendable {
        var started = Date()
        var apps: [AppStatus] = []
        var sampleRate: Double = 0
        var deviceName = ""
        /// Frames lost because the writer fell behind (replaced by silence).
        var droppedFrames = 0
        /// Files written so far (open and closed), in creation order.
        var files: [URL] = []
        /// Approximate recording time left on the disk, in seconds.
        var secondsLeftOnDisk: Double?
        /// Set when the session stopped by itself (write error, full disk).
        var failure: String?
        var isRunning = false
    }

    let targets: [Target]
    let folder: URL
    let skipSilence: Bool

    private let queue = DispatchQueue(label: "com.federicociapi.RoomEQ.recording", qos: .userInitiated)
    private let state = Mutex(Snapshot())
    private var tracks: [Track] = []
    private var capture: Capture?
    private var timer: DispatchSourceTimer?
    private var ticks = 0

    init(targets: [Target], folder: URL, skipSilence: Bool) {
        self.targets = targets
        self.folder = folder
        self.skipSilence = skipSilence
    }

    deinit { if capture != nil { Log.engine.fault("RecordingSession released while running") } }

    var snapshot: Snapshot { state.withLock { $0 } }

    // MARK: - Control (any thread; work happens on `queue`)

    /// Starts on `device`. Throws without leaving anything behind.
    func start(device: AudioObjectID) throws {
        try queue.sync {
            guard !targets.isEmpty else { throw EngineError("Nessuna app da registrare.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let capture = try Capture.make(targets: targets, device: device)
            tracks = targets.map { Track(target: $0, folder: folder, sampleRate: capture.sampleRate, skipSilence: skipSilence) }
            do {
                try capture.start(rings: tracks.map(\.ring))
            } catch {
                capture.destroy()
                tracks = []
                throw error
            }
            self.capture = capture
            state.withLock {
                $0 = Snapshot(started: Date(), sampleRate: capture.sampleRate, deviceName: capture.deviceName, isRunning: true)
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            Log.engine.info(
                "Recording started on \(capture.deviceName, privacy: .public) at \(capture.sampleRate) Hz: \(self.targets.map(\.bundleID), privacy: .public)")
        }
    }

    /// Stops and closes every file. Safe to call more than once.
    func stop() {
        queue.sync { finish(failure: nil) }
    }

    /// Moves the taps to a new output device (called when the macOS output
    /// changes). Same rate: the files continue. Other rate: new files.
    func switchDevice(to device: AudioObjectID) {
        queue.async { [self] in
            guard let old = capture else { return }
            guard AudioDevices.uid(of: device) != old.deviceUID else { return }
            old.destroy()
            capture = nil
            drain()
            do {
                let new = try Capture.make(targets: targets, device: device)
                if new.sampleRate != old.sampleRate {
                    for track in tracks { track.restart(sampleRate: new.sampleRate) }
                }
                try new.start(rings: tracks.map(\.ring))
                capture = new
                state.withLock {
                    $0.sampleRate = new.sampleRate
                    $0.deviceName = new.deviceName
                }
                Log.engine.info("Recording moved to \(new.deviceName, privacy: .public) at \(new.sampleRate) Hz")
            } catch {
                Log.engine.error("Recording could not follow the output change: \(error.localizedDescription, privacy: .public)")
                finish(failure: String(localized: "Registrazione fermata: non riesce a seguire la nuova uscita audio (\(error.localizedDescription)). I file salvati sono completi."))
            }
        }
    }

    /// Re-reads the running processes of each app (a browser may start a new
    /// helper process while recording).
    func refreshProcesses() {
        queue.async { [self] in capture?.refreshProcesses() }
    }

    // MARK: - Writer (queue)

    private func tick() {
        drain()
        ticks += 1
        if ticks % 20 == 0 {  // about once a second
            for track in tracks { track.updateHeader() }
            if let failure = tracks.lazy.compactMap(\.failure).first {
                finish(failure: failure)
                return
            }
            checkDisk()
        }
    }

    private func drain() {
        var apps: [AppStatus] = []
        var dropped = 0
        for track in tracks {
            dropped += track.drain()
            apps.append(AppStatus(name: track.target.name, peak: track.ring.takePeak(), isPaused: track.isPaused))
        }
        let files = tracks.flatMap(\.files).sorted { $0.created < $1.created }.map(\.url)
        state.withLock {
            $0.apps = apps
            $0.droppedFrames += dropped
            $0.files = files
        }
    }

    private func checkDisk() {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, let capture else { return }
        let bytesPerSecond = capture.sampleRate * Double(WAVWriter.channels * WAVWriter.bytesPerSample) * Double(tracks.count)
        let seconds = Double(free) / max(bytesPerSecond, 1)
        state.withLock { $0.secondsLeftOnDisk = seconds }
        if free < 50_000_000 {
            finish(failure: String(localized: "Registrazione fermata: il disco è pieno. I file salvati sono completi."))
        }
    }

    private func finish(failure: String?) {
        timer?.cancel()
        timer = nil
        capture?.destroy()
        capture = nil
        drain()
        for track in tracks { track.close() }
        let files = tracks.flatMap(\.files).sorted { $0.created < $1.created }.map(\.url)
        tracks = []
        state.withLock {
            $0.isRunning = false
            $0.files = files
            if let failure { $0.failure = failure }
        }
        Log.engine.info("Recording stopped: \(files.count) files\(failure.map { ", \($0)" } ?? "", privacy: .public)")
    }
}

// MARK: - One app

/// One app's ring, silence gate and files. Used on the session queue only.
private final class Track {
    let target: RecordingSession.Target
    let ring: RecordingRing
    private let folder: URL
    private let skipSilence: Bool
    private var gate: SilenceGate
    private var sink: FileSink
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 4096
    private var silence: [Float] = []

    init(target: RecordingSession.Target, folder: URL, sampleRate: Double, skipSilence: Bool) {
        self.target = target
        self.folder = folder
        self.skipSilence = skipSilence
        // Two seconds of headroom for the writer.
        ring = RecordingRing(minimumFrames: Int(sampleRate * 2))
        gate = SilenceGate(settings: .standard(sampleRate: sampleRate), enabled: skipSilence)
        sink = FileSink(folder: folder, appName: target.name, sampleRate: Int(sampleRate.rounded()))
        scratch = .allocate(capacity: scratchFrames * 2)
    }

    deinit { scratch.deallocate() }

    var isPaused: Bool { gate.isPaused }
    var files: [FileSink.File] { sink.files }
    var failure: String? { sink.failure }

    /// Moves everything in the ring to the files. Returns dropped frames.
    func drain() -> Int {
        while true {
            let count = ring.read(into: scratch, maxFrames: scratchFrames)
            if count == 0 { break }
            gate.process(UnsafeBufferPointer(start: scratch, count: count * 2), into: &sink)
        }
        let dropped = ring.takeDroppedFrames()
        if dropped > 0 {
            // Keep the length (and the alignment with the other apps).
            if silence.count < dropped * 2 { silence = [Float](repeating: 0, count: dropped * 2) }
            silence.withUnsafeBufferPointer {
                gate.process(UnsafeBufferPointer(rebasing: $0[0..<(dropped * 2)]), into: &sink)
            }
            Log.engine.error("Recording \(self.target.bundleID, privacy: .public): \(dropped) frames dropped")
        }
        return dropped
    }

    /// Closes the current file and continues at a new sample rate.
    func restart(sampleRate: Double) {
        gate.finish(into: &sink)
        gate = SilenceGate(settings: .standard(sampleRate: sampleRate), enabled: skipSilence)
        sink.sampleRate = Int(sampleRate.rounded())
    }

    func updateHeader() { sink.updateHeader() }

    func close() { gate.finish(into: &sink) }
}

/// Opens, fills and closes the WAV files of one app (the silence gate's sink).
private final class FileSink: RecordingSink {
    struct File {
        let url: URL
        let created: Date
    }

    let folder: URL
    let appName: String
    var sampleRate: Int
    private(set) var files: [File] = []
    private(set) var failure: String?
    private var writer: WAVWriter?

    init(folder: URL, appName: String, sampleRate: Int) {
        self.folder = folder
        self.appName = appName
        self.sampleRate = sampleRate
    }

    func open() {
        guard failure == nil else { return }
        let now = Date()
        let url = RecordingNames.uniqueURL(in: folder, app: appName, date: now)
        do {
            writer = try WAVWriter(url: url, sampleRate: sampleRate)
            files.append(File(url: url, created: now))
            Log.engine.info("Recording file opened: \(url.lastPathComponent, privacy: .public)")
        } catch {
            fail(error)
        }
    }

    func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let writer else { return }
        do {
            if !writer.canAppend(frames: samples.count / 2) {
                // RIFF limit (about 4 hours of stereo at 48 kHz): next file.
                close()
                open()
                guard let next = self.writer else { return }
                try next.append(samples)
                return
            }
            try writer.append(samples)
        } catch {
            fail(error)
        }
    }

    func close() {
        guard let writer else { return }
        self.writer = nil
        do { try writer.close() } catch { fail(error) }
    }

    func updateHeader() {
        guard let writer else { return }
        do { try writer.updateHeader() } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        Log.engine.error("Recording file error (\(self.appName, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        if failure == nil {
            failure = String(localized: "Registrazione fermata: errore nel salvare il file di «\(appName)» (\(error.localizedDescription)).")
        }
        writer = nil
    }
}

// MARK: - Taps, aggregate and IOProc on one device

private final class Capture {
    let deviceID: AudioObjectID
    let deviceUID: String
    let deviceName: String
    let sampleRate: Double
    private let source: TapSource
    private let channelCount: Int
    private let targets: [RecordingSession.Target]
    private var taps: [(id: AudioObjectID, uuid: UUID, processes: [AudioObjectID])] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var started = false

    private init(
        deviceID: AudioObjectID, deviceUID: String, deviceName: String, sampleRate: Double, source: TapSource,
        channelCount: Int, targets: [RecordingSession.Target]
    ) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.sampleRate = sampleRate
        self.source = source
        self.channelCount = channelCount
        self.targets = targets
    }

    /// Builds the taps and the aggregate (not started). Throws after cleaning up.
    static func make(targets: [RecordingSession.Target], device: AudioObjectID) throws -> Capture {
        guard let uid = AudioDevices.uid(of: device) else {
            throw EngineError("Uscita audio non disponibile per la registrazione.")
        }
        let streams = try DeviceStreams.streams(of: device, scope: kAudioObjectPropertyScopeOutput)
        let counts = streams.map { Int($0.format.mChannelsPerFrame) }
        let source: TapSource
        switch TapSourceSelection.locate(preferred: AudioDevices.preferredStereoChannels(of: device), streamChannelCounts: counts) {
        case .success(let located): source = located
        case .failure(let error): throw EngineError(message: error.message)
        }
        let capture = Capture(
            deviceID: device, deviceUID: uid, deviceName: AudioDevices.name(of: device),
            sampleRate: try AudioDevices.nominalSampleRate(of: device), source: source,
            channelCount: counts[source.stream], targets: targets)
        do {
            try capture.build()
        } catch {
            capture.destroy()
            throw error
        }
        return capture
    }

    private func build() throws {
        for target in targets {
            let processes = AudioProcesses.processObjects(matching: [target.bundleID]).map(\.object)
            let uuid = UUID()
            let description = Self.description(target: target, uuid: uuid, deviceUID: deviceUID, stream: source.stream, processes: processes)
            var tapID = AudioObjectID(kAudioObjectUnknown)
            try AudioObject.check(AudioHardwareCreateProcessTap(description, &tapID), "Creazione del tap di registrazione")
            taps.append((tapID, uuid, processes))
            let format: AudioStreamBasicDescription = try AudioObject.read(
                tapID, AudioObject.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription(),
                "Lettura formato del tap")
            guard format.isFloat32, Int(format.mChannelsPerFrame) == channelCount, format.mSampleRate == sampleRate else {
                throw EngineError("Il formato della registrazione non coincide con quello dell'uscita: registrazione annullata per non convertire l'audio.")
            }
            Log.engine.info(
                "Recording tap \(tapID) for \(target.bundleID, privacy: .public): processes \(processes, privacy: .public), \(format.logDescription, privacy: .public)")
        }
        let tapList: [[String: Any]] = try taps.map { tap in
            let uid = try AudioObject.readString(tap.id, AudioObject.address(kAudioTapPropertyUID), "Lettura UID del tap")
            return [kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: 0]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "RoomEQ Recording",
            kAudioAggregateDeviceUIDKey: "\(AudioDevices.ownAggregateUIDPrefix).recording.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        try AudioObject.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "Creazione dell'aggregato di registrazione")

        // One input stream per tap, in tap order, each with the device's channels.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        var inputs: [StreamInfo] = []
        while clock.now < deadline {
            inputs = (try? DeviceStreams.streams(of: aggregateID, scope: kAudioObjectPropertyScopeInput)) ?? []
            if inputs.count == taps.count { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard inputs.count == taps.count,
            inputs.allSatisfy({ $0.format.isFloat32 && Int($0.format.mChannelsPerFrame) == channelCount && !$0.format.isNonInterleaved })
        else {
            throw EngineError("Gli stream della registrazione non sono comparsi come previsto: registrazione annullata.")
        }
        let rate = try AudioDevices.nominalSampleRate(of: aggregateID)
        guard rate == sampleRate else {
            throw EngineError("Il formato della registrazione non coincide con quello dell'uscita: registrazione annullata per non convertire l'audio.")
        }
    }

    private static func description(
        target: RecordingSession.Target, uuid: UUID, deviceUID: String, stream: Int, processes: [AudioObjectID]
    ) -> CATapDescription {
        // Mix of these processes' audio for one output stream (not exclusive):
        // that stream's format, no mixdown, no conversion. Unmuted: recording
        // never changes what the user hears.
        let description = CATapDescription(processes: processes, deviceUID: deviceUID, stream: UInt(stream))
        description.isMixdown = false
        description.isMono = false
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "RoomEQ Recording \(target.bundleID)"
        description.uuid = uuid
        if #available(macOS 26.0, *) {
            // Also catches the app's main process when it starts later. Helper
            // processes with other bundle IDs come from the process list.
            description.bundleIDs = [target.bundleID]
            description.isProcessRestoreEnabled = true
        }
        return description
    }

    /// Starts the IOProc that copies each tap's stereo pair into its ring.
    func start(rings: [RecordingRing]) throws {
        let rings = ContiguousArray(rings)
        let channels = channelCount
        let left = source.left
        let right = source.right
        try AudioObject.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let count = min(list.count, rings.count)
                for index in 0..<count {
                    let buffer = list[index]
                    guard let data = buffer.mData, Int(buffer.mNumberChannels) == channels else { continue }
                    let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                    rings[index].write(
                        interleaved: data.assumingMemoryBound(to: Float.self), frames: frames, channelCount: channels,
                        left: left, right: right)
                }
            }, "Creazione della callback di registrazione")
        guard let procID else { throw EngineError("Creazione delle callback: ID mancante") }
        try AudioObject.check(AudioDeviceStart(aggregateID, procID), "Avvio della registrazione")
        started = true
    }

    /// Adds newly started processes of each app (e.g. a new browser helper).
    func refreshProcesses() {
        for index in taps.indices {
            let processes = AudioProcesses.processObjects(matching: [targets[index].bundleID]).map(\.object)
            guard Set(processes) != Set(taps[index].processes) else { continue }
            var description = Self.description(
                target: targets[index], uuid: taps[index].uuid, deviceUID: deviceUID, stream: source.stream,
                processes: processes)
            var address = AudioObject.address(kAudioTapPropertyDescription)
            let status = withUnsafeMutablePointer(to: &description) {
                AudioObjectSetPropertyData(taps[index].id, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
            if status == noErr {
                taps[index].processes = processes
                Log.engine.info("Recording tap for \(self.targets[index].bundleID, privacy: .public): processes now \(processes, privacy: .public)")
            } else {
                Log.engine.error("Recording tap update failed: \(describeOSStatus(status), privacy: .public)")
            }
        }
    }

    func destroy() {
        if let procID {
            if started { AudioDeviceStop(aggregateID, procID) }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        started = false
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        for tap in taps { AudioHardwareDestroyProcessTap(tap.id) }
        taps = []
    }
}
