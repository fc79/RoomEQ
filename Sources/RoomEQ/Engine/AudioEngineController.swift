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
// The output device can be chosen from the panel (`setSystemOutputDevice`):
// that changes the macOS default output, which RoomEQ then follows.
//
// Settings (stage 4): one versioned document (`AppSettings`, RoomEQCore)
// holds the working EQ state, presets, per-output assignments, exclusions
// and auto-start; saved to UserDefaults (debounced 0,5 s, flushed on quit),
// loaded leniently at launch (migrating the stage-3 "EQSettings"); anything
// unreadable is backed up before it can be overwritten.
// One file on purpose: the extensions at the bottom (Presets, Exclusions,
// System) are in the same file so that all state can be `private(set)`
// (views can read it, never write it).
//
// Principle: unsaved EQ work is never lost without an explicit confirmation
// by the user. `hasUnsavedChanges` tells the UI when to ask; automatic
// per-output switches stash unsaved work per output instead of dropping it.
//
// Every change of the band list is turned into coefficients for the running
// session's sample rate (while stopped: the macOS default output's nominal
// rate, or 48 kHz if unknown) and handed to the audio thread, where every
// band ramps to its new parameters in 30 ms. Every session start recomputes
// them for the actual rate.
//
// Automatic pause ("Nessuna correzione", see OutputAssignment.swift in
// RoomEQCore): with per-output presets on and the macOS default output set
// to "no correction", the engine is stopped completely (`.paused`: no tap,
// no aggregate, no IOProc) while the main switch stays on; RoomEQ resumes
// on its own when the default output has correction again. Pausing and
// resuming are neither errors nor automatic restarts. The default-output
// listener lives here (`prepare`), not in the session, so it works while
// paused. Every launch goes through `launch(on:)`, which pauses instead
// when the rules say so; `applyOutputMode` handles the other direction.
// The user's intention (`isSwitchedOn`) is kept apart from `state`: it
// survives errors, so after a failed start a change of the macOS output
// still pauses (no correction) or tries again (correction); only the
// switch (`stop()`) turns it off.
//
// Retry window (`startRetryDeadline`, 30 s): opened by the auto-start at
// login, an automatic resume, and a change of the macOS output (also while
// running, or after a lost device). A device just switched on or plugged in
// often has irregular IO for a moment, so inside the window a failed start
// is NOT an error: RoomEQ stays `.starting` ("Attendo che l'uscita … sia
// pronta…") and tries again after `startRetryDelay`. Only when the window
// is over (or retrying cannot help, e.g. no permission) it goes `.failed`.
// One retry chain at a time: each retry is bound to the launch generation,
// so stop, pause, any new launch or failure cancels it. Retries never count
// as automatic restarts.
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
import ServiceManagement
import UniformTypeIdentifiers

/// Engine lifecycle state.
enum EngineState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    /// Stopped because of an error (see `lastError`).
    case failed
    /// Switched on, but nothing runs: the macOS default output is set to
    /// "no correction" (`pausedOutputName`). Resumes by itself.
    case paused
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
    /// The main switch: the user's intention, set by `start()` (also the
    /// auto-start) and cleared only by `stop()` / quitting. Stays on while
    /// paused and after an error (`.failed`, `lastError` explains it): the
    /// switch shows "on" until the user turns it off. Use this (not
    /// `isRunning`) for the on/off toggle.
    private(set) var isSwitchedOn = false
    /// Name of the output RoomEQ is paused for (nil unless `.paused`).
    var pausedOutputName: String? { state == .paused ? pausedDeviceName : nil }

    // MARK: Devices and routing

    /// Output-capable devices (aggregate devices excluded). For the output
    /// menu use `outputDeviceOptions` (adds the "is default" flag).
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

    // MARK: Readouts

    private(set) var sampleRate: Double?
    private(set) var latency: LatencyBreakdown?
    /// e.g. "Stima 5,7 ms (ingresso … + buffer … + anello … + uscita …)".
    var latencySummary: String { latency?.summary ?? "—" }
    /// Meters, refreshed ~25 times per second while running. Peaks are the
    /// maximum since the previous refresh; counters are cumulative per run.
    /// (For the CLIP badge use `clipStatus`, which can be reset.)
    private(set) var meters = MeterSnapshot.silent
    /// Clipping since the last `resetClipIndicators()` (or session start, or
    /// preamp change), refreshed with the meters: input overs (the source is
    /// already over 0 dBFS), output overs (clamped before the device), how
    /// many were caused by the EQ, and the max levels in dB over full scale.
    private(set) var clipStatus = ClipStatus.none
    /// Preamp that would have avoided the EQ-caused clipping measured since
    /// the last reset (current preamp - max over, rounded down to 0,1 dB,
    /// >= -24 dB); nil unless the EQ caused it. Only a suggestion.
    var suggestedPreampForClipping: Double? { clipStatus.suggestedPreamp(currentPreamp: preampDecibels) }
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
    var bands: [EQBand] { settings.bands }
    /// EQ on (processed signal) or off (original signal, 10 ms crossfade).
    /// The filters keep running while off, so switching is click-free.
    /// Global: not part of presets.
    var isEQEnabled: Bool { settings.isEQEnabled }
    /// Output preamp in dB, `preampRange` (-24…0): attenuation only.
    /// Applied (15 ms ramp) with the EQ on and off.
    var preampDecibels: Double { settings.preampDecibels }
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
    /// the running session's; when stopped, the nominal rate of the macOS
    /// default output (read with the device list), or `idleSampleRate`.
    private(set) var eqSampleRate: Double = AudioEngineController.idleSampleRate
    static let idleSampleRate: Double = 48_000
    /// Set at launch when the saved settings could not be read completely
    /// (a backup copy was kept). Italian, for the UI; nil otherwise.
    private(set) var settingsNotice: String?

    /// Result of the last REW import: warnings (skipped filters, other
    /// equaliser…), a one-line summary on success, an error otherwise.
    private(set) var lastImportWarnings: [String] = []
    private(set) var lastImportSummary: String?
    private(set) var lastImportError: String?
    /// True while a file is being read.
    private(set) var isImporting = false

    // MARK: Stage 4 state (extensions at the bottom of this file)

    /// Everything persisted (read-only for views: use the documented API).
    private(set) var settings: AppSettings
    /// Last error of a settings action (output, sample rate, login item,
    /// exclusions, saving), Italian; nil when fine. `clearSettingsError()` resets it.
    private(set) var lastSettingsError: String?
    /// Rates the output device offers (standard rates inside its ranges).
    private(set) var availableSampleRates: [Double] = []
    /// True while a sample-rate change requested by the user is in progress.
    private(set) var isChangingSampleRate = false
    /// True while the macOS default output is being changed from the panel.
    private(set) var isChangingOutputDevice = false
    /// "Open at login" status (refresh with `refreshLaunchAtLoginStatus()`).
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    /// True while (un)registering the login item.
    private(set) var isChangingLaunchAtLogin = false
    /// Apps that could be excluded (refresh with `refreshCandidateApps()`).
    private(set) var candidateApps: [AppInfo] = []
    /// Excluded apps with display info (RoomEQ itself never listed).
    private(set) var excludedApps: [ExcludedApp] = []
    /// Italian note about the last automatic per-output preset switch
    /// (e.g. "Uscita «Cuffie»: applicato il preset «Cuffie»"); cleared after
    /// 20 s, on an output change that switches nothing, or on a manual preset.
    private(set) var lastAutomaticPresetSwitch: String?

    // MARK: Private

    @ObservationIgnored private let engine = AudioEngine()
    /// HAL reads/writes for devices happen here, never on the main thread.
    @ObservationIgnored private let deviceQueue = DispatchQueue(
        label: "com.federicociapi.RoomEQ.devices", qos: .userInitiated)
    /// Slow device operations (waiting for a sample-rate change) run here,
    /// so they never delay device-list reads on `deviceQueue`.
    @ObservationIgnored private let slowDeviceQueue = DispatchQueue(
        label: "com.federicociapi.RoomEQ.devices.slow", qos: .userInitiated)
    /// SMAppService calls (they can block) run here.
    @ObservationIgnored private let loginItemQueue = DispatchQueue(
        label: "com.federicociapi.RoomEQ.loginitem", qos: .userInitiated)
    @ObservationIgnored private var renderState: RenderStateHandle?
    @ObservationIgnored private var link: SplitLinkHandle?
    /// ID of the engine session this controller considers running.
    @ObservationIgnored private var activeSessionID: Int?
    /// The session replaced by the last restart, and when: a fatal error it
    /// reports right after is still shown (it would otherwise be masked).
    @ObservationIgnored private var replacedSessionID: Int?
    @ObservationIgnored private var replacedSessionDate: Date?
    /// When the user last changed the device sample rate (the restart that
    /// follows is not counted as an automatic one).
    @ObservationIgnored private var userSampleRateChangeDate: Date?
    /// One start retry is allowed right after a user sample-rate change.
    @ObservationIgnored private var rateChangeRetryAvailable = false
    /// "non è passato a…" message, cleared if the device reaches the rate later.
    @ObservationIgnored private var pendingRateMessage: (message: String, rate: Double, uid: String)?
    /// Retry window: until this time a failed start is retried instead of
    /// failing (see the header). Nil = no window.
    @ObservationIgnored private var startRetryDeadline: Date?
    /// Launch generation of the retry being waited for: waiting iff it
    /// equals `launchGeneration` (any new launch, stop, pause or failure
    /// changes the generation, which ends the wait by itself).
    @ObservationIgnored private var retryWaitGeneration: Int?
    static let startRetryWindow: TimeInterval = 30
    /// Pause between attempts (each attempt takes about 1 s more itself).
    static let startRetryDelay: TimeInterval = 1.5
    @ObservationIgnored private var automaticNoteClear: DispatchWorkItem?
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    /// Cumulative clip counters at the last reset (see `clipStatus`).
    @ObservationIgnored private var clipBaseline = ClipCounters.zero
    /// Nominal-rate listener on the current macOS default output.
    @ObservationIgnored private var rateListener: PropertyListener?
    @ObservationIgnored private var rateListenerGeneration = 0
    /// Output of the last automatic pause (read via `pausedOutputName`).
    private var pausedDeviceName: String?
    /// RoomEQ's bundle ID (always excluded, never listed).
    static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.federicociapi.RoomEQ"
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
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    static let saveDelay: TimeInterval = 0.5

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let loaded = AppSettings.load(
            current: userDefaults.data(forKey: AppSettings.storageKey),
            legacy: userDefaults.data(forKey: EQSettings.storageKey), ownBundleID: Self.ownBundleID)
        // Keep unreadable raw data BEFORE anything can save over it: once per
        // distinct content, at most 5 backups (oldest dropped).
        var existing: [String: Data] = [:]
        for (key, value) in userDefaults.dictionaryRepresentation() where SettingsBackups.isBackupKey(key) {
            if let data = value as? Data { existing[key] = data }
        }
        let plan = SettingsBackups.plan(
            existing: existing, adding: loaded.backups, timestamp: Int(Date().timeIntervalSince1970))
        for (key, data) in plan.writes {
            userDefaults.set(data, forKey: key)
            Log.app.error("Saved settings not fully readable; raw data kept in \(key, privacy: .public)")
        }
        for key in plan.deletions { userDefaults.removeObject(forKey: key) }
        if !loaded.warnings.isEmpty {
            Log.app.error("Settings load: \(loaded.warnings.joined(separator: "; "), privacy: .public)")
        }
        settings = loaded.settings
        bufferSize = loaded.settings.bufferFrames
        eqDesign = EQDesign(bands: loaded.settings.bands, sampleRate: Self.idleSampleRate)
        // The notice is shown once per distinct unreadable content.
        settingsNotice = plan.hasNewContent ? loaded.notice : nil
        refreshExcludedApps()
        updateEQ()
        if loaded.migrated {
            Log.app.notice("Settings migrated from stage 3 (preset «\(AppSettings.firstPresetName, privacy: .public)»)")
            writeSettings()  // the new document exists from now on
        }
    }

    /// Call once at launch: device list and device-change listeners
    /// (device list + macOS default output).
    func prepare() {
        guard !prepared else { return }
        prepared = true
        engine.eventHandler = { [weak self] event in self?.handle(event) }
        refreshLaunchAtLoginStatus()
        if settings.autoStartEngineOnLaunch {
            // At login the HAL / the output device may not be ready yet:
            // keep trying for up to 30 s.
            startRetryDeadline = Date().addingTimeInterval(Self.startRetryWindow)
        }
        refreshDevices { [weak self] in self?.attemptStartRetry() }
        // HAL listener registration can block briefly: done off the main
        // thread; the handlers run on main.
        deviceQueue.async { [weak self] in
            let system = AudioObjectID(kAudioObjectSystemObject)
            var listeners: [PropertyListener] = []
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
                do {
                    listeners.append(
                        try PropertyListener(object: system, address: AudioObject.address(selector), queue: .main) {
                            [weak self] in
                            MainActor.assumeIsolated { self?.refreshDevices() }
                        })
                } catch {
                    Log.devices.error("Device listener: \(error.localizedDescription, privacy: .public)")
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deviceListeners = listeners }
            }
        }
    }

    /// Auto-start at launch: starts once a default output exists (checked
    /// every 2 s until `startRetryDeadline`); a start that then fails is
    /// retried by `retryWithinWindow`. Never counted as automatic restarts.
    private func attemptStartRetry() {
        guard let deadline = startRetryDeadline else { return }
        guard Date() < deadline else {
            startRetryDeadline = nil
            Log.app.error("Start retries gave up after 30 s")
            return
        }
        guard state == .stopped || state == .failed else { return }
        guard systemOutputDevice != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refreshDevices { [weak self] in self?.attemptStartRetry() }
            }
            return
        }
        Log.app.info("Auto-start at launch")
        start()
    }

    // MARK: Start / stop

    func start() {
        guard state == .stopped || state == .failed else { return }
        isSwitchedOn = true
        automaticRestarts.removeAll()
        audioCapturePermissionLikelyDenied = false
        lastError = nil
        state = .starting
        status = "Avvio…"
        let generation = invalidatePendingLaunches()
        refreshDevices { [weak self] in
            guard let self, self.state == .starting, self.launchGeneration == generation else { return }
            guard let device = self.systemOutputDevice else {
                let noOutput = "Nessun dispositivo di uscita di macOS disponibile"
                if !self.retryWithinWindow(after: noOutput) { self.fail(noOutput) }
                return
            }
            self.launch(on: device, statusText: "Avvio su \(device.name)…")
        }
    }

    /// Stops the engine. Also works from `.failed` (makes sure nothing is
    /// left) and `.paused` (switches off).
    func stop() {
        guard state == .running || state == .starting || state == .failed || state == .paused else { return }
        isSwitchedOn = false
        startRetryDeadline = nil
        rateChangeRetryAvailable = false
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
        isSwitchedOn ? stop() : start()
    }

    /// Synchronous shutdown for app termination and SIGINT/SIGTERM: returns
    /// once the IOProcs, the aggregate and the tap are destroyed.
    func shutdown() {
        flushPendingSave()
        // shutdown() may be followed by exit(0) (signals): make sure the
        // preferences reach the disk first.
        userDefaults.synchronize()
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        invalidatePendingLaunches()
        clearActiveSession()
        engine.stopSynchronously()
        isSwitchedOn = false
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
        if let uid = effectiveOutputDevice?.uid, settings.outputPairs[uid] != pair.left {
            settings.outputPairs[uid] = pair.left  // remembered per output device
            saveSettings()
        }
    }

    /// The channel pair remembered for `device` (1–2 if none or not available).
    private func rememberedPair(for device: OutputDeviceInfo) -> OutputChannelPair {
        let pair = settings.outputPairs[device.uid].map { OutputChannelPair(left: $0) } ?? .firstPair
        return OutputChannelPair.available(forChannelCount: device.outputChannelCount).contains(pair) ? pair : .firstPair
    }

    /// Restarts the engine if running (the delay is re-measured for the new
    /// buffer size).
    func setBufferSize(_ frames: Int) {
        guard frames != bufferSize else { return }
        bufferSize = frames
        settings.bufferFrames = frames  // remembered across launches
        saveSettings()
        restartIfActive(reason: "buffer \(frames)")
    }

    // MARK: EQ settings (all applied live and saved)

    /// Preamp in dB, clamped to -24…0 (NaN ignored). Applied smoothly (15 ms
    /// ramp). Also resets the clip indicators: what was measured at the old
    /// preamp (and `suggestedPreampForClipping`) no longer applies.
    func setPreamp(_ decibels: Double) {
        guard let value = Preamp.clamp(decibels), value != preampDecibels else { return }
        settings.preampDecibels = value
        renderState?.setPreamp(decibels: value)
        resetClipIndicators()
        saveSettings()
    }

    /// Clears the CLIP indicator: counts and max levels start again from now.
    func resetClipIndicators() {
        clipBaseline = renderState?.resetClipMaxima() ?? .zero
        if clipStatus != .none { clipStatus = .none }
    }

    /// EQ on/off (10 ms crossfade to/from the original signal).
    func setEQEnabled(_ enabled: Bool) {
        guard enabled != isEQEnabled else { return }
        settings.isEQEnabled = enabled
        renderState?.setBypass(!enabled)
        saveSettings()
    }

    /// Updates the band with the same ID (unknown IDs are ignored). Only
    /// the fields that differ from the current band are taken, each clamped
    /// to `EQBand.frequencyRange` / `gainRange` / `qRange` (non-finite
    /// values ignored); untouched fields stay as they are, even if out of
    /// range (`EQBand.applyingEdit`). Fine for continuous slider drags: the
    /// band ramps towards the latest value (30 ms).
    func setBand(_ band: EQBand) {
        guard let index = bands.firstIndex(where: { $0.id == band.id }) else { return }
        let updated = bands[index].applyingEdit(band)
        guard bands[index] != updated else { return }
        settings.bands[index] = updated
        workingStateChanged()
    }

    func setBandEnabled(id: EQBand.ID, _ enabled: Bool) {
        guard let index = bands.firstIndex(where: { $0.id == id }), bands[index].isEnabled != enabled else { return }
        settings.bands[index].isEnabled = enabled
        workingStateChanged()
    }

    func removeBand(id: EQBand.ID) {
        guard let index = bands.firstIndex(where: { $0.id == id }) else { return }
        settings.bands.remove(at: index)
        workingStateChanged()
    }

    /// Appends a neutral band (1 kHz, 0 dB, Q 1). Returns nil (and changes
    /// nothing) when there are already `EQBand.maximumCount` bands.
    @discardableResult
    func addBand() -> EQBand? {
        guard bands.count < EQBand.maximumCount else { return nil }
        let band = EQBand.neutral()
        settings.bands.append(band)
        workingStateChanged()
        return band
    }

    /// Back to the user's REW measurement filters (preamp and EQ on/off
    /// unchanged). Marks the active preset as modified (not saved into it).
    func resetToDefaultFilters() {
        settings.bands = EQBand.defaultBands()
        workingStateChanged()
    }

    /// Combined EQ response in dB at each frequency (Hz), for drawing.
    /// Uses `eqSampleRate` (running session's rate, else the default output's).
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
            let rates = systemOutput.map { AudioDevices.availableSampleRates(of: $0.objectID) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if rates != self.availableSampleRates { self.availableSampleRates = rates }
                    self.applyDeviceList(devices, systemOutput: systemOutput)
                    completion?()
                }
            }
        }
    }

    // MARK: Internals

    private func applyDeviceList(_ devices: [OutputDeviceInfo], systemOutput: OutputDeviceInfo?) {
        let previousOutput = systemOutputDevice
        if devices != outputDevices { outputDevices = devices }
        if systemOutput?.objectID != systemOutputDevice?.objectID { watchSampleRate(of: systemOutput) }
        if systemOutput != systemOutputDevice {
            systemOutputDevice = systemOutput
            if renderState == nil {
                updateEQ()  // idle rate may have changed
                if let systemOutput { outputChannelPair = rememberedPair(for: systemOutput) }
            }
        }
        clearStaleRateMessage()
        // Per-output presets BEFORE following the output, so the new
        // session starts with the new output's preset.
        applyPresetForOutput(systemOutput)
        rememberDeviceNames(devices + [previousOutput].compactMap { $0 })
        applyOutputMode(outputChanged: systemOutput?.uid != previousOutput?.uid)
        followSystemOutputIfNeeded()
    }

    /// Refreshes the device info (rate, available rates) when the default
    /// output's nominal sample rate changes, also while stopped. The HAL
    /// listener is (un)registered off the main thread.
    private func watchSampleRate(of device: OutputDeviceInfo?) {
        rateListenerGeneration += 1
        let generation = rateListenerGeneration
        let old = rateListener
        rateListener = nil
        deviceQueue.async { [weak self] in
            old?.remove()
            guard let device else { return }
            var listener: PropertyListener?
            do {
                listener = try PropertyListener(
                    object: device.objectID, address: AudioObject.address(kAudioDevicePropertyNominalSampleRate),
                    queue: .main
                ) { [weak self] in
                    MainActor.assumeIsolated { self?.refreshDevices() }
                }
            } catch {
                Log.devices.warning("Rate listener: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.rateListenerGeneration == generation else {
                        // Superseded meanwhile: unregister it again (off main).
                        if let listener { self?.deviceQueue.async { listener.remove() } }
                        return
                    }
                    self.rateListener = listener
                }
            }
        }
    }

    /// Pauses or resumes according to the switch and the per-output rule of
    /// the macOS default output (`AppSettings.engineMode`). Paused: resumes
    /// on an output with correction. Failed (switch still on): pauses on a
    /// "no correction" output, and tries again only when the default output
    /// itself changed (`outputChanged`: never on mere device-list refreshes,
    /// which a failing start causes itself). With no default output a pause
    /// just waits.
    private func applyOutputMode(outputChanged: Bool) {
        guard let output = systemOutputDevice else { return }
        switch settings.engineMode(userWantsOn: isSwitchedOn, outputUID: output.uid) {
        case .off:
            return
        case .paused:
            pause(on: output)
        case .active:
            // Waiting to retry on the old output: start over on the new one.
            let newOutputWhileWaiting = outputChanged && isWaitingForRetry
            guard state == .paused || (state == .failed && outputChanged) || newOutputWhileWaiting else { return }
            Log.app.info("Resuming on \(output.uid, privacy: .public) (has correction)")
            // A fresh start with a retry window; not an automatic restart.
            openRetryWindow()
            automaticRestarts.removeAll()
            audioCapturePermissionLikelyDenied = false
            launch(on: output, statusText: "Riprendo su \(output.name)…")
        }
    }

    /// Automatic pause for `device` ("no correction"): the session is torn
    /// down as by `stop()` (tap, aggregate, IOProcs released on the engine
    /// queue, apps heard directly), but the state goes to `.paused` at once
    /// and the switch stays on. Not counted as an error or an automatic
    /// restart. Already paused: only the output name changes.
    private func pause(on device: OutputDeviceInfo) {
        if pausedDeviceName != device.name { pausedDeviceName = device.name }
        let text = "In pausa: nessuna correzione per \(device.name)"
        if status != text { status = text }
        guard state != .paused else { return }
        Log.app.info("Pausing: no correction for \(device.uid, privacy: .public)")
        startRetryDeadline = nil  // the start request is satisfied (or no longer wanted)
        rateChangeRetryAvailable = false
        replacedSessionID = nil  // a late failure of it must not count now
        replacedSessionDate = nil
        invalidatePendingLaunches()
        clearActiveSession()
        // Queued on the engine queue: a later start always runs after it.
        engine.stop()
        state = .paused
        lastError = nil
    }

    /// When the macOS default output changes while running, move RoomEQ to it.
    private func followSystemOutputIfNeeded() {
        guard isRunning, let system = systemOutputDevice, let active = activeOutputDevice, system.uid != active.uid
        else { return }
        // A deliberate change (the user picked another output in macOS):
        // not counted toward the automatic-restart limit. The new device
        // may have just been switched on: retry window.
        openRetryWindow()
        restartIfActive(reason: "uscita di macOS ora \(system.name)")
    }

    /// Opens (or renews) the retry window for the start that follows.
    private func openRetryWindow() {
        startRetryDeadline = Date().addingTimeInterval(Self.startRetryWindow)
    }

    private var isWaitingForRetry: Bool { state == .starting && retryWaitGeneration == launchGeneration }

    /// Inside the retry window, a failed start (or no output yet) is retried
    /// after `startRetryDelay`, staying `.starting` with no error shown (it
    /// is logged). False when there is no window or it is over: the caller
    /// fails. The retry is bound to a new launch generation, so it is the
    /// only chain: stop, pause, a new launch (output change, settings) or a
    /// failure cancels it, and a start while waiting is ignored (`.starting`).
    private func retryWithinWindow(after message: String) -> Bool {
        guard let deadline = startRetryDeadline else { return false }
        guard Date().addingTimeInterval(Self.startRetryDelay) < deadline else {
            startRetryDeadline = nil
            Log.app.error("Start retries gave up (window over): \(message, privacy: .public)")
            return false
        }
        Log.app.notice("Start failed inside the retry window (\(message, privacy: .public)); retrying")
        let name = systemOutputDevice?.name
        state = .starting
        status = name.map { "Attendo che l'uscita «\($0)» sia pronta…" } ?? "Attendo un'uscita audio…"
        lastError = nil
        let generation = invalidatePendingLaunches()
        retryWaitGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startRetryDelay) { [weak self] in
            guard let self, self.isWaitingForRetry, self.launchGeneration == generation else { return }
            self.refreshDevices { [weak self] in
                // The refresh may have paused, or started over on a new output.
                guard let self, self.isWaitingForRetry, self.launchGeneration == generation else { return }
                guard let device = self.systemOutputDevice else {
                    let noOutput = "Nessun dispositivo di uscita di macOS disponibile"
                    if !self.retryWithinWindow(after: noOutput) { self.fail(noOutput) }
                    return
                }
                self.launch(on: device, statusText: "Attendo che l'uscita «\(device.name)» sia pronta…")
            }
        }
        return true
    }

    private func configuration(for device: OutputDeviceInfo) -> EngineConfiguration {
        EngineConfiguration(
            outputDeviceUID: device.uid,
            outputPair: outputChannelPair,
            bufferFrames: bufferSize,
            excludedBundleIDs: excludedBundleIDs,
            gain: Preamp.linearGain(decibels: preampDecibels) ?? 1,
            bypass: !isEQEnabled,
            bands: bands,
            processListFallbackEnabled: !userDefaults.bool(forKey: "DisableProcessExclusionFallback"))
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
        clipBaseline = .zero  // a new session starts with fresh counters
        if clipStatus != .none { clipStatus = .none }
        updateEQ()  // back to the idle sample rate
    }

    /// Starts a session on `device` (the macOS default output), replacing
    /// the current one; pauses instead when `device` is set to "no
    /// correction" (every start and restart goes through here).
    private func launch(on device: OutputDeviceInfo, statusText: String) {
        if settings.engineMode(userWantsOn: true, outputUID: device.uid) == .paused {
            pause(on: device)
            return
        }
        if let activeSessionID {
            // A fatal error this session reports in the next seconds must
            // not be masked by the restart (see `handle(.fatal)`).
            replacedSessionID = activeSessionID
            replacedSessionDate = Date()
        }
        clearActiveSession()
        state = .starting
        status = statusText
        lastError = nil
        outputChannelPair = rememberedPair(for: device)  // remembered per output device
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
            startRetryDeadline = nil
            rateChangeRetryAvailable = false
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
            if retryAfterSampleRateChange(error) { return }
            if error is AudioCapturePermissionError {
                audioCapturePermissionLikelyDenied = true
                startRetryDeadline = nil  // retrying won't help
            }
            // The HAL / a device just switched on may not be ready yet.
            if retryWithinWindow(after: error.localizedDescription) { return }
            fail(error.localizedDescription)
        }
    }

    /// Right after a user sample-rate change the HAL may still be settling
    /// and the no-conversion check can fail once: retry one time (not
    /// counted as an automatic restart). True if a retry was scheduled.
    private func retryAfterSampleRateChange(_ error: Error) -> Bool {
        guard rateChangeRetryAvailable, let change = userSampleRateChangeDate, Date().timeIntervalSince(change) < 8
        else { return false }
        rateChangeRetryAvailable = false
        Log.app.notice("Start failed right after a sample-rate change (\(error.localizedDescription, privacy: .public)); retrying once")
        state = .starting
        status = "Riprovo dopo il cambio di frequenza…"
        let generation = invalidatePendingLaunches()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.state == .starting, self.launchGeneration == generation else { return }
            self.refreshDevices { [weak self] in
                guard let self, self.state == .starting, self.launchGeneration == generation else { return }
                guard let device = self.systemOutputDevice else {
                    self.fail("Nessun dispositivo di uscita di macOS disponibile")
                    return
                }
                self.launch(on: device, statusText: "Avvio su \(device.name)…")
            }
        }
        return true
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
                self.openRetryWindow()  // the new output may not be ready yet
                self.launch(on: device, statusText: "Avvio su \(device.name)…")
                if self.state == .starting { self.lastError = "\(name) è stato scollegato: audio su \(device.name)" }
            }

        case .latencyChanged(let sessionID, let latency):
            guard sessionID == activeSessionID else { return }
            self.latency = latency

        case .fatal(let sessionID, let message):
            // The engine already stopped the session (apps unmuted).
            if sessionID == activeSessionID {
                fail(message)
            } else if sessionID == replacedSessionID, let date = replacedSessionDate, Date().timeIntervalSince(date) < 2 {
                // The session that a restart just replaced had failed: show
                // it, and count it, so a failure loop can't hide behind
                // restarts.
                Log.app.error("Replaced session \(sessionID) had failed: \(message, privacy: .public)")
                lastError = "La sessione precedente si era interrotta: \(message)"
                if !countAutomaticRestart() { fail("Troppi riavvii automatici (\(message))") }
            }
        }
    }

    /// Records an automatic restart; false when there were more than 3 in 10 s.
    private func countAutomaticRestart() -> Bool {
        let now = Date()
        automaticRestarts = automaticRestarts.filter { now.timeIntervalSince($0) < 10 } + [now]
        return automaticRestarts.count <= 3
    }

    /// Restart requested by the system (format/layout change, IO problem).
    /// At most 3 in 10 s, to avoid restart loops. User-initiated restarts
    /// (buffer, exclusions, macOS output change) call `restartIfActive`
    /// directly and are not counted.
    private func automaticRestart(reason: String) {
        let now = Date()
        if let userChange = userSampleRateChangeDate, now.timeIntervalSince(userChange) < 5 {
            // Caused by the user's own sample-rate change: not "automatic".
            restartIfActive(reason: reason)
            return
        }
        guard countAutomaticRestart() else {
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
    /// Ends any retry window (the next start, if any, opens its own).
    private func fail(_ message: String) {
        Log.app.error("Engine error: \(message, privacy: .public)")
        startRetryDeadline = nil
        invalidatePendingLaunches()
        clearActiveSession()
        engine.stop()
        state = .failed
        lastError = message
        status = "Errore: \(message)"
    }

    // MARK: EQ internals

    /// The working bands and/or preamp changed (edit, preset, automatic
    /// per-output switch, restored edits, import): publish BOTH to the
    /// audio thread (see `updateEQ`) and save.
    private func workingStateChanged() {
        updateEQ()
        saveSettings()
    }

    /// Rate used while stopped: the default output's nominal rate (so the
    /// warnings match what the next start will use), else 48 kHz.
    private var idleRate: Double { systemOutputDevice?.nominalSampleRate ?? Self.idleSampleRate }

    /// Recomputes the design for the current rate, hands the working state
    /// (filters AND preamp, `publishWorkingState`) to the audio thread if
    /// running, and refreshes the derived values.
    private func updateEQ() {
        let rate = renderState?.configuration.sampleRate ?? idleRate
        let design = renderState?.publishWorkingState(bands: bands, preampDecibels: preampDecibels)
            ?? EQDesign(bands: bands, sampleRate: rate)
        if design != eqDesign { eqDesign = design }
        if rate != eqSampleRate { eqSampleRate = rate }
        if design.issues != bandIssues { bandIssues = design.issues }
        if design.warnings != filterWarnings { filterWarnings = design.warnings }
        let boost = EQCurve.maximumBoostDecibels(design: design)
        if boost != maxCurveBoostDecibels { maxCurveBoostDecibels = boost }
        let suggested = EQCurve.suggestedPreampDecibels(forMaximumBoost: boost)
        if suggested != suggestedPreampDecibels { suggestedPreampDecibels = suggested }
    }

    /// Debounced: writes 0,5 s after the last change (a slider drag makes
    /// one write, not hundreds). `flushPendingSave` writes immediately.
    private func saveSettings() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeSettings() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Writes a pending save now (called on quit).
    func flushPendingSave() {
        guard let work = pendingSave, !work.isCancelled else { return }
        work.cancel()
        writeSettings()
    }

    private func writeSettings() {
        pendingSave = nil
        do {
            userDefaults.set(try settings.encoded(), forKey: AppSettings.storageKey)
        } catch {
            Log.app.error("Saving settings failed: \(error.localizedDescription, privacy: .public)")
            lastSettingsError = "Impossibile salvare le impostazioni: \(error.localizedDescription)"
        }
    }

    private func finishImport(_ result: Result<REWImportResult, Error>, fileName: String, generation: Int) {
        guard generation == importGeneration else { return }  // a newer import is running
        isImporting = false
        switch result {
        case .success(let imported):
            settings.bands = imported.bands
            workingStateChanged()
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
        let clips = ClipStatus(counters: renderState.readClipCounters(), baseline: clipBaseline)
        if clips != clipStatus { clipStatus = clips }
    }
}

// MARK: - Presets
//
// Presets and per-output presets (stage 4). Logic in RoomEQCore
// (Presets.swift); here it is applied to the engine and saved.
//
// Applying a preset only replaces the working bands/preamp: they reach the
// audio thread like any edit, so every band ramps (30 ms, click-free).
// Editing after applying marks the preset modified; nothing is saved into
// a preset unless the user asks (`saveCurrentToActivePreset`). The working
// state itself is always persisted.

extension AudioEngineController {
    // MARK: Presets — state

    /// All presets, in display order (at least one).
    var presets: [EQPreset] { settings.presets }
    /// The preset the working state comes from (nil after deleting it).
    var activePresetID: UUID? { settings.activePresetID }
    var activePreset: EQPreset? { settings.activePreset }
    /// The working bands/preamp differ from the active preset (band IDs
    /// ignored). False when no preset is active.
    var isActivePresetModified: Bool { settings.isActivePresetModified }
    /// TRUE WHEN REPLACING THE CURRENT SOUND WOULD LOSE WORK: modified vs the
    /// active preset, or no active preset and the sound matches no preset
    /// (e.g. after deleting the active one). The UI must ask before
    /// `applyPreset`, `importREWFile`, `resetToDefaultFilters`; "Salva" with
    /// no active preset must go to "Salva come…".
    var hasUnsavedChanges: Bool { settings.hasUnsavedChanges }
    /// A free name ("Senza nome", "Senza nome 2"…) for saving without asking.
    var suggestedNewPresetName: String { settings.suggestedNewPresetName }

    // MARK: Presets — actions (errors: `PresetError`, Italian messages)

    /// Loads a preset (replaces the current sound: ask the user first if
    /// `hasUnsavedChanges`). Click-free (bands and preamp ramp). EQ on/off
    /// is not touched.
    func applyPreset(id: UUID) throws {
        try settings.applyPreset(id: id)
        showAutomaticNote(nil)
        workingStateChanged()
    }

    /// Saves the working state as a new preset (validated name) and makes
    /// it active.
    @discardableResult
    func saveCurrentAsNewPreset(name: String) throws -> EQPreset {
        let preset = try settings.saveCurrentAsNewPreset(name: name)
        saveSettings()
        return preset
    }

    /// Overwrites the active preset with the working state.
    func saveCurrentToActivePreset() throws {
        try settings.saveCurrentToActivePreset()
        saveSettings()
    }

    /// Renames (trimmed, non-empty, at most 40 characters, unique ignoring
    /// case and accents).
    func renamePreset(id: UUID, name: String) throws {
        try settings.renamePreset(id: id, name: name)
        saveSettings()
    }

    /// Deletes a preset (never the last). Deleting the active one leaves
    /// the sound unchanged with no active preset; its output assignments
    /// are removed.
    func deletePreset(id: UUID) throws {
        try settings.deletePreset(id: id)
        saveSettings()
    }

    /// Copy named "<name> copia" placed after the original; not activated.
    @discardableResult
    func duplicatePreset(id: UUID) throws -> EQPreset {
        let copy = try settings.duplicatePreset(id: id)
        saveSettings()
        return copy
    }

    /// Italian error for a proposed name (live validation in a text field),
    /// nil if valid. `excluding`: the preset being renamed.
    func presetNameError(_ name: String, excluding id: UUID? = nil) -> String? {
        do {
            _ = try settings.validatedPresetName(name, excluding: id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Per-output presets

    /// Option (default off): when the macOS output changes to a device with
    /// an assigned preset, apply it automatically (see `outputDidChange` in
    /// RoomEQCore: unsaved edits are remembered per output and restored when
    /// coming back). Takes effect at the next output change; "no correction"
    /// (pause) takes effect at once.
    var isPresetPerOutputEnabled: Bool { settings.isPresetPerOutputEnabled }
    /// Device UID -> preset ID.
    var presetAssignments: [String: UUID] { settings.presetAssignments }
    /// Device UIDs set to "no correction".
    var noCorrectionOutputs: Set<String> { settings.noCorrectionOutputs }

    /// On: pauses at once if the current output has "no correction"; off:
    /// resumes if paused.
    func setPresetPerOutputEnabled(_ enabled: Bool) {
        guard enabled != settings.isPresetPerOutputEnabled else { return }
        settings.isPresetPerOutputEnabled = enabled
        // Start tracking from the current output.
        settings.startTrackingOutput(systemOutputDevice?.uid)
        saveSettings()
        applyOutputMode(outputChanged: false)
    }

    /// Replaces any rule of that output. If it is the current output and
    /// it had "no correction" (option on), the preset is applied at once,
    /// always (unsaved changes are remembered per output, never lost) and
    /// RoomEQ resumes if it was paused; otherwise, as before, it takes
    /// effect at the next output change.
    func assignPreset(id: UUID, toDeviceUID uid: String) throws {
        let wasNoCorrection = settings.noCorrectionOutputs.contains(uid)
        try settings.assignPreset(id: id, toDeviceUID: uid)
        outputRuleChanged(deviceUID: uid, leftNoCorrection: wasNoCorrection)
    }

    /// "Nessuna correzione" for that output (replaces its preset). If it is
    /// the current output (and the option is on), RoomEQ pauses at once.
    func assignNoCorrection(toDeviceUID uid: String) {
        guard !uid.isEmpty, !settings.noCorrectionOutputs.contains(uid) else { return }
        settings.assignNoCorrection(toDeviceUID: uid)
        outputRuleChanged(deviceUID: uid, leftNoCorrection: false)
    }

    /// No rule for that output (neither a preset nor "no correction"). If
    /// RoomEQ was paused for it, it resumes.
    func clearAssignment(deviceUID uid: String) {
        let wasNoCorrection = settings.noCorrectionOutputs.contains(uid)
        guard settings.presetAssignments[uid] != nil || wasNoCorrection else { return }
        settings.clearAssignment(deviceUID: uid)
        outputRuleChanged(deviceUID: uid, leftNoCorrection: wasNoCorrection)
    }

    /// After a rule change: remember the name, save, and apply it at once
    /// when it concerns the current output. Leaving "no correction" there
    /// applies its preset now (`noCorrectionLifted` in RoomEQCore), then
    /// pauses/resumes as the new rule says.
    private func outputRuleChanged(deviceUID uid: String, leftNoCorrection: Bool) {
        if let device = outputDevices.first(where: { $0.uid == uid }), settings.outputsWithRules.contains(uid) {
            settings.deviceNames[uid] = device.name
        }
        saveSettings()
        guard let output = systemOutputDevice, output.uid == uid else { return }
        if leftNoCorrection { showOutputSwitch(settings.noCorrectionLifted(onCurrentOutput: uid), on: output) }
        applyOutputMode(outputChanged: false)
    }

    /// Outputs to show in the assignment list: every connected output, plus
    /// remembered ones (with a preset, "no correction" or remembered edits)
    /// that are not connected. Stable order: by name, then UID.
    /// Limitation: outputs are identified by their Core Audio UID; a device
    /// whose UID changes appears as a new output (assign it again).
    var knownOutputs: [KnownOutput] {
        let connected = Set(outputDevices.map(\.uid))
        var uids = outputDevices.map(\.uid)
        for uid in settings.outputsWithRules where !connected.contains(uid) {
            uids.append(uid)
        }
        let existing = Set(settings.presets.map(\.id))
        return uids.map { uid in
            KnownOutput(
                uid: uid,
                name: outputDevices.first { $0.uid == uid }?.name ?? settings.deviceNames[uid] ?? uid,
                isConnected: connected.contains(uid),
                assignedPresetID: settings.presetAssignments[uid].flatMap { existing.contains($0) ? $0 : nil },
                isNoCorrection: settings.noCorrectionOutputs.contains(uid),
                hasRememberedEdits: settings.editsByDevice[uid] != nil)
        }
        .sorted { ($0.name.lowercased(), $0.uid) < ($1.name.lowercased(), $1.uid) }
    }

    /// Keeps names only for outputs that need one when unplugged (a rule or
    /// remembered edits), and drops the others.
    private func rememberDeviceNames(_ devices: [OutputDeviceInfo]) {
        let before = settings.deviceNames
        let needed = settings.outputsWithRules
        for device in devices where needed.contains(device.uid) { settings.deviceNames[device.uid] = device.name }
        settings.pruneDeviceNames()
        if settings.deviceNames != before { saveSettings() }
    }

    /// The macOS default output may have changed (also at launch): applies
    /// the per-output rules before the engine follows the new output.
    private func applyPresetForOutput(_ output: OutputDeviceInfo?) {
        // Same output: nothing to do (and nothing to save on every refresh).
        guard let output, output.uid != settings.lastOutputDeviceUID else { return }
        showOutputSwitch(settings.outputDidChange(to: output.uid), on: output)
    }

    /// Applies and announces what a per-output switch did to the working state.
    private func showOutputSwitch(_ outcome: AppSettings.OutputSwitch, on output: OutputDeviceInfo) {
        func presetName(_ id: UUID?) -> String? { id.flatMap { id in settings.presets.first { $0.id == id }?.name } }
        switch outcome {
        case .unchanged:
            showAutomaticNote(nil)
            saveSettings()  // lastOutputDeviceUID
        case .appliedPreset(let id):
            showAutomaticNote("Uscita «\(output.name)»: applicato il preset «\(presetName(id) ?? "?")»")
            Log.app.info("Per-output preset applied for \(output.uid, privacy: .public)")
            workingStateChanged()
        case .restoredEdits(let base, let assigned):
            var note = "Ripristinate le modifiche non salvate per «\(output.name)»"
            if let name = presetName(base) { note += " (basate su «\(name)»)" }
            if let name = presetName(assigned) { note += "; il preset assegnato è «\(name)»" }
            showAutomaticNote(note)
            Log.app.info("Per-output edits restored for \(output.uid, privacy: .public)")
            workingStateChanged()
        case .noCorrection:
            showAutomaticNote(nil)  // nothing recorded, nothing to save; the pause follows
        }
    }

    /// Shows the automatic-switch note for 20 s (nil clears it now).
    private func showAutomaticNote(_ note: String?) {
        automaticNoteClear?.cancel()
        lastAutomaticPresetSwitch = note
        guard note != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.lastAutomaticPresetSwitch = nil }
        }
        automaticNoteClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    // MARK: Output device

    /// Output devices for the output menu: devices macOS accepts as default
    /// output, with at least 2 output channels, aggregates excluded (virtual
    /// devices included, transport "Virtuale"); the default is marked.
    var outputDeviceOptions: [OutputDeviceOption] {
        outputDevices.map {
            OutputDeviceOption(
                uid: $0.uid, name: $0.name, transportName: $0.transportName, outputChannelCount: $0.outputChannelCount,
                nominalSampleRate: $0.nominalSampleRate, isDefault: $0.uid == systemOutputDevice?.uid)
        }
    }

    /// Makes `uid` the macOS default output (an explicit user choice: it
    /// changes the output for every app) and checks that macOS switched.
    /// The alert/sound-effects output is never touched (macOS can make it
    /// follow the selected output by itself). RoomEQ then follows the new
    /// output (engine restart if running). Errors in `lastSettingsError`.
    func setSystemOutputDevice(uid: String) {
        guard let device = outputDevices.first(where: { $0.uid == uid }) else {
            lastSettingsError = "Dispositivo di uscita non trovato"
            return
        }
        guard uid != systemOutputDevice?.uid, !isChangingOutputDevice else { return }
        isChangingOutputDevice = true
        lastSettingsError = nil
        slowDeviceQueue.async { [weak self] in
            var message: String?
            do {
                try AudioDevices.setDefaultOutputDevice(device.objectID)
            } catch {
                message = "macOS non ha accettato «\(device.name)» come uscita (\(Self.reason(error)))"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isChangingOutputDevice = false
                    if let message { self.lastSettingsError = message }
                    self.refreshDevices()  // the default-output listener refreshes too
                }
            }
        }
    }

    // MARK: Sample rate

    /// The output device's current rate: the running session's, else the
    /// macOS default output's nominal rate.
    var currentSampleRate: Double? { isRunning ? sampleRate : systemOutputDevice?.nominalSampleRate }

    /// Sets the nominal sample rate of the macOS default output (explicit
    /// user action only; RoomEQ never changes it by itself). WARNING for the
    /// UI: this changes the rate for EVERY app using that device, Ableton
    /// included. RoomEQ never converts rates: the running engine rebuilds
    /// at the new rate (tap, device and capture all follow), the filters are
    /// recomputed; if that first start fails because the HAL is still
    /// settling, it is retried once. Refused while RoomEQ is starting or
    /// stopping. Errors in `lastSettingsError`.
    func setDeviceSampleRate(_ rate: Double) {
        guard let device = systemOutputDevice else {
            lastSettingsError = "Nessun dispositivo di uscita di macOS disponibile"
            return
        }
        switch state {
        case .starting:
            lastSettingsError = "Attendi che RoomEQ finisca di avviarsi"
            return
        case .stopping:
            lastSettingsError = "Attendi che RoomEQ finisca di fermarsi"
            return
        case .running, .stopped, .failed, .paused:
            break
        }
        guard SampleRates.contains(availableSampleRates, rate) else {
            lastSettingsError = "«\(device.name)» non offre \(AudioFormatText.kilohertz(rate))"
            return
        }
        guard !isChangingSampleRate, !(currentSampleRate.map { SampleRates.same($0, rate) } ?? false) else { return }
        let oldRate = currentSampleRate
        let wasRunning = state == .running
        isChangingSampleRate = true
        lastSettingsError = nil
        pendingRateMessage = nil
        userSampleRateChangeDate = Date()
        rateChangeRetryAvailable = wasRunning
        // The 2 s wait runs on its own queue, never delaying device-list reads.
        slowDeviceQueue.async { [weak self] in
            var message: String?
            do {
                try AudioDevices.setNominalSampleRate(rate, of: device.objectID)
                // The change is asynchronous in the HAL: wait (max 2 s).
                var reached = false
                for _ in 0..<40 {
                    if let now = try? AudioDevices.nominalSampleRate(of: device.objectID), SampleRates.same(now, rate) {
                        reached = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if !reached { message = "«\(device.name)» non è passato a \(AudioFormatText.kilohertz(rate))" }
            } catch {
                message = "«\(device.name)» non accetta \(AudioFormatText.kilohertz(rate)) (\(Self.reason(error)))"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isChangingSampleRate = false
                    if let message {
                        self.lastSettingsError = message
                        self.pendingRateMessage = (message, rate, device.uid)
                    }
                    self.userSampleRateChangeDate = Date()
                    self.refreshDevices { [weak self] in
                        guard let self, wasRunning, message == nil else { return }
                        // Normally the session's own listener has already
                        // asked for the rebuild; make sure it happens.
                        if self.state == .running, !(self.sampleRate.map { SampleRates.same($0, rate) } ?? false) {
                            self.restartIfActive(reason: "frequenza \(AudioFormatText.change(from: oldRate, to: rate))")
                        } else if self.state == .failed, self.rateChangeRetryAvailable {
                            // Failed before the retry window could catch it: start once more.
                            self.rateChangeRetryAvailable = false
                            self.start()
                        }
                    }
                }
            }
        }
    }

    /// Clears a "non è passato a…" error once the device reaches that rate
    /// later, or once another output is in use.
    private func clearStaleRateMessage() {
        guard let pending = pendingRateMessage else { return }
        let reached = systemOutputDevice?.uid == pending.uid
            && (systemOutputDevice?.nominalSampleRate.map { SampleRates.same($0, pending.rate) } ?? false)
        guard reached || systemOutputDevice?.uid != pending.uid else { return }
        if lastSettingsError == pending.message { lastSettingsError = nil }
        pendingRateMessage = nil
    }

    /// Short reason for a user message (no doubled "operation failed" prefix).
    nonisolated private static func reason(_ error: Error) -> String {
        (error as? CoreAudioError)?.shortDescription ?? error.localizedDescription
    }
}

// MARK: - Exclusions
//
// Apps excluded from the tap (stage 4). Rules in RoomEQCore (Exclusions.swift).
//
// Applying a change to a running engine:
//   * ADDING an app: live, by updating the tap description (the same
//     mechanism used since stage 2 for excluded apps started after the tap,
//     verified on hardware). If that fails: engine restart.
//   * REMOVING an app: engine restart (about 1 s of silence). Removing a
//     process from a live tap's exclusion list is not verified on hardware
//     yet, so the safe path is used. To try the live path:
//     `defaults write com.federicociapi.RoomEQ LiveExclusionRemoval -bool YES`
//     (it falls back to a restart if Core Audio refuses).
// Restarts caused by these user actions don't count toward the automatic
// restart limit.

extension AudioEngineController {
    /// Bundle IDs passed to the engine (RoomEQ's own is added by the tap).
    var excludedBundleIDs: [String] { settings.excludedApps.map(\.bundleID) }

    /// Warnings about the current exclusions (e.g. REW), Italian.
    var exclusionWarnings: [String] { excludedApps.compactMap(\.warning) }

    /// Warning(s) to show BEFORE excluding `bundleID`, one per line, nil if
    /// none: REW (measurements would bypass RoomEQ), or an ID so short that
    /// it would exclude many apps (e.g. "com.apple").
    func warningForExcluding(bundleID: String) -> String? {
        ExclusionRules.warning(forBundleID: bundleID, isInstalledApp: Self.installedApp(bundleID: bundleID) != nil)
    }

    /// Excludes an app (errors: `ExclusionError`, Italian). Allowed with a
    /// warning for REW and very short IDs (`warningForExcluding`). The
    /// installed app's own casing of the ID is stored when known (matching
    /// ignores case anyway). Applied live.
    func addExcludedApp(bundleID: String) throws {
        var id = try ExclusionRules.validateNew(bundleID, existing: settings.excludedApps, ownBundleID: Self.ownBundleID)
        let url = Self.installedApp(bundleID: id)
        if let canonical = url.flatMap({ Bundle(url: $0)?.bundleIdentifier }), ExclusionRules.same(canonical, id) {
            id = canonical
        }
        settings.excludedApps.append(ExcludedAppRecord(bundleID: id, name: url.map { Self.displayName(of: $0) } ?? id))
        exclusionsChanged(removal: false)
    }

    /// Same, keeping the name of an app picked in Finder / from `candidateApps`.
    func addExcludedApp(_ app: AppInfo) throws {
        let id = try ExclusionRules.validateNew(app.bundleID, existing: settings.excludedApps, ownBundleID: Self.ownBundleID)
        settings.excludedApps.append(ExcludedAppRecord(bundleID: id, name: app.name))
        exclusionsChanged(removal: false)
    }

    /// Stops excluding an app (engine restart if running, see the header).
    func removeExcludedApp(bundleID: String) {
        let before = settings.excludedApps.count
        settings.excludedApps.removeAll { ExclusionRules.same($0.bundleID, bundleID) }
        guard settings.excludedApps.count != before else { return }
        exclusionsChanged(removal: true)
    }

    /// Info about an app picked with NSOpenPanel (an .app bundle), nil if it
    /// has no bundle ID. Does not exclude it: pass it to `addExcludedApp(_:)`.
    func appInfo(forBundleURL url: URL) -> AppInfo? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
        return AppInfo(bundleID: id, name: Self.displayName(of: url), url: url, isRunning: running, isPlayingAudio: false)
    }

    /// Re-reads `candidateApps`: running regular apps (not RoomEQ, not
    /// already excluded), marked when they are playing audio; those first,
    /// then by name. The audio flag is read off the main thread.
    func refreshCandidateApps() {
        let excluded = settings.excludedApps.map(\.bundleID)
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> (String, String, URL?)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                !ExclusionRules.isOwn(id, ownBundleID: Self.ownBundleID),
                !excluded.contains(where: { ExclusionRules.same($0, id) })
            else { return nil }
            return (id, app.localizedName ?? id, app.bundleURL)
        }
        deviceQueue.async { [weak self] in
            let playing = Self.bundleIDsPlayingAudio()
            let apps = running.map { id, name, url in
                AppInfo(
                    bundleID: id, name: name, url: url, isRunning: true,
                    isPlayingAudio: playing.contains { AudioProcesses.bundleID($0, matches: id) })
            }
            .sorted { ($0.isPlayingAudio ? 0 : 1, $0.name.lowercased()) < ($1.isPlayingAudio ? 0 : 1, $1.name.lowercased()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.candidateApps = apps }
            }
        }
    }

    /// App icon for display (generic icon if the app is not installed).
    /// Cached per bundle ID (views ask for it on every redraw).
    func icon(forBundleID bundleID: String) -> NSImage {
        if let cached = iconCache[bundleID] { return cached }
        let icon = Self.installedApp(bundleID: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        iconCache[bundleID] = icon
        return icon
    }

    // MARK: Controller-internal

    /// Rebuilds `excludedApps` (display names, install state, warnings).
    private func refreshExcludedApps() {
        let apps = settings.excludedApps.map { record in
            let url = Self.installedApp(bundleID: record.bundleID)
            return ExcludedApp(
                bundleID: record.bundleID, name: url.map { Self.displayName(of: $0) } ?? record.name, url: url,
                warning: ExclusionRules.warning(forBundleID: record.bundleID, isInstalledApp: url != nil))
        }
        if apps != excludedApps { excludedApps = apps }
    }

    private func exclusionsChanged(removal: Bool) {
        refreshExcludedApps()
        refreshCandidateApps()
        saveSettings()
        switch state {
        case .starting:
            restartIfActive(reason: "app escluse")  // the launch in flight has the old list
        case .running:
            let live = !removal || userDefaults.bool(forKey: "LiveExclusionRemoval")
            guard live, let sessionID = activeSessionID else {
                restartIfActive(reason: "app escluse")
                return
            }
            engine.updateExclusions(sessionID: sessionID, bundleIDs: excludedBundleIDs) { [weak self] error in
                guard let self, error != nil, self.activeSessionID == sessionID else { return }
                self.restartIfActive(reason: "app escluse")
            }
        case .stopped, .stopping, .failed, .paused:
            break
        }
    }

    private static func installedApp(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static func displayName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Bundle IDs of processes currently sending audio to an output.
    nonisolated private static func bundleIDsPlayingAudio() -> [String] {
        let processes = (try? AudioProcesses.processObjectIDs()) ?? []
        return processes.compactMap { process in
            let running: UInt32? = try? AudioObject.read(
                process, AudioObject.address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0),
                "Processo in riproduzione")
            guard running == 1 else { return nil }
            return AudioProcesses.bundleID(of: process)
        }
    }
}

// MARK: - System
//
// Login item, auto-start, quick EQ toggle and menu-bar state (stage 4).
//
// Login item: SMAppService.mainApp (macOS 13+). macOS records the app by its
// path and code signature. RoomEQ is ad-hoc signed and rebuilt into ./build,
// so after a rebuild macOS may treat it as a different item (status
// "requires approval" or not found): it works best with the app copied to
// /Applications. `launchAtLoginHint` explains what to do.

extension AudioEngineController {
    // MARK: Quick toggle and menu-bar icon

    /// EQ on <-> off (click-free crossfade), for the menu bar.
    func toggleEQ() { setEQEnabled(!isEQEnabled) }

    /// State for a 3-state menu-bar icon (off / EQ on / EQ off) plus
    /// starting, error and automatic pause.
    var menuBarState: MenuBarState {
        switch state {
        case .stopped, .stopping: return .stopped
        case .starting: return .starting
        case .failed: return .failed
        case .paused: return .paused
        case .running: return isEQEnabled ? .active : .bypassed
        }
    }

    // MARK: Auto-start

    /// Start the engine automatically when RoomEQ opens (default off).
    var autoStartEngineOnLaunch: Bool { settings.autoStartEngineOnLaunch }

    func setAutoStartEngineOnLaunch(_ enabled: Bool) {
        guard enabled != settings.autoStartEngineOnLaunch else { return }
        settings.autoStartEngineOnLaunch = enabled
        saveSettings()
    }

    // MARK: Login item

    /// True when registered (enabled or waiting for approval).
    var launchAtLogin: Bool { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }

    /// Italian hint for the current status, nil when nothing to do.
    var launchAtLoginHint: String? {
        switch launchAtLoginStatus {
        case .requiresApproval:
            return "Per completare, consenti RoomEQ in Impostazioni di Sistema › Generali › Elementi login."
        case .unavailable:
            return Self.isInApplicationsFolder
                ? "macOS non trova RoomEQ tra gli elementi di login: disattiva e riattiva l'opzione."
                : "macOS non trova RoomEQ tra gli elementi di login: copia RoomEQ nella cartella Applicazioni, aprilo da lì e riattiva l'opzione."
        case .enabled, .disabled:
            return Self.isInApplicationsFolder
                ? nil : "L'apertura al login funziona meglio con RoomEQ nella cartella Applicazioni."
        }
    }

    /// Registers / unregisters RoomEQ as a login item (off the main thread;
    /// `isChangingLaunchAtLogin` meanwhile). Errors in `lastSettingsError`.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isChangingLaunchAtLogin else { return }
        lastSettingsError = nil
        isChangingLaunchAtLogin = true
        if enabled && !settings.loginItemRequested {
            settings.loginItemRequested = true
            saveSettings()
        }
        loginItemQueue.async { [weak self] in
            var message: String?
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                message = enabled
                    ? "Impossibile attivare l'apertura al login: \(error.localizedDescription)"
                    : "Impossibile disattivare l'apertura al login: \(error.localizedDescription)"
                Log.app.error("Login item: \(error.localizedDescription, privacy: .public)")
            }
            let status = SMAppService.mainApp.status
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isChangingLaunchAtLogin = false
                    if let message { self.lastSettingsError = message }
                    self.applyLaunchAtLoginStatus(status)
                }
            }
        }
    }

    /// Re-reads the status (call when the panel opens: the user may have
    /// changed it in System Settings).
    func refreshLaunchAtLoginStatus() {
        loginItemQueue.async { [weak self] in
            let status = SMAppService.mainApp.status
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyLaunchAtLoginStatus(status) }
            }
        }
    }

    /// `.notFound` is documented as "an error occurred and no such service
    /// could be found"; some macOS versions also report it for an app that
    /// was simply never registered. So it means "unavailable" only if the
    /// user has asked for login launch before; otherwise just "off".
    private func applyLaunchAtLoginStatus(_ service: SMAppService.Status) {
        let status: LaunchAtLoginStatus
        switch service {
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = settings.loginItemRequested ? .unavailable : .disabled
        case .notRegistered: status = .disabled
        @unknown default: status = .disabled
        }
        if status != launchAtLoginStatus { launchAtLoginStatus = status }
    }

    /// Opens System Settings › Generali › Elementi login.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func clearSettingsError() { lastSettingsError = nil }

    private static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}
