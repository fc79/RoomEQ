// The app's single source of truth for the audio engine, for the UI.
//
// Everything here runs on the main thread. The UI reads the observable
// properties and calls the methods; it never talks to Core Audio directly.
// All properties are read-only from outside: change them through the
// `set...` / `select...` methods, which validate and apply the change
// (live where possible, otherwise by restarting the engine).
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

    /// Output-capable devices (RoomEQ's own aggregate excluded).
    private(set) var outputDevices: [OutputDeviceInfo] = []
    /// UID chosen by the user, or nil for automatic (Quantum, else default output).
    private(set) var selectedOutputDeviceUID: String?
    /// Automatic choice (Quantum, else system default), updated with the device list.
    private(set) var automaticOutputDevice: OutputDeviceInfo?
    /// The device the RUNNING session actually uses (nil when not running).
    private(set) var activeOutputDevice: OutputDeviceInfo?
    var activeOutputDeviceUID: String? { activeOutputDevice?.uid }

    /// The device that should be used: the user's choice if present,
    /// otherwise the automatic choice. While running in automatic mode the
    /// engine follows it (e.g. back to the Quantum when it is plugged in).
    var effectiveOutputDevice: OutputDeviceInfo? {
        if let uid = selectedOutputDeviceUID, let device = outputDevices.first(where: { $0.uid == uid }) {
            return device
        }
        return automaticOutputDevice
    }

    /// Output channel pair the tap is routed to (default 1–2).
    private(set) var outputChannelPair: OutputChannelPair = .firstPair
    /// Pairs offered by the active device (or, when not running, by the
    /// device that would be used).
    var availableChannelPairs: [OutputChannelPair] {
        OutputChannelPair.available(
            forChannelCount: (activeOutputDevice ?? effectiveOutputDevice)?.outputChannelCount ?? 2)
    }

    // MARK: Buffer, level, exclusions

    /// IO buffer size in frames (the value actually applied when running).
    private(set) var bufferSize = BufferSize.defaultSize
    /// Buffer sizes the current device accepts (64/128/256 within its range).
    private(set) var bufferSizeOptions = BufferSize.preferredSizes
    /// Output gain in dB (applied after the DSP chain, ramped over 15 ms).
    private(set) var gainDecibels: Double = 0
    static let gainRange: ClosedRange<Double> = -60...12
    /// When true the output crossfades (10 ms) to the unprocessed signal.
    /// Stage 2: no audible difference.
    private(set) var isBypassed = false
    /// Apps never captured (RoomEQ itself is always excluded in addition).
    private(set) var excludedBundleIDs = ["com.ableton.live"]
    /// How system audio is captured: device tap (default) or global
    /// mixdown (diagnostic). Persisted in UserDefaults `TapMode`.
    private(set) var tapMode: TapMode =
        UserDefaults.standard.string(forKey: TapMode.defaultsKey).flatMap(TapMode.init(rawValue:)) ?? .defaultMode

    // MARK: Readouts

    private(set) var sampleRate: Double?
    private(set) var latency: LatencyBreakdown?
    /// e.g. "Stima 12.3 ms (ingresso 1.2 + buffer 5.8 + uscita 5.3) a 44100 Hz".
    var latencySummary: String { latency?.summary ?? "—" }
    /// Meters, refreshed ~25 times per second while running. Peaks are the
    /// maximum since the previous refresh; counters are cumulative per run.
    private(set) var meters = MeterSnapshot.silent
    /// Tap format of the running session, e.g. "44,1 kHz · 2 ch" (diagnostics).
    private(set) var tapFormatDescription: String?

    // MARK: Hooks

    /// Called after a (re)start whenever the sample rate differs from the
    /// previous run's (and on the first start). Stage 3 recomputes the EQ
    /// coefficients here.
    @ObservationIgnored var onSampleRateChange: ((Double) -> Void)?

    // MARK: Private

    @ObservationIgnored private let engine = AudioEngine()
    /// HAL reads for the device list happen here, never on the main thread.
    @ObservationIgnored private let deviceQueue = DispatchQueue(
        label: "com.federicociapi.RoomEQ.devices", qos: .userInitiated)
    @ObservationIgnored private var renderState: RenderStateHandle?
    /// ID of the engine session this controller considers running.
    @ObservationIgnored private var activeSessionID: Int?
    /// Incremented whenever pending launches become unwanted (new launch,
    /// stop, failure). A start completing with an old generation is stopped.
    @ObservationIgnored private var launchGeneration = 0
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var lastMeterPoll: ContinuousClock.Instant?
    @ObservationIgnored private var watchdog = InvalidCycleWatchdog(tripSeconds: 0.5)
    @ObservationIgnored private var deviceListeners: [PropertyListener] = []
    @ObservationIgnored private var lastSampleRate: Double?
    @ObservationIgnored private var automaticRestarts: [Date] = []
    @ObservationIgnored private var prepared = false

    init() {}

    /// Call once at launch: device list and device-change listeners.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        engine.eventHandler = { [weak self] event in self?.handle(event) }
        // No leftover clean-up: tap and aggregate are private, so the HAL
        // removes them when a previous instance exits (even on a crash) and
        // they would be invisible to us anyway. See AggregateDevice.swift.
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
            guard let device = self.effectiveOutputDevice else {
                self.fail("Nessun dispositivo di uscita disponibile")
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
    /// once the tap and aggregate are destroyed.
    func shutdown() {
        invalidatePendingLaunches()
        clearActiveSession()
        engine.stopSynchronously()
        state = .stopped
        status = "Fermo"
        Log.app.info("Engine shut down")
    }

    // MARK: Settings

    /// nil = automatic choice. Restarts the engine if running.
    func selectOutputDevice(uid: String?) {
        guard uid != selectedOutputDeviceUID else { return }
        selectedOutputDeviceUID = uid
        let channels = effectiveOutputDevice?.outputChannelCount ?? 2
        if !OutputChannelPair.available(forChannelCount: channels).contains(outputChannelPair) {
            outputChannelPair = .firstPair
        }
        restartIfActive(reason: "cambio dispositivo di uscita")
    }

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

    /// Applied live when running (clamped to the device's range). Reverts
    /// to the previous value if the device refuses it.
    func setBufferSize(_ frames: Int) {
        guard frames != bufferSize else { return }
        let previous = bufferSize
        bufferSize = frames
        guard isRunning else { return }
        engine.setBufferSize(frames) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (latency, applied)):
                self.latency = latency
                self.bufferSize = applied
            case .failure(let error):
                self.bufferSize = previous
                self.lastError = error.localizedDescription
            }
        }
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

    /// Changes the capture mode (persisted). Restarts the engine if running.
    func setTapMode(_ mode: TapMode) {
        guard mode != tapMode else { return }
        tapMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: TapMode.defaultsKey)
        restartIfActive(reason: "modalità di cattura \(mode.displayName.lowercased())")
    }

    /// Applied live, smoothly (15 ms ramp).
    func setGainDecibels(_ decibels: Double) {
        gainDecibels = min(max(decibels, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        renderState?.setGain(linear: Float(Decibels.linear(fromDecibels: gainDecibels)))
    }

    /// Applied live (10 ms crossfade).
    func setBypass(_ bypassed: Bool) {
        isBypassed = bypassed
        renderState?.setBypass(bypassed)
    }

    /// Re-reads the device list on a background queue and publishes it on
    /// the main thread; then runs `completion` (on main).
    func refreshDevices(then completion: (@MainActor () -> Void)? = nil) {
        deviceQueue.async { [weak self] in
            let devices = AudioDevices.outputDevices()
            let automatic = AudioDevices.preferredOutputDevice(
                in: devices, defaultOutputID: AudioDevices.defaultOutputDeviceID())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyDeviceList(devices, automatic: automatic)
                    completion?()
                }
            }
        }
    }

    // MARK: Internals

    private func applyDeviceList(_ devices: [OutputDeviceInfo], automatic: OutputDeviceInfo?) {
        if devices != outputDevices { outputDevices = devices }
        if automatic != automaticOutputDevice { automaticOutputDevice = automatic }
        followAutomaticChoiceIfNeeded()
    }

    /// In automatic mode, move the running engine to the automatic choice
    /// when it changes (e.g. the Quantum is plugged back in).
    private func followAutomaticChoiceIfNeeded() {
        guard isRunning, selectedOutputDeviceUID == nil,
            let automatic = automaticOutputDevice, let active = activeOutputDevice,
            automatic.uid != active.uid
        else { return }
        automaticRestart(reason: "uscita automatica ora \(automatic.name)")
    }

    private func configuration(for device: OutputDeviceInfo) -> EngineConfiguration {
        EngineConfiguration(
            outputDeviceUID: device.uid,
            outputPair: outputChannelPair,
            bufferFrames: bufferSize,
            excludedBundleIDs: excludedBundleIDs,
            gain: Float(Decibels.linear(fromDecibels: gainDecibels)),
            bypass: isBypassed,
            processListFallbackEnabled: !UserDefaults.standard.bool(forKey: "DisableProcessExclusionFallback"),
            tapMode: tapMode,
            tapDriftCompensation: Self.diagnosticFlag("TapDriftCompensation", default: true),
            tapMixdown: Self.diagnosticFlag("TapMixdown", default: true))
    }

    /// Boolean diagnostic switch from UserDefaults (set with
    /// `defaults write com.federicociapi.RoomEQ <key> -bool YES|NO`).
    private static func diagnosticFlag(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? defaultValue : UserDefaults.standard.bool(forKey: key)
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
        activeSessionID = nil
        activeOutputDevice = nil
        tapFormatDescription = nil
    }

    private func launch(on device: OutputDeviceInfo, statusText: String) {
        clearActiveSession()
        state = .starting
        status = statusText
        lastError = nil
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
            // Re-apply live settings changed while the engine was starting.
            info.renderState.setGain(linear: Float(Decibels.linear(fromDecibels: gainDecibels)))
            info.renderState.setBypass(isBypassed)
            if !info.renderState.setOutputPair(outputChannelPair) { outputChannelPair = info.outputPair }
            sampleRate = info.sampleRate
            latency = info.latency
            bufferSize = info.bufferFrames
            bufferSizeOptions = info.bufferSizeOptions
            tapFormatDescription = info.tapFormatSummary
            audioCapturePermissionLikelyDenied = false
            state = .running
            status = "In funzione su \(info.outputDevice.name) · \(Int(info.sampleRate)) Hz · buffer \(info.bufferFrames)"
            startMeters()
            if lastSampleRate != info.sampleRate {
                lastSampleRate = info.sampleRate
                onSampleRateChange?(info.sampleRate)
            }
            // The device list may have changed while starting.
            followAutomaticChoiceIfNeeded()
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
            // The engine has already stopped that session.
            guard sessionID == activeSessionID else { return }
            let lostUID = activeOutputDevice?.uid
            clearActiveSession()
            guard selectedOutputDeviceUID == nil else {
                fail("\(name) è stato scollegato")
                return
            }
            // Automatic mode: continue on the next automatic choice.
            state = .starting
            status = "\(name) scollegato, cerco un'altra uscita…"
            let generation = invalidatePendingLaunches()
            refreshDevices { [weak self] in
                guard let self, self.state == .starting, self.launchGeneration == generation else { return }
                guard let device = self.effectiveOutputDevice, device.uid != lostUID else {
                    self.fail("\(name) è stato scollegato")
                    return
                }
                self.launch(on: device, statusText: "Avvio su \(device.name)…")
                self.lastError = "\(name) è stato scollegato: audio su \(device.name)"
            }

        case .latencyChanged(let sessionID, let latency, let frames):
            guard sessionID == activeSessionID else { return }
            self.latency = latency
            bufferSize = frames
        }
    }

    /// Restart requested by the system (format/layout change, IO problem,
    /// device change). At most 3 in 10 s, to avoid restart loops.
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
        guard let device = effectiveOutputDevice else {
            fail("Nessun dispositivo di uscita disponibile")
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

    private func startMeters() {
        stopMeters()
        watchdog.reset()
        lastMeterPoll = ContinuousClock.now
        let timer = Timer(timeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        lastMeterPoll = nil
        meters = .silent
    }

    private func pollMeters() {
        guard let renderState else { return }
        let snapshot = renderState.readMeters()
        meters = snapshot

        // Watchdog: if most cycles are being silenced (buffer layout no
        // longer matches) for 0.5 s, rebuild the engine.
        let now = ContinuousClock.now
        let elapsed = lastMeterPoll.map { (now - $0) / .seconds(1) } ?? 0
        lastMeterPoll = now
        if watchdog.update(
            renderedCycles: snapshot.renderedCycles, invalidCycles: snapshot.invalidCycles, elapsed: elapsed)
        {
            Log.app.error(
                "Watchdog: \(snapshot.invalidInputCycles) invalid input / \(snapshot.invalidOutputCycles) invalid output cycles; restarting"
            )
            automaticRestart(reason: "audio non elaborabile (disposizione dei buffer cambiata)")
        }
    }
}
