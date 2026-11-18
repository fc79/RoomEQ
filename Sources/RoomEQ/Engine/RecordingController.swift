// The recording feature for the UI: which apps to record (remembered), "skip
// silence", start/stop, and what to show while recording (elapsed time, one
// level per app, notices). The audio work is in RecordingSession; nothing
// here waits for it (start and stop complete asynchronously), except
// `stopForQuit()`, bounded.
//
// While recording it listens to Core Audio (handlers on a background queue)
// for:
//   - the default output device: the session follows it (it never stops
//     because the output changed);
//   - the process list: an app may start a new helper process (browsers).

import AppKit
import CoreAudio
import Observation
import RoomEQCore

@MainActor
@Observable
final class RecordingController {
    /// A chosen app, remembered between launches.
    struct Choice: Codable, Hashable, Sendable {
        let bundleID: String
        let name: String
    }

    /// One app in the picker.
    struct AppRow: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let isPlaying: Bool
        let isChosen: Bool
    }

    /// One app while recording.
    struct LiveApp: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        /// Smoothed peak, linear 0…1.
        let level: Float
        let isPaused: Bool
    }

    private(set) var chosen: [Choice] = []
    var skipSilence: Bool {
        didSet { defaults.set(skipSilence, forKey: Keys.skipSilence) }
    }
    private(set) var apps: [AppRow] = []

    /// Between "Registra" and the session actually running.
    private(set) var isStarting = false
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var live: [LiveApp] = []
    /// A warning while recording (lost audio, disk almost full).
    private(set) var notice: String?
    /// Why the last recording stopped by itself, or why it could not start.
    private(set) var failure: String?
    /// "Salvati 2 file (03:27)." after a recording.
    private(set) var savedSummary: String?
    private(set) var savedFiles: [URL] = []

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var listeners: [PropertyListener] = []
    @ObservationIgnored private let listenerQueue = DispatchQueue(label: "com.federicociapi.RoomEQ.recording.listeners")
    @ObservationIgnored private var levels: [String: Float] = [:]

    private enum Keys {
        static let apps = "recording.apps"
        static let skipSilence = "recording.skipSilence"
    }

    init() {
        skipSilence = defaults.object(forKey: Keys.skipSilence) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.apps), let saved = try? JSONDecoder().decode([Choice].self, from: data) {
            chosen = saved
        }
    }

    var canStart: Bool { !chosen.isEmpty && !isRecording && !isStarting }

    /// "Brave, Spotify", "Brave, Spotify e un'altra", "Brave, Spotify e altre 2",
    /// "Nessuna app".
    var summary: String {
        let names = chosen.map(\.name)
        switch names.count {
        case 0: return String(localized: "Nessuna app")
        case 1, 2: return names.joined(separator: ", ")
        case 3: return String(localized: "\(names[0]), \(names[1]) e un'altra")
        default: return String(localized: "\(names[0]), \(names[1]) e altre \(names.count - 2)")
        }
    }

    // MARK: Choosing apps

    /// Running regular apps (not RoomEQ) plus chosen apps that are not
    /// running; playing ones first, then by name. The audio flag is read off
    /// the main thread.
    func refreshApps() {
        let own = Bundle.main.bundleIdentifier ?? ""
        var rows: [(String, String)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, !ExclusionRules.same(id, own) else { return nil }
            return (id, app.localizedName ?? id)
        }
        for choice in chosen where !rows.contains(where: { ExclusionRules.same($0.0, choice.bundleID) }) {
            rows.append((choice.bundleID, choice.name))
        }
        listenerQueue.async { [weak self] in
            let playing = AudioProcesses.bundleIDsPlayingAudio()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apps = rows.map { id, name in
                        AppRow(
                            bundleID: id, name: name,
                            isPlaying: playing.contains { RecordingMatch.belongs(processBundleID: $0, toApp: id) },
                            isChosen: self.chosen.contains { ExclusionRules.same($0.bundleID, id) })
                    }
                    .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
                }
            }
        }
    }

    func setChosen(_ chosen: Bool, app: AppRow) {
        guard !isRecording, !isStarting else { return }
        self.chosen.removeAll { ExclusionRules.same($0.bundleID, app.bundleID) }
        if chosen { self.chosen.append(Choice(bundleID: app.bundleID, name: app.name)) }
        if let data = try? JSONEncoder().encode(self.chosen) { defaults.set(data, forKey: Keys.apps) }
        apps = apps.map {
            $0.bundleID == app.bundleID
                ? AppRow(bundleID: $0.bundleID, name: $0.name, isPlaying: $0.isPlaying, isChosen: chosen) : $0
        }
    }

    // MARK: Recording

    func start() {
        guard canStart else { return }
        failure = nil
        notice = nil
        savedSummary = nil
        savedFiles = []
        guard let device = AudioDevices.defaultOutputDeviceID() else {
            failure = String(localized: "Nessuna uscita audio: impossibile registrare.")
            return
        }
        let session = RecordingSession(
            targets: chosen.map { RecordingSession.Target(bundleID: $0.bundleID, name: $0.name) },
            folder: RecordingNames.defaultFolder(), skipSilence: skipSilence)
        self.session = session
        isStarting = true
        // Listen first, so an output change during the start is not missed.
        startListening(session)
        session.start(device: device) { [weak self] error in
            MainActor.assumeIsolated { self?.started(session, error: error) }
        }
    }

    func stop() {
        guard let session, isRecording else { return }
        session.stop { [weak self] snapshot in
            MainActor.assumeIsolated { self?.finish(session, snapshot) }
        }
    }

    /// At quit (and SIGINT/SIGTERM): closes the files, waiting at most 2 s.
    func stopForQuit() {
        guard let session else { return }
        stopListening()
        session.stopAndWait(timeout: 2)
    }

    func showInFinder() {
        let files = savedFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.isEmpty {
            let folder = RecordingNames.defaultFolder()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    func clearFailure() { failure = nil }
    func clearSaved() { savedSummary = nil }

    // MARK: Internals

    private func started(_ started: RecordingSession, error: Error?) {
        guard started === session else { return }
        isStarting = false
        if let error {
            stopListening()
            session = nil
            failure = String(localized: "Registrazione non avviata: \(error.localizedDescription)")
            return
        }
        isRecording = true
        elapsed = 0
        levels = [:]
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // .common: keeps running while a control is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard let session else { return }
        let snapshot = session.takeSnapshot()
        guard snapshot.isRunning else {
            finish(session, snapshot)
            return
        }
        elapsed = Date().timeIntervalSince(snapshot.started)
        savedFiles = snapshot.files
        live = snapshot.apps.map { app in
            // Fast attack, slow release, like the output meters.
            let level = max(app.peak, (levels[app.bundleID] ?? 0) * 0.8)
            levels[app.bundleID] = level
            return LiveApp(bundleID: app.bundleID, name: app.name, level: level, isPaused: app.isPaused)
        }
        var notices: [String] = []
        if snapshot.droppedFrames > 0, snapshot.sampleRate > 0 {
            let seconds = NumberText.string(Double(snapshot.droppedFrames) / snapshot.sampleRate, decimals: 2...2)
            notices.append(String(localized: "Persa una piccola parte dell'audio (circa \(seconds) s, sostituita da silenzio). La registrazione continua."))
        }
        if let left = snapshot.secondsLeftOnDisk, left < 600 {
            let minutes = Int(left / 60)
            notices.append(
                minutes < 2
                    ? String(localized: "Disco quasi pieno: resta meno di 2 minuti di registrazione.")
                    : String(localized: "Disco quasi pieno: restano circa \(minutes) minuti di registrazione."))
        }
        let text = notices.isEmpty ? nil : notices.joined(separator: "\n")
        if text != notice { notice = text }
    }

    private func finish(_ finished: RecordingSession, _ snapshot: RecordingSession.Snapshot) {
        guard finished === session else { return }
        timer?.invalidate()
        timer = nil
        stopListening()
        session = nil
        isRecording = false
        live = []
        notice = nil
        savedFiles = snapshot.files
        failure = snapshot.failure
        let duration = Format.duration(Date().timeIntervalSince(snapshot.started))
        switch snapshot.files.count {
        case 0: savedSummary = String(localized: "Nessun file salvato: le app non hanno suonato.")
        case 1: savedSummary = String(localized: "Salvato 1 file (\(duration)).")
        default: savedSummary = String(localized: "Salvati \(snapshot.files.count) file (\(duration)).")
        }
    }

    private func startListening(_ session: RecordingSession) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        listenerQueue.async { [weak self, weak session] in
            guard let session else { return }
            var made: [PropertyListener] = []
            do {
                made.append(try PropertyListener(
                    object: system, address: AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice),
                    queue: self?.listenerQueue ?? .global()
                ) { [weak session] in
                    guard let device = AudioDevices.defaultOutputDeviceID() else { return }
                    session?.switchDevice(to: device)
                })
                made.append(try PropertyListener(
                    object: system, address: AudioObject.address(kAudioHardwarePropertyProcessObjectList),
                    queue: self?.listenerQueue ?? .global()
                ) { [weak session] in session?.refreshProcesses() })
            } catch {
                Log.engine.error("Recording listeners: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.session === session else {
                        self?.listenerQueue.async { for listener in made { listener.remove() } }
                        return
                    }
                    self.listeners = made
                }
            }
        }
    }

    private func stopListening() {
        let old = listeners
        listeners = []
        listenerQueue.async { for listener in old { listener.remove() } }
    }
}
