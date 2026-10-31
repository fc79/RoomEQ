// The app's single source of truth for the audio engine, for the UI.
//
// Everything here runs on the main thread. The UI reads the observable
// properties and calls the methods; it never talks to Core Audio directly.
// All properties are read-only from outside: change them through the
// `set...` / `select...` methods, which validate and apply the change
// (live where possible, otherwise by restarting the engine).

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
    /// Last error message, nil when everything is fine.
    private(set) var lastError: String?

    var isRunning: Bool { state == .running }

    // MARK: Devices and routing

    /// Output-capable devices (RoomEQ's own aggregate excluded).
    private(set) var outputDevices: [OutputDeviceInfo] = []
    /// UID chosen by the user, or nil for automatic (Quantum, else default output).
    private(set) var selectedOutputDeviceUID: String?
    /// The device that is (or would be) used: the user's choice if present,
    /// otherwise the automatic choice.
    var effectiveOutputDevice: OutputDeviceInfo? {
        if let uid = selectedOutputDeviceUID, let device = outputDevices.first(where: { $0.uid == uid }) {
            return device
        }
        return automaticOutputDevice
    }
    /// Automatic choice (Quantum, else system default), updated with the device list.
    private(set) var automaticOutputDevice: OutputDeviceInfo?

    /// Output channel pair the tap is routed to (default 1–2).
    private(set) var outputChannelPair: OutputChannelPair = .firstPair
    /// Pairs offered by the effective output device.
    var availableChannelPairs: [OutputChannelPair] {
        OutputChannelPair.available(forChannelCount: effectiveOutputDevice?.outputChannelCount ?? 2)
    }

    // MARK: Buffer, level, exclusions

    /// IO buffer size in frames (the value actually applied when running).
    private(set) var bufferSize = BufferSize.defaultSize
    /// Buffer sizes the current device accepts (64/128/256 within its range).
    private(set) var bufferSizeOptions = BufferSize.preferredSizes
    /// Output gain in dB (applied after the DSP chain), range `gainRange`.
    private(set) var gainDecibels: Double = 0
    static let gainRange: ClosedRange<Double> = -60...12
    /// When true the DSP chain is skipped (stage 2: no audible difference).
    private(set) var isBypassed = false
    /// Apps never captured (RoomEQ itself is always excluded in addition).
    private(set) var excludedBundleIDs = ["com.ableton.live"]

    // MARK: Readouts

    private(set) var sampleRate: Double?
    private(set) var latency: LatencyBreakdown?
    /// e.g. "12.3 ms (ingresso 1.2 + buffer 5.8 + uscita 5.3) a 44100 Hz".
    var latencySummary: String { latency?.summary ?? "—" }
    /// Meters, refreshed ~25 times per second while running. Peaks are the
    /// maximum since the previous refresh; counters are cumulative per run.
    private(set) var meters = MeterSnapshot.silent
    /// Tap format as reported by Core Audio (diagnostics).
    private(set) var tapFormatDescription: String?

    // MARK: Hooks

    /// Called after a (re)start whenever the sample rate differs from the
    /// previous run's (and on the first start). Stage 3 recomputes the EQ
    /// coefficients here.
    @ObservationIgnored var onSampleRateChange: ((Double) -> Void)?

    // MARK: Private

    @ObservationIgnored private let engine = AudioEngine()
    @ObservationIgnored private var renderState: RenderStateHandle?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var deviceListeners: [PropertyListener] = []
    @ObservationIgnored private var lastSampleRate: Double?
    @ObservationIgnored private var automaticRestarts: [Date] = []
    @ObservationIgnored private var prepared = false
    /// Incremented on every launch; completions of older launches are ignored.
    @ObservationIgnored private var launchGeneration = 0

    init() {}

    /// Call once at launch: device list, device-change listeners, leftover clean-up.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        engine.eventHandler = { [weak self] event in self?.handle(event) }
        engine.performStartupCleanup()
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
        refreshDevices()
        guard let device = effectiveOutputDevice else {
            fail("Nessun dispositivo di uscita disponibile")
            return
        }
        automaticRestarts.removeAll()
        launch(on: device, statusText: "Avvio su \(device.name)…")
    }

    func stop() {
        guard state == .running || state == .starting else { return }
        state = .stopping
        status = "Arresto…"
        stopMeters()
        engine.stop { [weak self] in
            guard let self else { return }
            self.renderState = nil
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
        stopMeters()
        engine.stopSynchronously()
        renderState = nil
        state = .stopped
        status = "Fermo"
        Log.app.info("Engine shut down")
    }

    // MARK: Settings

    /// nil = automatic choice. Restarts the engine if running.
    func selectOutputDevice(uid: String?) {
        guard uid != selectedOutputDeviceUID else { return }
        selectedOutputDeviceUID = uid
        if !availableChannelPairs.contains(outputChannelPair) { outputChannelPair = .firstPair }
        restartIfActive(reason: "cambio dispositivo di uscita")
    }

    /// Applied live.
    func setOutputChannelPair(_ pair: OutputChannelPair) {
        guard availableChannelPairs.contains(pair) else {
            lastError = "Canali \(pair) non disponibili su questo dispositivo"
            return
        }
        outputChannelPair = pair
        if let renderState {
            renderState.setOutputPair(pair)
            engine.refreshLatency()
        }
    }

    /// Applied live when running (clamped to the device's range).
    func setBufferSize(_ frames: Int) {
        guard frames != bufferSize else { return }
        bufferSize = frames
        guard isRunning else { return }
        engine.setBufferSize(frames) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (latency, applied)):
                self.latency = latency
                self.bufferSize = applied
            case .failure(let error):
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

    /// Applied live, smoothly.
    func setGainDecibels(_ decibels: Double) {
        gainDecibels = min(max(decibels, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        renderState?.setGain(linear: Float(Decibels.linear(fromDecibels: gainDecibels)))
    }

    /// Applied live.
    func setBypass(_ bypassed: Bool) {
        isBypassed = bypassed
        renderState?.setBypass(bypassed)
    }

    func refreshDevices() {
        let devices = AudioDevices.outputDevices()
        if devices != outputDevices { outputDevices = devices }
        let automatic = AudioDevices.preferredOutputDevice(in: devices)
        if automatic != automaticOutputDevice { automaticOutputDevice = automatic }
    }

    // MARK: Internals

    private func configuration(for device: OutputDeviceInfo) -> EngineConfiguration {
        EngineConfiguration(
            outputDeviceUID: device.uid,
            outputPair: outputChannelPair,
            bufferFrames: bufferSize,
            excludedBundleIDs: excludedBundleIDs,
            gain: Float(Decibels.linear(fromDecibels: gainDecibels)),
            bypass: isBypassed,
            processListFallbackEnabled: !UserDefaults.standard.bool(forKey: "DisableProcessExclusionFallback"))
    }

    private func launch(on device: OutputDeviceInfo, statusText: String) {
        state = .starting
        status = statusText
        lastError = nil
        stopMeters()
        renderState = nil
        launchGeneration += 1
        let generation = launchGeneration
        engine.start(configuration(for: device)) { [weak self] result in
            self?.didStart(result, generation: generation)
        }
    }

    private func didStart(_ result: Result<SessionInfo, Error>, generation: Int) {
        // A newer launch superseded this one (its session is already gone).
        guard generation == launchGeneration else { return }
        // The user pressed Stop while starting: the stop is queued after the
        // start and will complete the transition.
        guard state == .starting else { return }
        switch result {
        case .success(let info):
            renderState = info.renderState
            // Re-apply live settings changed while the engine was starting.
            info.renderState.setGain(linear: Float(Decibels.linear(fromDecibels: gainDecibels)))
            info.renderState.setBypass(isBypassed)
            if !info.renderState.setOutputPair(outputChannelPair) { outputChannelPair = info.outputPair }
            sampleRate = info.sampleRate
            latency = info.latency
            bufferSize = info.bufferFrames
            bufferSizeOptions = info.bufferSizeOptions
            tapFormatDescription = info.tapFormatDescription
            state = .running
            status = "In funzione su \(info.outputDevice.name) · \(Int(info.sampleRate)) Hz · buffer \(info.bufferFrames)"
            startMeters()
            if lastSampleRate != info.sampleRate {
                lastSampleRate = info.sampleRate
                onSampleRateChange?(info.sampleRate)
            }
        case .failure(let error):
            fail(error.localizedDescription)
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .restartNeeded(let reason):
            guard isRunning else { return }
            // Guard against restart loops: at most 3 automatic restarts in 10 s.
            let now = Date()
            automaticRestarts = automaticRestarts.filter { now.timeIntervalSince($0) < 10 } + [now]
            guard automaticRestarts.count <= 3 else {
                engine.stop {}
                fail("Troppi riavvii automatici (\(reason))")
                return
            }
            restartIfActive(reason: reason)
        case .deviceLost(let name):
            refreshDevices()
            fail("\(name) è stato scollegato")
        case .latencyChanged(let latency, let frames):
            self.latency = latency
            bufferSize = frames
        }
    }

    private func restartIfActive(reason: String) {
        guard state == .running || state == .starting else { return }
        refreshDevices()
        guard let device = effectiveOutputDevice else {
            engine.stop {}
            fail("Nessun dispositivo di uscita disponibile")
            return
        }
        Log.app.info("Restarting engine: \(reason, privacy: .public)")
        launch(on: device, statusText: "Riavvio (\(reason))…")
    }

    private func fail(_ message: String) {
        Log.app.error("Engine error: \(message, privacy: .public)")
        stopMeters()
        renderState = nil
        state = .failed
        lastError = message
        status = "Errore: \(message)"
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

    private func pollMeters() {
        guard let renderState else { return }
        meters = renderState.readMeters()
    }
}
