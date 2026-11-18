// Per-app recording: one WAV file per chosen app, the apps' own sound before
// RoomEQ's correction.
//
// For each app a private, UNMUTED process tap includes that app's processes
// (the app itself and its helper processes, see `RecordingMatch`) on the
// same output stream the correction uses: the device's own rate and
// channels, no mixdown, no sample-rate conversion. Each tap has its own
// private aggregate and IOProc (one tap per aggregate, so there is no doubt
// about which stream belongs to which app); all taps run on the output
// device's clock, so the files stay aligned within a few milliseconds. The
// aggregates are separate from the correction's: recording works with the
// correction on, off or paused, and adds nothing to its path.
//
// Threads:
//   - each IOProc (real time) only copies its tap's chosen stereo pair into
//     that app's `RecordingRing` (no allocation, lock or ARC traffic);
//   - `queue` (serial) does everything else: building and tearing down the
//     taps, and every 50 ms draining the rings through the silence gates into
//     the WAV files (header refreshed every second, data flushed to disk
//     every 10 seconds);
//   - Core Audio listeners run on `listenerQueue` and only hop to `queue`.
// The main thread never waits for `queue`, except `stopAndWait` at quit
// (bounded).
//
// The recording follows the output: a new default output device, or a new
// sample rate or stream layout on the same device, rebuilds the taps. At the
// same sample rate the files continue; at another one they are closed and new
// files start (never converted). If the new output is not ready yet, it is
// retried every second for 30 seconds before the recording stops.

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
        let bundleID: String
        let name: String
        /// Highest peak since the previous `takeSnapshot()` (linear).
        var peak: Float
        /// "Skip silence" is waiting for the app to play.
        var isPaused: Bool
    }

    struct Snapshot: Equatable, Sendable {
        var started = Date()
        var apps: [AppStatus] = []
        var sampleRate: Double = 0
        var deviceName = ""
        /// Frames lost (the writer fell behind, or a buffer came in an
        /// unexpected layout), replaced by silence.
        var droppedFrames = 0
        /// Files written so far (open and closed), in creation order.
        var files: [URL] = []
        /// Approximate recording time left on the disk, in seconds.
        var secondsLeftOnDisk: Double?
        /// Set when the session stopped by itself (write error, full disk,
        /// output not followed).
        var failure: String?
        var isRunning = false
        /// The output can't be captured right now; retrying.
        var isWaitingForOutput = false
    }

    let targets: [Target]
    let folder: URL
    let skipSilence: Bool

    private let queue = DispatchQueue(label: "com.federicociapi.RoomEQ.recording", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "com.federicociapi.RoomEQ.recording.device")
    private let state = Mutex(Snapshot())

    // Confined to `queue`.
    private var tracks: [Track] = []
    private var capture: Capture?
    private var deviceListeners: [PropertyListener] = []
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var finished = false
    /// A process-list refresh is already scheduled (notifications come in
    /// bursts when a browser starts or ends helpers).
    private var processRefreshScheduled = false
    /// The sample rate of the files being written.
    private var fileRate: Double = 0
    /// Set by stop/stopAndWait from any thread: a (re)build in progress gives up.
    private let cancelling = Atomic<Bool>(false)
    /// While the output can't be captured: retry until this moment.
    private var retryDeadline: ContinuousClock.Instant?
    /// Invalidates scheduled retries and debounced rebuilds.
    private var generation = 0

    init(targets: [Target], folder: URL, skipSilence: Bool) {
        self.targets = targets
        self.folder = folder
        self.skipSilence = skipSilence
    }

    deinit { if capture != nil { Log.engine.fault("RecordingSession released while running") } }

    /// The current state; the peaks start again from zero after each call.
    func takeSnapshot() -> Snapshot {
        state.withLock { current in
            let copy = current
            for index in current.apps.indices { current.apps[index].peak = 0 }
            return copy
        }
    }

    // MARK: - Control (any thread)

    /// Starts on `device`; `completion` runs on the main queue with nil or
    /// the reason it could not start (nothing is left behind then).
    func start(device: AudioObjectID, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            let result: Error?
            do {
                try begin(device: device)
                result = nil
            } catch {
                result = error
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stops and closes every file; `completion` runs on the main queue with
    /// the final state.
    func stop(completion: @escaping @Sendable (Snapshot) -> Void) {
        cancelling.store(true, ordering: .relaxed)  // cut a slow (re)build short
        queue.async { [self] in
            finish(failure: nil)
            let snapshot = takeSnapshot()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// For quitting: stops and waits at most `timeout` for the files to be
    /// closed. A (re)build in progress is cut short so this normally returns
    /// well within the timeout.
    func stopAndWait(timeout: TimeInterval) {
        cancelling.store(true, ordering: .relaxed)
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            finish(failure: nil)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            Log.engine.error("Recording did not stop within \(timeout) s at quit")
        }
    }

    /// The default output changed: follow it.
    func outputChanged() {
        queue.async { [self] in follow() }
    }

    /// Re-reads the running processes of each app (a browser may start a new
    /// helper process while recording).
    func refreshProcesses() {
        queue.async { [self] in
            guard !processRefreshScheduled else { return }
            processRefreshScheduled = true
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                processRefreshScheduled = false
                capture?.refreshProcesses()
            }
        }
    }

    // MARK: - Lifecycle (queue)

    private func begin(device: AudioObjectID) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !targets.isEmpty else { throw EngineError("Nessuna app da registrare.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let capture = try Capture.make(targets: targets, device: device, cancelling: cancelling)
        tracks = targets.map { Track(target: $0, folder: folder, sampleRate: capture.sampleRate, skipSilence: skipSilence) }
        do {
            try capture.start(rings: tracks.map(\.ring))
        } catch {
            capture.destroy()
            tracks = []
            throw error
        }
        self.capture = capture
        fileRate = capture.sampleRate
        listen(to: capture, owner: generation)
        state.withLock {
            $0 = Snapshot(
                started: Date(),
                apps: targets.map { AppStatus(bundleID: $0.bundleID, name: $0.name, peak: 0, isPaused: skipSilence) },
                sampleRate: capture.sampleRate, deviceName: capture.deviceName, isRunning: true)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        Log.engine.info(
            "Recording started on \(capture.deviceName, privacy: .public) at \(capture.sampleRate) Hz: \(self.targets.map(\.bundleID), privacy: .public)")
        // The output may have changed while starting.
        follow()
    }

    /// Makes the taps match the current default output: rebuilds them when
    /// the device (object), its sample rate or its stream layout differ from
    /// the running capture, or when there is none. Does nothing otherwise, so
    /// repeated notifications cost nothing.
    private func follow() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, timer != nil else { return }
        if let capture, retryDeadline == nil, let device = AudioDevices.defaultOutputDeviceID(),
            capture.matches(device: device)
        {
            return
        }
        generation += 1
        // A retry window already running keeps its deadline.
        stopCapture()
        attemptCapture(generation: generation)
    }

    /// Tries to capture the current default output; while it can't (no
    /// output, not ready, unsupported layout) retries every second for 30
    /// seconds, then stops the recording with a message.
    private func attemptCapture(generation attempt: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, attempt == generation else { return }
        var new: Capture?
        do {
            guard let device = AudioDevices.defaultOutputDeviceID() else {
                throw EngineError("Uscita audio non disponibile per la registrazione.")
            }
            let made = try Capture.make(targets: targets, device: device, cancelling: cancelling)
            new = made
            try made.start(rings: tracks.map(\.ring))
            // New files only once the new rate is really recording (a failed
            // attempt, then a return to the old rate, keeps the files whole).
            // What the IOProcs already wrote is still in the rings: it goes
            // to the new files at the next drain.
            if !SampleRates.same(made.sampleRate, fileRate) {
                for track in tracks { track.restart(sampleRate: made.sampleRate) }
                fileRate = made.sampleRate
            }
            capture = made
            retryDeadline = nil
            listen(to: made, owner: generation)
            state.withLock {
                $0.sampleRate = made.sampleRate
                $0.deviceName = made.deviceName
                $0.isWaitingForOutput = false
            }
            Log.engine.info("Recording now on \(made.deviceName, privacy: .public) at \(made.sampleRate) Hz")
        } catch {
            if let new {
                // What a half-started attempt wrote (maybe at another rate)
                // must not reach the files.
                let leaked = new.destroy()
                for track in tracks { track.ring.discardAll() }
                replaceRings(leaked)
            }
            if finished || cancelling.load(ordering: .relaxed) { return }
            let clock = ContinuousClock()
            let deadline = retryDeadline ?? clock.now + .seconds(30)
            retryDeadline = deadline
            state.withLock { $0.isWaitingForOutput = true }
            if clock.now < deadline {
                Log.engine.notice("Recording can't use the output yet, retrying: \(error.localizedDescription, privacy: .public)")
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attemptCapture(generation: attempt) }
            } else {
                Log.engine.error("Recording could not follow the output: \(error.localizedDescription, privacy: .public)")
                finish(failure: String(localized: "Registrazione fermata: non riesce a seguire la nuova uscita audio (\(error.localizedDescription)). I file salvati sono completi."))
            }
        }
    }

    /// Stops the taps (the files stay open).
    private func stopCapture() {
        for listener in deviceListeners { listener.remove() }
        deviceListeners = []
        let leaked = capture?.destroy() ?? []
        capture = nil
        drain()
        replaceRings(leaked)
    }

    /// Tracks whose ring an IOProc that could not be stopped may still write
    /// to get a fresh one, so the next capture is never a second producer.
    private func replaceRings(_ leaked: Set<ObjectIdentifier>) {
        guard !leaked.isEmpty else { return }
        for track in tracks where leaked.contains(ObjectIdentifier(track.ring)) { track.replaceRing() }
    }

    /// A new rate or stream layout on the current device, a tap format change,
    /// or the device going away: check again (debounced, changes come in
    /// bursts). Notifications of an older capture (`owner` no longer the
    /// current generation) are ignored, even when they arrive late.
    private func listen(to capture: Capture, owner: Int) {
        let changed: () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard owner == self.generation else { return }
                self.queue.asyncAfter(deadline: .now() + 0.2) {
                    guard owner == self.generation else { return }
                    self.follow()
                }
            }
        }
        var addresses: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (capture.deviceID, AudioObject.address(kAudioDevicePropertyNominalSampleRate)),
            (capture.deviceID, AudioObject.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)),
            (capture.deviceID, AudioObject.address(kAudioDevicePropertyDeviceIsAlive)),
        ]
        for tap in capture.tapIDs { addresses.append((tap, AudioObject.address(kAudioTapPropertyFormat))) }
        for (object, address) in addresses {
            do {
                deviceListeners.append(try PropertyListener(object: object, address: address, queue: listenerQueue, handler: changed))
            } catch {
                Log.engine.error("Recording listener: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func finish(failure: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }
        finished = true
        generation += 1
        timer?.cancel()
        timer = nil
        stopCapture()
        var failure = failure
        for track in tracks {
            track.close()
            if failure == nil, let trackFailure = track.failure { failure = trackFailure }
        }
        let files = allFiles()
        tracks = []
        state.withLock {
            $0.isRunning = false
            $0.files = files
            if let failure { $0.failure = failure }
            for index in $0.apps.indices { $0.apps[index].isPaused = false }
        }
        Log.engine.info("Recording stopped: \(files.count) files\(failure.map { ", \($0)" } ?? "", privacy: .public)")
    }

    // MARK: - Writer (queue)

    private func tick() {
        dispatchPrecondition(condition: .onQueue(queue))
        drain()
        ticks += 1
        if ticks % 20 == 0 {  // every second
            for track in tracks { track.updateHeader(flushToDisk: ticks % 200 == 0) }
            if let failure = tracks.lazy.compactMap(\.failure).first {
                finish(failure: failure)
                return
            }
            checkDisk()
        }
    }

    private func drain() {
        var dropped = 0
        var peaks: [Float] = []
        var paused: [Bool] = []
        for track in tracks {
            dropped += track.drain()
            peaks.append(track.ring.takePeak())
            paused.append(track.isPaused)
        }
        let files = allFiles()
        state.withLock {
            for index in $0.apps.indices where index < peaks.count {
                $0.apps[index].peak = max($0.apps[index].peak, peaks[index])
                $0.apps[index].isPaused = paused[index]
            }
            $0.droppedFrames += dropped
            $0.files = files
        }
    }

    private func allFiles() -> [URL] {
        tracks.flatMap(\.files).sorted { $0.created < $1.created }.map(\.url)
    }

    private func checkDisk() {
        var url = folder
        url.removeAllCachedResourceValues()  // fresh value every time
        guard let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, free > 0
        else { return }  // 0 or missing: unknown on some volumes
        let bytesPerSecond = fileRate * Double(WAVWriter.channels * WAVWriter.bytesPerSample) * Double(tracks.count)
        state.withLock { $0.secondsLeftOnDisk = Double(free) / max(bytesPerSecond, 1) }
        if free < 50_000_000 {
            finish(failure: String(localized: "Registrazione fermata: il disco è pieno. I file salvati sono completi."))
        }
    }
}

// MARK: - One app

/// One app's ring, silence gate and files. Used on the session queue only.
private final class Track {
    let target: RecordingSession.Target
    private(set) var ring: RecordingRing
    private let skipSilence: Bool
    private var gate: SilenceGate
    private var sink: FileSink
    private let scratch: UnsafeMutablePointer<Float>
    private let zeros: UnsafeMutablePointer<Float>
    private let scratchFrames = 4096

    init(target: RecordingSession.Target, folder: URL, sampleRate: Double, skipSilence: Bool) {
        self.target = target
        self.skipSilence = skipSilence
        // At least two seconds of headroom for the writer, also if the output
        // later moves to a higher rate (up to 192 kHz: 1 s).
        ring = RecordingRing(minimumFrames: Int(max(sampleRate, 96_000) * 2))
        gate = SilenceGate(settings: .standard(sampleRate: sampleRate), enabled: skipSilence)
        sink = FileSink(appName: target.name, folder: folder, sampleRate: Int(sampleRate.rounded()))
        scratch = .allocate(capacity: scratchFrames * 2)
        zeros = .allocate(capacity: scratchFrames * 2)
        zeros.initialize(repeating: 0, count: scratchFrames * 2)
    }

    deinit {
        scratch.deallocate()
        zeros.deallocate()
    }

    var isPaused: Bool { gate.isPaused }
    var files: [FileSink.File] { sink.files }
    var failure: String? { sink.failure }

    /// Moves everything in the ring to the files. Returns dropped frames.
    func drain() -> Int {
        let dropped = ring.drain(scratch: scratch, scratchFrames: scratchFrames) { chunk in
            switch chunk {
            case .audio(let samples):
                gate.process(samples, into: &sink)
            case .silence(let frames):
                // Silence of the same length, where the audio was lost, keeps
                // the file's duration (and its alignment with the other apps'
                // files).
                var left = frames
                while left > 0 {
                    let count = min(left, scratchFrames)
                    gate.process(UnsafeBufferPointer(start: zeros, count: count * 2), into: &sink)
                    left -= count
                }
            }
        }
        if dropped > 0 {
            Log.engine.error("Recording \(self.target.bundleID, privacy: .public): \(dropped) frames dropped")
        }
        let silenced = ring.takeSilencedFrames()
        if silenced > 0 {
            Log.engine.error(
                "Recording \(self.target.bundleID, privacy: .public): \(silenced) frames in an unexpected layout, recorded as silence")
        }
        return dropped + silenced  // both are reported as lost audio
    }

    /// A new, empty ring of the same size (the old one stays with an IOProc
    /// that could not be stopped, deliberately leaked by `Capture.destroy`).
    func replaceRing() {
        ring = RecordingRing(minimumFrames: ring.capacity)
    }

    /// Closes the current file and continues at a new sample rate.
    func restart(sampleRate: Double) {
        gate.finish(into: &sink)
        gate = SilenceGate(settings: .standard(sampleRate: sampleRate), enabled: skipSilence)
        sink.sampleRate = Int(sampleRate.rounded())
    }

    func updateHeader(flushToDisk: Bool) { sink.updateHeader(flushToDisk: flushToDisk) }

    func close() { gate.finish(into: &sink) }
}

/// Opens, fills and closes the WAV files of one app (the silence gate's sink).
private final class FileSink: RecordingSink {
    struct File {
        let url: URL
        let created: Date
    }

    let appName: String
    let folder: URL
    var sampleRate: Int
    private(set) var files: [File] = []
    private(set) var failure: String?
    private var writer: WAVWriter?

    init(appName: String, folder: URL, sampleRate: Int) {
        self.appName = appName
        self.folder = folder
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

    func updateHeader(flushToDisk: Bool) {
        guard let writer else { return }
        do {
            try writer.updateHeader()
            if flushToDisk { try writer.flushToDisk() }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        Log.engine.error("Recording file error (\(self.appName, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        if failure == nil {
            failure = String(localized: "Registrazione fermata: errore nel salvare il file di «\(appName)» (\(error.localizedDescription)).")
        }
        writer = nil
    }
}

// MARK: - Taps, aggregates and IOProcs on one device

private final class Capture {
    /// One app: its tap, its private aggregate and its IOProc.
    private struct Unit {
        let target: RecordingSession.Target
        let tapID: AudioObjectID
        let uuid: UUID
        var processes: [AudioObjectID]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var started = false
        /// The ring this unit's IOProc writes to (held unretained by it).
        var ring: RecordingRing?
    }

    let deviceID: AudioObjectID
    let deviceUID: String
    let deviceName: String
    let sampleRate: Double
    private let source: TapSource
    private let channelCount: Int
    private var units: [Unit] = []

    var tapIDs: [AudioObjectID] { units.map(\.tapID) }

    /// The capture still fits `device`: same object (a device unplugged and
    /// plugged back gets a new one), same rate, same stream layout, and every
    /// tap still delivers that format.
    func matches(device: AudioObjectID) -> Bool {
        guard device == deviceID, AudioDevices.isAlive(device),
            let rate = try? AudioDevices.nominalSampleRate(of: device), SampleRates.same(rate, sampleRate),
            let streams = try? DeviceStreams.streams(of: device, scope: kAudioObjectPropertyScopeOutput),
            source.stream < streams.count, Int(streams[source.stream].format.mChannelsPerFrame) == channelCount
        else { return false }
        for unit in units {
            guard
                let format: AudioStreamBasicDescription = try? AudioObject.read(
                    unit.tapID, AudioObject.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription(),
                    "Lettura formato del tap"),
                SampleRates.same(format.mSampleRate, sampleRate), Int(format.mChannelsPerFrame) == channelCount
            else { return false }
        }
        return true
    }

    private init(
        deviceID: AudioObjectID, deviceUID: String, deviceName: String, sampleRate: Double, source: TapSource,
        channelCount: Int
    ) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.sampleRate = sampleRate
        self.source = source
        self.channelCount = channelCount
    }

    /// Builds the taps and aggregates (not started). Throws after cleaning up.
    static func make(targets: [RecordingSession.Target], device: AudioObjectID, cancelling: borrowing Atomic<Bool>) throws -> Capture {
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
        let rate = try AudioDevices.nominalSampleRate(of: device)
        guard AudioFormatText.isKnownRate(rate) else {
            throw EngineError("Il formato della registrazione non coincide con quello dell'uscita: registrazione annullata per non convertire l'audio.")
        }
        let capture = Capture(
            deviceID: device, deviceUID: uid, deviceName: AudioDevices.name(of: device), sampleRate: rate,
            source: source, channelCount: counts[source.stream])
        do {
            for target in targets { try capture.addUnit(for: target, cancelling: cancelling) }
        } catch {
            capture.destroy()
            throw error
        }
        return capture
    }

    private func addUnit(for target: RecordingSession.Target, cancelling: borrowing Atomic<Bool>) throws {
        if cancelling.load(ordering: .relaxed) { throw CancellationError() }
        let processes = AudioProcesses.processObjects(ofApp: target.bundleID) ?? []
        let uuid = UUID()
        let description = Self.description(target: target, uuid: uuid, deviceUID: deviceUID, stream: source.stream, processes: processes)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        do {
            try AudioObject.check(AudioHardwareCreateProcessTap(description, &tapID), "Creazione del tap di registrazione")
        } catch {
            throw AudioCapturePermissionError.classify(error, tapCreation: true)
        }
        var unit = Unit(target: target, tapID: tapID, uuid: uuid, processes: processes)
        units.append(unit)
        let format: AudioStreamBasicDescription = try AudioObject.read(
            tapID, AudioObject.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription(),
            "Lettura formato del tap")
        guard format.isFloat32, Int(format.mChannelsPerFrame) == channelCount, SampleRates.same(format.mSampleRate, sampleRate)
        else {
            throw EngineError("Il formato della registrazione non coincide con quello dell'uscita: registrazione annullata per non convertire l'audio.")
        }
        let tapUID = try AudioObject.readString(tapID, AudioObject.address(kAudioTapPropertyUID), "Lettura UID del tap")
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "RoomEQ Recording",
            kAudioAggregateDeviceUIDKey: "\(AudioDevices.ownAggregateUIDPrefix).recording.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 0]],
        ]
        try AudioObject.check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &unit.aggregateID),
            "Creazione dell'aggregato di registrazione")
        units[units.count - 1] = unit

        // Exactly one input stream (the tap), in the device's format.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        var inputs: [StreamInfo] = []
        while clock.now < deadline {
            inputs = (try? DeviceStreams.streams(of: unit.aggregateID, scope: kAudioObjectPropertyScopeInput)) ?? []
            if inputs.count == 1 || cancelling.load(ordering: .relaxed) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard inputs.count == 1, inputs[0].format.isFloat32, Int(inputs[0].format.mChannelsPerFrame) == channelCount,
            !inputs[0].format.isNonInterleaved
        else {
            throw EngineError("Gli stream della registrazione non sono comparsi come previsto: registrazione annullata.")
        }
        let aggregateRate = try AudioDevices.nominalSampleRate(of: unit.aggregateID)
        guard SampleRates.same(aggregateRate, sampleRate) else {
            throw EngineError("Il formato della registrazione non coincide con quello dell'uscita: registrazione annullata per non convertire l'audio.")
        }
        Log.engine.info(
            "Recording tap \(tapID) for \(target.bundleID, privacy: .public): processes \(processes, privacy: .public), \(format.logDescription, privacy: .public), aggregate \(unit.aggregateID)")
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

    /// Starts one IOProc per app, each copying its tap's stereo pair into the
    /// app's ring (`rings` in the order of the targets).
    func start(rings: [RecordingRing]) throws {
        let channels = channelCount
        let left = source.left
        let right = source.right
        for index in units.indices {
            // Unretained: the ring outlives the IOProc (the session keeps the
            // tracks until the capture is destroyed), and no ARC traffic
            // happens on the real-time thread.
            units[index].ring = rings[index]
            let ring = Unmanaged.passUnretained(rings[index])
            try AudioObject.check(
                AudioDeviceCreateIOProcIDWithBlock(&units[index].procID, units[index].aggregateID, nil) { _, input, _, _, _ in
                    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                    guard list.count > 0, let data = list[0].mData else { return }
                    let bufferChannels = Int(list[0].mNumberChannels)
                    let frames = Int(list[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, bufferChannels))
                    _ = ring._withUnsafeGuaranteedRef { ring in
                        if bufferChannels == channels {
                            ring.write(
                                interleaved: data.assumingMemoryBound(to: Float.self), frames: frames,
                                channelCount: channels, left: left, right: right)
                        } else {
                            ring.writeSilence(frames: frames)  // unexpected layout: silence instead
                        }
                    }
                }, "Creazione della callback di registrazione")
            guard let procID = units[index].procID else { throw EngineError("Creazione delle callback: ID mancante") }
            try AudioObject.check(AudioDeviceStart(units[index].aggregateID, procID), "Avvio della registrazione")
            units[index].started = true
        }
    }

    /// Adds newly started processes of each app (e.g. a new browser helper).
    /// A failed read of the process list changes nothing, and a process the
    /// tap already has stays while it is in the list, even if its bundle ID
    /// can't be read this time.
    func refreshProcesses() {
        for index in units.indices {
            guard
                let processes = AudioProcesses.processObjects(
                    ofApp: units[index].target.bundleID, keeping: units[index].processes),
                Set(processes) != Set(units[index].processes)
            else { continue }
            var description = Self.description(
                target: units[index].target, uuid: units[index].uuid, deviceUID: deviceUID, stream: source.stream,
                processes: processes)
            var address = AudioObject.address(kAudioTapPropertyDescription)
            let status = withUnsafeMutablePointer(to: &description) {
                AudioObjectSetPropertyData(units[index].tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
            if status == noErr {
                units[index].processes = processes
                Log.engine.info(
                    "Recording tap for \(self.units[index].target.bundleID, privacy: .public): processes now \(processes, privacy: .public)")
            } else {
                Log.engine.error("Recording tap update failed: \(describeOSStatus(status), privacy: .public)")
            }
        }
    }

    /// Stops and destroys every IOProc, aggregate and tap. If an IOProc may
    /// still run (its stop or destroy failed), its ring is deliberately
    /// leaked: the IOProc holds it unretained, and freeing it would let a
    /// real-time thread write to freed memory (as the correction engine
    /// does with its shared state, see EngineSession.teardown).
    /// Returns the rings left to such IOProcs (empty when all went well).
    @discardableResult
    func destroy() -> Set<ObjectIdentifier> {
        var leaked: Set<ObjectIdentifier> = []
        for unit in units {
            if let procID = unit.procID {
                var status = noErr
                if unit.started { status = AudioDeviceStop(unit.aggregateID, procID) }
                let destroyStatus = AudioDeviceDestroyIOProcID(unit.aggregateID, procID)
                if status != noErr || destroyStatus != noErr {
                    Log.engine.fault(
                        "Recording IOProc of \(unit.target.bundleID, privacy: .public) not cleanly removed (stop \(describeOSStatus(status), privacy: .public), destroy \(describeOSStatus(destroyStatus), privacy: .public)): keeping its ring")
                    if let ring = unit.ring {
                        _ = Unmanaged.passRetained(ring)  // deliberate leak
                        leaked.insert(ObjectIdentifier(ring))
                    }
                }
            }
            if unit.aggregateID != kAudioObjectUnknown {
                let status = AudioHardwareDestroyAggregateDevice(unit.aggregateID)
                if status != noErr {
                    Log.engine.error("Recording aggregate \(unit.aggregateID) not destroyed: \(describeOSStatus(status), privacy: .public)")
                }
            }
            let status = AudioHardwareDestroyProcessTap(unit.tapID)
            if status != noErr {
                Log.engine.error("Recording tap \(unit.tapID) not destroyed: \(describeOSStatus(status), privacy: .public)")
            }
        }
        units = []
        return leaked
    }
}
