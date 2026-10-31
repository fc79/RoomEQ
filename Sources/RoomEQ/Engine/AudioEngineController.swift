// The app's single source of truth for the audio engine, for the UI.
//
// Everything here runs on the main thread. The UI reads the observable
// properties and calls the methods; it never talks to Core Audio directly.
// All properties are read-only from outside: change them through the
// `set...` methods, which validate and apply the change (live where
// possible, otherwise by restarting the engine).
//
// Output device: ALWAYS the macOS default output (tapped device = output
// device), followed automatically when it changes.
//
// EQ (stage 3): the band list, preamp and EQ on/off live here, are saved
// to UserDefaults on every change and loaded at launch (the user's REW
// filters when nothing is saved). Every change of the band list is turned
// into coefficients for the running session's sample rate (48 kHz while
// stopped, for the curve) and handed to the audio thread, which switches
// click-free. Every session start recomputes them for the actual rate.
//
// Invariant: there is never a running engine session the controller does
// not know about. A session becomes "active" only when its start completes
// while that launch is still wanted; any other completed start is stopped
// immediately, `fail()` always stops the engine, and events from sessions
// that are no longer active are ignored.

import AppKit
import CoreAudio
import Foundation
import Observation
import RoomEQCore

/// Engine lifecycle state.
enum EngineState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    /// Stopped because of an error (see `lastError`).
    case failed
}

@MainActor
@Observable
final class AudioEngineController {
    // MARK: Status

    private(set) var state: EngineState = .stopped
    /// Short, human-readable (Italian) status line.
    private(set) var status = "Fermo"
    /// Last error or notice, nil when everything is fine.
    private(set) var lastError: String?
    /// True when the last start failed in a way that looks like macOS
    /// refusing audio capture (privacy permission). `lastError` then holds an
    /// Italian explanation with the System Settings path.
    private(set) var audioCapturePermissionLikelyDenied = false

    var isRunning: Bool { state == .running }

    // MARK: Devices and routing

    /// Output-capable devices (RoomEQ's own aggregates excluded), for stage 4.
    private(set) var outputDevices: [OutputDeviceInfo] = []
    /// The macOS default output device: RoomEQ taps it and plays on it.
    private(set) var systemOutputDevice: OutputDeviceInfo?
    /// The device the RUNNING session actually uses (nil when not running).
    private(set) var activeOutputDevice: OutputDeviceInfo?
    var activeOutputDeviceUID: String? { activeOutputDevice?.uid }
    /// The device that is (or would be) used.
    var effectiveOutputDevice: OutputDeviceInfo? { activeOutputDevice ?? systemOutputDevice }

    /// Output channel pair the audio is routed to (default 1–2).
    private(set) var outputChannelPair: OutputChannelPair = .firstPair
    /// Pairs offered by the active device (or, when not running, by the
    /// device that would be used).
    var availableChannelPairs: [OutputChannelPair] {
        OutputChannelPair.available(forChannelCount: effectiveOutputDevice?.outputChannelCount ?? 2)
    }

    // MARK: Buffer, level, exclusions

    /// IO buffer size in frames, same on the capture and output side.
    private(set) var bufferSize = BufferSize.defaultSize
    /// Buffer sizes the devices accept (64/128/256 within their ranges).
    private(set) var bufferSizeOptions = BufferSize.preferredSizes
    /// Apps never captured (RoomEQ itself is always excluded in addition).
    private(set) var excludedBundleIDs = ["com.ableton.live"]

    // MARK: Readouts

    private(set) var sampleRate: Double?
    private(set) var latency: LatencyBreakdown?
    /// e.g. "Stima 5,7 ms (ingresso … + buffer … + anello … + uscita …)".
    var latencySummary: String { latency?.summary ?? "—" }
    /// Meters, refreshed ~25 times per second while running. Peaks are the
    /// maximum since the previous refresh; counters are cumulative per run.
    private(set) var meters = MeterSnapshot.silent
    /// Ring buffer status (delay, underruns, capture overloads…), refreshed
    /// with the meters.
    private(set) var ringStatus = SplitLinkStatus.empty
    /// Ring read delay in frames / ms (nil when not running).
    var ringDelayFrames: Int? { isRunning ? Int(ringStatus.delayFrames) : nil }
    var ringDelayMilliseconds: Double? {
        guard let frames = ringDelayFrames, let sampleRate, sampleRate > 0 else { return nil }
        return Double(frames) * 1000 / sampleRate
    }
    /// Tap format of the running session, e.g. "44,1 kHz · 10 ch".
    private(set) var tapFormatDescription: String?

    // MARK: EQ

    /// The EQ bands in processing order (at most `EQBand.maximumCount`).
    private(set) var bands: [EQBand]
    /// EQ on (processed signal) or off (original signal, 10 ms crossfade).
    /// The filters keep running while off, so switching is click-free.
    private(set) var isEQEnabled: Bool
    /// Output preamp in dB, `preampRange` (-24…0): attenuation only.
    /// Applied (15 ms ramp) with the EQ on and off.
    private(set) var preampDecibels: Double
    static let preampRange = Preamp.range
    /// Largest boost of the combined EQ curve between 20 Hz and 20 kHz
    /// (0 when the curve never goes above 0 dB).
    private(set) var maxCurveBoostDecibels: Double = 0
    /// Preamp that would keep the curve at or below 0 dB (-maxBoost rounded
    /// up to 0,1 dB). Only a suggestion: call `setPreamp` to apply it.
    private(set) var suggestedPreampDecibels: Double = 0
    /// Enabled bands that are NOT processed, with the reason (e.g. Fc too
    /// high for the current sample rate), keyed by band ID.
    private(set) var bandIssues: [UUID: String] = [:]
    /// The same messages in band order.
    private(set) var filterWarnings: [String] = []
    /// Sample rate the curve, the issues and the coefficients refer to:
    /// the running session's, or `idleSampleRate` when stopped.
    private(set) var eqSampleRate: Double = AudioEngineController.idleSampleRate
    static let idleSampleRate: Double = 48_000

    /// Result of the last REW import: warnings (skipped filters, other
    /// equaliser…), a one-line summary on success, an error otherwise.
    private(set) var lastImportWarnings: [String] = []
    private(set) var lastImportSummary: String?
    private(set) var lastImportError: String?
    /// True while a file is being read.
    private(set) var isImporting = false

    // MARK: Private

    @ObservationIgnored private let engine = AudioEngine()
    /// HAL reads for the device list happen here, never on the main thread.
    @ObservationIgnored private let deviceQueue = DispatchQueue(
        label: "com.federicociapi.RoomEQ.devices", qos: .userInitiated)
    @ObservationIgnored private var renderState: RenderStateHandle?
    @ObservationIgnored private var link: SplitLinkHandle?
    /// ID of the engine session this controller considers running.
    @ObservationIgnored private var activeSessionID: Int?
    /// Incremented whenever pending launches become unwanted (new launch,
    /// stop, failure). A start completing with an old generation is stopped.
    @ObservationIgnored private var launchGeneration = 0
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var deviceListeners: [PropertyListener] = []
    @ObservationIgnored private var automaticRestarts: [Date] = []
    @ObservationIgnored private var prepared = false
    /// Current EQ design (coefficients at `eqSampleRate`). Observed, so
    /// views calling `curveResponse` refresh when it changes.
    private var eqDesign: EQDesign
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let importQueue = DispatchQueue(
        label: "com.federicociapi.RoomEQ.import", qos: .userInitiated)
    @ObservationIgnored private var importGeneration = 0
    static let settingsKey = "EQSettings"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let settings = userDefaults.data(forKey: Self.settingsKey).flatMap(EQSettings.decode) ?? .defaults()
        bands = settings.bands
        isEQEnabled = settings.isEQEnabled
        preampDecibels = settings.preampDecibels
        eqDesign = EQDesign(bands: settings.bands, sampleRate: Self.idleSampleRate)
        updateEQ()
    }

    /// Call once at launch: device list and device-change listeners
    /// (device list + macOS default output).
    func prepare() {
        guard !prepared else { return }
        prepared = true
        engine.eventHandler = { [weak self] event in self?.handle(event) }
        refreshDevices()
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            do {
                deviceListeners.append(
                    try PropertyListener(object: system, address: AudioObject.address(selector), queue: .main) {
                        [weak self] in
                        MainActor.assumeIsolated { self?.refreshDevices() }
                    })
            } catch {
                Log.devices.error("Device listener: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Start / stop

    func start() {
        guard state == .stopped || state == .failed else { return }
        automaticRestarts.removeAll()
        audioCapturePermissionLikelyDenied = false
        lastError = nil
        state = .starting
        status = "Avvio…"
        let generation = invalidatePendingLaunches()
        refreshDevices { [weak self] in
            guard let self, self.state == .starting, self.launchGeneration == generation else { return }
            guard let device = self.systemOutputDevice else {
                self.fail("Nessun dispositivo di uscita di macOS disponibile")
                return
            }
            self.launch(on: device, statusText: "Avvio su \(device.name)…")
        }
    }

    /// Stops the engine. Also works from `.failed` (makes sure nothing is left).
    func stop() {
        guard state == .running || state == .starting || state == .failed else { return }
        invalidatePendingLaunches()
        clearActiveSession()
        state = .stopping
        status = "Arresto…"
        lastError = nil
        engine.stop { [weak self] in
            guard let self, self.state == .stopping else { return }
            self.state = .stopped
            self.status = "Fermo"
        }
    }

    func toggle() {
        isRunning || state == .starting ? stop() : start()
    }

    /// Synchronous shutdown for app termination and SIGINT/SIGTERM: returns
    /// once the IOProcs, the aggregate and the tap are destroyed.
    func shutdown() {
        invalidatePendingLaunches()
        clearActiveSession()
        engine.stopSynchronously()
        state = .stopped
        status = "Fermo"
        Log.app.info("Engine shut down")
    }

    // MARK: Settings

    /// Applied live (validated against the active device).
    func setOutputChannelPair(_ pair: OutputChannelPair) {
        guard availableChannelPairs.contains(pair) else {
            lastError = "Canali \(pair) non disponibili su questo dispositivo"
            return
        }
        if let renderState {
            guard renderState.setOutputPair(pair) else {
                lastError = "Canali \(pair) non disponibili sul dispositivo in uso"
                return
            }
            engine.refreshLatency()
        }
        outputChannelPair = pair
    }

    /// Restarts the engine if running (the delay is re-measured for the new
    /// buffer size).
    func setBufferSize(_ frames: Int) {
        guard frames != bufferSize else { return }
        bufferSize = frames
        restartIfActive(reason: "buffer \(frames)")
    }

    /// Restarts the engine if running (the tap must be rebuilt).
    func setExcludedBundleIDs(_ ids: [String]) {
        var cleaned: [String] = []
        for id in ids.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !id.isEmpty {
            if !cleaned.contains(id) { cleaned.append(id) }
        }
        guard cleaned != excludedBundleIDs else { return }
        excludedBundleIDs = cleaned
        restartIfActive(reason: "cambio app escluse")
    }

    // MARK: EQ settings (all applied live and saved)

    /// Preamp in dB, clamped to -24…0. Applied smoothly (15 ms ramp).
    func setPreamp(_ decibels: Double) {
        let value = Preamp.clamp(decibels)
        guard value != preampDecibels else { return }
        preampDecibels = value
        renderState?.setPreamp(decibels: value)
        saveSettings()
    }

    /// EQ on/off (10 ms crossfade to/from the original signal).
    func setEQEnabled(_ enabled: Bool) {
        guard enabled != isEQEnabled else { return }
        isEQEnabled = enabled
        renderState?.setBypass(!enabled)
        saveSettings()
    }

    /// Replaces the band with the same ID (unknown IDs are ignored).
    /// Values are clamped to `EQBand.frequencyRange` / `gainRange` /
    /// `qRange`. Fine for continuous slider drags: changes are coalesced by
    /// the audio thread and the last one is always applied.
    func setBand(_ band: EQBand) {
        guard let index = bands.firstIndex(where: { $0.id == band.id }) else { return }
        let clamped = band.clamped()
        guard bands[index] != clamped else { return }
        bands[index] = clamped
        bandsChanged()
    }

    func setBandEnabled(id: EQBand.ID, _ enabled: Bool) {
        guard let index = bands.firstIndex(where: { $0.id == id }), bands[index].isEnabled != enabled else { return }
        bands[index].isEnabled = enabled
        bandsChanged()
    }

    func removeBand(id: EQBand.ID) {
        guard let index = bands.firstIndex(where: { $0.id == id }) else { return }
        bands.remove(at: index)
        bandsChanged()
    }

    /// Appends a neutral band (1 kHz, 0 dB, Q 1). Returns nil (and changes
    /// nothing) when there are already `EQBand.maximumCount` bands.
    @discardableResult
    func addBand() -> EQBand? {
        guard bands.count < EQBand.maximumCount else { return nil }
        let band = EQBand.neutral()
        bands.append(band)
        bandsChanged()
        return band
    }

    /// Back to the user's REW measurement filters (preamp and EQ on/off unchanged).
    func resetToDefaultFilters() {
        bands = EQBand.defaultBands()
        bandsChanged()
    }

    /// Combined EQ response in dB at each frequency (Hz), for drawing.
    /// Uses the running session's sample rate, or 48 kHz when stopped.
    /// Bands that are disabled or not processable are not included.
    func curveResponse(frequencies: [Double]) -> [Double] {
        EQCurve.responseDecibels(
            coefficients: eqDesign.coefficients, sampleRate: eqDesign.sampleRate, frequencies: frequencies)
    }

    /// Imports a REW "Export filter settings as text" file. The file is read
    /// and parsed on a background queue; then, on success, its PK filters
    /// replace the current bands (applied live, saved). Outcome in
    /// `lastImportSummary` / `lastImportWarnings` / `lastImportError`.
    func importREWFile(url: URL) {
        importGeneration += 1
        let generation = importGeneration
        isImporting = true
        lastImportError = nil
        importQueue.async { [weak self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try REWImport.load(url: url) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishImport(result, fileName: url.lastPathComponent, generation: generation)
                }
            }
        }
    }

    /// Re-reads the device list and the macOS default output on a background
    /// queue and publishes them on the main thread; then runs `completion`.
    func refreshDevices(then completion: (@MainActor () -> Void)? = nil) {
        deviceQueue.async { [weak self] in
            let devices = AudioDevices.outputDevices()
            let systemOutput = AudioDevices.defaultOutputDeviceID().flatMap(AudioDevices.info(for:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyDeviceList(devices, systemOutput: systemOutput)
                    completion?()
                }
            }
        }
    }

    // MARK: Internals

    private func applyDeviceList(_ devices: [OutputDeviceInfo], systemOutput: OutputDeviceInfo?) {
        if devices != outputDevices { outputDevices = devices }
        if systemOutput != systemOutputDevice { systemOutputDevice = systemOutput }
        followSystemOutputIfNeeded()
    }

    /// When the macOS default output changes while running, move RoomEQ to it.
    private func followSystemOutputIfNeeded() {
        guard isRunning, let system = systemOutputDevice, let active = activeOutputDevice, system.uid != active.uid
        else { return }
        // A deliberate change (the user picked another output in macOS):
        // not counted toward the automatic-restart limit.
        restartIfActive(reason: "uscita di macOS ora \(system.name)")
    }

    private func configuration(for device: OutputDeviceInfo) -> EngineConfiguration {
        EngineConfiguration(
            outputDeviceUID: device.uid,
            outputPair: outputChannelPair,
            bufferFrames: bufferSize,
            excludedBundleIDs: excludedBundleIDs,
            gain: Preamp.linearGain(decibels: preampDecibels),
            bypass: !isEQEnabled,
            bands: bands,
            processListFallbackEnabled: !UserDefaults.standard.bool(forKey: "DisableProcessExclusionFallback"))
    }

    /// Makes every launch in flight unwanted; returns the new generation.
    @discardableResult
    private func invalidatePendingLaunches() -> Int {
        launchGeneration += 1
        return launchGeneration
    }

    /// Forgets the running session on the UI side (the engine is stopped or
    /// replaced separately).
    private func clearActiveSession() {
        stopMeters()
        renderState = nil
        link = nil
        activeSessionID = nil
        activeOutputDevice = nil
        tapFormatDescription = nil
        ringStatus = .empty
        updateEQ()  // back to the idle sample rate
    }

    private func launch(on device: OutputDeviceInfo, statusText: String) {
        clearActiveSession()
        state = .starting
        status = statusText
        lastError = nil
        if !OutputChannelPair.available(forChannelCount: device.outputChannelCount).contains(outputChannelPair) {
            outputChannelPair = .firstPair
        }
        let generation = invalidatePendingLaunches()
        // engine.start stops the current session (if any) before building
        // the new one, on the engine queue.
        engine.start(configuration(for: device)) { [weak self] result in
            self?.didStart(result, generation: generation)
        }
    }

    private func didStart(_ result: Result<SessionInfo, Error>, generation: Int) {
        let wanted = generation == launchGeneration && state == .starting
        switch result {
        case .success(let info):
            guard wanted else {
                // Superseded, stopped or failed meanwhile: never leave this
                // session running (it would keep the tapped apps muted).
                Log.app.info("Discarding session \(info.sessionID) (no longer wanted)")
                engine.stop(sessionID: info.sessionID)
                return
            }
            activeSessionID = info.sessionID
            activeOutputDevice = info.outputDevice
            renderState = info.renderState
            link = info.link
            // Re-apply live settings changed while the engine was starting.
            info.renderState.setPreamp(decibels: preampDecibels)
            info.renderState.setBypass(!isEQEnabled)
            if !info.renderState.setOutputPair(outputChannelPair) { outputChannelPair = info.outputPair }
            sampleRate = info.sampleRate
            latency = info.latency
            bufferSize = info.bufferFrames
            bufferSizeOptions = info.bufferSizeOptions
            tapFormatDescription = info.tapFormatSummary
            ringStatus = info.link.status()
            audioCapturePermissionLikelyDenied = false
            state = .running
            status = "In funzione su \(info.outputDevice.name) · \(AudioFormatText.kilohertz(info.sampleRate)) · buffer \(info.bufferFrames)"
            startMeters()
            // Curve and issues for this session's rate; bands changed while
            // starting are published (an unchanged set is not re-sent).
            updateEQ()
            // The macOS output may have changed while starting.
            followSystemOutputIfNeeded()
        case .failure(let error):
            guard wanted else { return }  // the failed session is already torn down
            if error is AudioCapturePermissionError { audioCapturePermissionLikelyDenied = true }
            fail(error.localizedDescription)
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .restartNeeded(let sessionID, let reason):
            guard sessionID == activeSessionID, isRunning else { return }
            automaticRestart(reason: reason)

        case .deviceLost(let sessionID, let name):
            // The engine has already stopped that session. macOS normally
            // switches its default output: follow it.
            guard sessionID == activeSessionID else { return }
            let lostUID = activeOutputDevice?.uid
            clearActiveSession()
            state = .starting
            status = "\(name) scollegato, passo all'uscita di macOS…"
            let generation = invalidatePendingLaunches()
            refreshDevices { [weak self] in
                guard let self, self.state == .starting, self.launchGeneration == generation else { return }
                guard let device = self.systemOutputDevice, device.uid != lostUID else {
                    self.fail("\(name) è stato scollegato")
                    return
                }
                self.launch(on: device, statusText: "Avvio su \(device.name)…")
                self.lastError = "\(name) è stato scollegato: audio su \(device.name)"
            }

        case .latencyChanged(let sessionID, let latency):
            guard sessionID == activeSessionID else { return }
            self.latency = latency

        case .fatal(let sessionID, let message):
            // The engine already stopped the session (apps unmuted).
            guard sessionID == activeSessionID else { return }
            fail(message)
        }
    }

    /// Restart requested by the system (format/layout change, IO problem).
    /// At most 3 in 10 s, to avoid restart loops. User-initiated restarts
    /// (buffer, exclusions, macOS output change) call `restartIfActive`
    /// directly and are not counted.
    private func automaticRestart(reason: String) {
        let now = Date()
        automaticRestarts = automaticRestarts.filter { now.timeIntervalSince($0) < 10 } + [now]
        guard automaticRestarts.count <= 3 else {
            fail("Troppi riavvii automatici (\(reason))")
            return
        }
        restartIfActive(reason: reason)
    }

    private func restartIfActive(reason: String) {
        guard state == .running || state == .starting else { return }
        guard let device = systemOutputDevice else {
            fail("Nessun dispositivo di uscita di macOS disponibile")
            return
        }
        Log.app.info("Restarting engine: \(reason, privacy: .public)")
        launch(on: device, statusText: "Riavvio (\(reason))…")
    }

    /// Error state. Always stops the engine, so no session can outlive it.
    private func fail(_ message: String) {
        Log.app.error("Engine error: \(message, privacy: .public)")
        invalidatePendingLaunches()
        clearActiveSession()
        engine.stop()
        state = .failed
        lastError = message
        status = "Errore: \(message)"
    }

    // MARK: EQ internals

    private func bandsChanged() {
        updateEQ()
        saveSettings()
    }

    /// Recomputes the design for the current rate, hands it to the audio
    /// thread (if running) and refreshes the derived values.
    private func updateEQ() {
        let rate = renderState?.configuration.sampleRate ?? Self.idleSampleRate
        let design = EQDesign(bands: bands, sampleRate: rate)
        renderState?.publishFilters(design.sections)
        if design != eqDesign { eqDesign = design }
        if rate != eqSampleRate { eqSampleRate = rate }
        if design.issues != bandIssues { bandIssues = design.issues }
        if design.warnings != filterWarnings { filterWarnings = design.warnings }
        let boost = EQCurve.maximumBoostDecibels(design: design, bands: bands)
        if boost != maxCurveBoostDecibels { maxCurveBoostDecibels = boost }
        let suggested = EQCurve.suggestedPreampDecibels(forMaximumBoost: boost)
        if suggested != suggestedPreampDecibels { suggestedPreampDecibels = suggested }
    }

    private func saveSettings() {
        let settings = EQSettings(bands: bands, preampDecibels: preampDecibels, isEQEnabled: isEQEnabled)
        do {
            userDefaults.set(try settings.encoded(), forKey: Self.settingsKey)
        } catch {
            Log.app.error("Saving EQ settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finishImport(_ result: Result<REWImportResult, Error>, fileName: String, generation: Int) {
        guard generation == importGeneration else { return }  // a newer import is running
        isImporting = false
        switch result {
        case .success(let imported):
            bands = imported.bands
            bandsChanged()
            lastImportWarnings = imported.warnings
            lastImportError = nil
            let count = imported.bands.count
            var summary = count == 1 ? "Importato 1 filtro" : "Importati \(count) filtri"
            summary += " da «\(fileName)»"
            let off = imported.bands.filter { !$0.isEnabled }.count
            if off > 0 { summary += off == 1 ? " (1 disattivato)" : " (\(off) disattivati)" }
            lastImportSummary = summary
            Log.app.info("REW import: \(count) bands, \(imported.warnings.count) warnings")
        case .failure(let error):
            if case .noUsableFilters(_, let warnings) = error as? REWImportError {
                lastImportWarnings = warnings
            } else {
                lastImportWarnings = []
            }
            lastImportSummary = nil
            lastImportError = (error as? LocalizedError)?.errorDescription ?? "Importazione non riuscita: \(error.localizedDescription)"
            Log.app.error("REW import failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startMeters() {
        stopMeters()
        let timer = Timer(timeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        meters = .silent
    }

    /// UI refresh only. Health, underruns and drift are watched by the
    /// engine itself (EngineSession.maintenanceTick), which stops the session
    /// and reports `.fatal` when RoomEQ cannot deliver audio.
    private func pollMeters() {
        guard let renderState, let link else { return }
        meters = renderState.readMeters()
        ringStatus = link.status()
    }
}
