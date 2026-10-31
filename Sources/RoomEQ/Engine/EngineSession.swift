// One running instance of the audio path: tap + aggregate + IOProc + listeners.
//
// Lifecycle: init -> start() -> (running) -> teardown(). A session is never
// restarted; the engine creates a new one instead. All methods must be called
// on the engine queue (see AudioEngine).

import CoreAudio
import Foundation
import RoomEQCore

// MARK: - Real-time callbacks

/// The IOProc signature with honest (nullable) pointers. The SDK imports
/// AudioDeviceIOProc's pointers as non-optional (the header sits inside
/// CF_ASSUME_NONNULL), but nothing guarantees the HAL never passes NULL; a
/// NULL in a non-optional Swift pointer would be undefined behaviour. This
/// type has the identical C ABI, so we register it via `unsafeBitCast` and
/// check the pointers like any optional.
private typealias NullableIOProc = @convention(c) (
    AudioObjectID,
    UnsafePointer<AudioTimeStamp>?,
    UnsafePointer<AudioBufferList>?,
    UnsafePointer<AudioTimeStamp>?,
    UnsafeMutablePointer<AudioBufferList>?,
    UnsafePointer<AudioTimeStamp>?,
    UnsafeMutableRawPointer?
) -> OSStatus

/// Called by Core Audio once per IO cycle on its real-time thread.
///
/// A C function pointer rather than AudioDeviceCreateIOProcIDWithBlock:
/// both run directly on the HAL IO thread, but invoking a Swift closure
/// through a block retains/releases the closure context on every cycle
/// (verified in the disassembly), while a C function involves no reference
/// counting at all. `clientData` is the `RenderState` pointer, kept alive by
/// the session until the IOProc is destroyed.
private func roomEQRender(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>?,
    _ inputData: UnsafePointer<AudioBufferList>?,
    _ inputTime: UnsafePointer<AudioTimeStamp>?,
    _ outputData: UnsafeMutablePointer<AudioBufferList>?,
    _ outputTime: UnsafePointer<AudioTimeStamp>?,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    RenderKernel.render(
        state: clientData.assumingMemoryBound(to: RenderState.self), input: inputData, output: outputData)
    return noErr
}

private typealias NullableListenerProc = @convention(c) (
    AudioObjectID, UInt32, UnsafePointer<AudioObjectPropertyAddress>?, UnsafeMutableRawPointer?
) -> OSStatus

/// kAudioDeviceProcessorOverload listener. Core Audio calls it SYNCHRONOUSLY
/// from the IO thread, so it only does one atomic increment.
private func roomEQOverloadListener(
    _ object: AudioObjectID, _ count: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>?, _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    RenderKernel.recordOverload(state: clientData.assumingMemoryBound(to: RenderState.self))
    return noErr
}

// MARK: - Types

/// What the user asked for.
struct EngineConfiguration: Equatable {
    var outputDeviceUID: String
    var outputPair: OutputChannelPair
    var bufferFrames: Int
    var excludedBundleIDs: [String]
    var gain: Float
    var bypass: Bool
    /// Update the tap when an excluded app starts after the tap was created
    /// (see `handleProcessListChanged`). Can be turned off for testing with
    /// `defaults write com.federicociapi.RoomEQ DisableProcessExclusionFallback -bool YES`.
    var processListFallbackEnabled: Bool
    /// Device tap (default) or global mixdown (diagnostic). UserDefaults `TapMode`.
    var tapMode: TapMode
    /// Drift compensation of the tap inside the aggregate. Diagnostic
    /// UserDefaults `TapDriftCompensation` (default true).
    var tapDriftCompensation: Bool
    /// Device mode only: stereo mix of the device stream (true), full
    /// device layout (false), or nil = automatic: try mixdown, then no
    /// mixdown, keeping the first tap whose rate equals the device's.
    /// Diagnostic UserDefaults `TapMixdown` (unset = automatic).
    var tapMixdown: Bool?
}

/// What actually got set up.
struct SessionInfo {
    let sessionID: Int
    let outputDevice: OutputDeviceInfo
    let sampleRate: Double
    let bufferFrames: Int
    let bufferSizeOptions: [Int]
    let outputPair: OutputChannelPair
    let latency: LatencyBreakdown
    let renderState: RenderStateHandle
    let tapMode: TapMode
    /// Short UI text, e.g. "44,1 kHz · 2 ch".
    let tapFormatSummary: String
}

/// macOS refused audio capture (most likely the privacy permission).
struct AudioCapturePermissionError: LocalizedError {
    let underlying: CoreAudioError

    var errorDescription: String? {
        "macOS non consente a RoomEQ di catturare l'audio di sistema (\(describeOSStatus(underlying.status))). "
            + "Apri Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio di sistema, "
            + "consenti l'accesso a RoomEQ e riprova."
    }

    /// Wraps `error` if its status looks like a permission refusal.
    /// '!hog' (kAudioDevicePermissionsError) is a permission error by
    /// definition; for tap creation we also treat 'nope' (illegal
    /// operation) as a likely refusal. These mappings are NOT documented for
    /// taps; check them in the live test.
    static func classify(_ error: Error, tapCreation: Bool) -> Error {
        guard let error = error as? CoreAudioError else { return error }
        let statuses: [OSStatus] =
            tapCreation
            ? [kAudioDevicePermissionsError, kAudioHardwareIllegalOperationError]
            : [kAudioDevicePermissionsError]
        return statuses.contains(error.status) ? AudioCapturePermissionError(underlying: error) : error
    }
}

/// Raw notifications from Core Audio listeners, forwarded to the engine queue.
enum SessionSignal {
    /// Sample rate, tap format or stream layout may have changed.
    case configurationMayHaveChanged
    case deviceMayBeGone
    case ioStoppedAbnormally
    case bufferSizeChanged
    case processListChanged
}

// MARK: - Session

final class EngineSession {
    let id: Int
    let configuration: EngineConfiguration
    private(set) var outputDevice: OutputDeviceInfo?
    private(set) var sampleRate: Double = 0
    private(set) var renderState: RenderStateHandle?
    /// Set once a restart has been requested, to avoid asking twice.
    var restartRequested = false
    /// A debounced configuration check is pending for this session.
    var configurationCheckScheduled = false
    /// Last latency sent to the controller (to avoid duplicate events).
    var lastEmittedLatency: LatencyBreakdown?

    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private var layout: AggregateLayout?
    private var tapFormat = AudioStreamBasicDescription()
    /// Output device's own nominal rate at start (normally == sampleRate).
    private var deviceSampleRate: Double = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false
    private var listeners: [PropertyListener] = []
    private var realtimeListeners: [RealtimeListener] = []
    /// Device mode: UID of the device whose output stream is tapped (the
    /// system default output at start).
    private var tappedDeviceUID: String?
    /// kAudioSubTapPropertyExtraLatency, read once per session.
    private var cachedTapExtraLatency: Int?

    init(id: Int, configuration: EngineConfiguration) {
        self.id = id
        self.configuration = configuration
    }

    // MARK: Start

    /// Builds and starts everything. On error, call `teardown()`.
    func start(listenerQueue: DispatchQueue, signal: @escaping (SessionSignal) -> Void) throws -> SessionInfo {
        // Output device.
        guard let deviceID = AudioDevices.deviceID(forUID: configuration.outputDeviceUID),
            let device = AudioDevices.info(for: deviceID)
        else { throw EngineError("Dispositivo di uscita non trovato (\(configuration.outputDeviceUID))") }
        guard device.outputChannelCount >= 2 else {
            throw EngineError("\(device.name) ha meno di 2 canali di uscita")
        }
        outputDevice = device
        Log.engine.info(
            "Starting session \(self.id) on \(device.name, privacy: .public) (\(device.outputChannelCount) out, \(device.inputChannelCount) in)"
        )

        // Tap.
        let tap: ProcessTap
        do {
            tap = try createTap(outputDevice: device)
        } catch {
            throw AudioCapturePermissionError.classify(error, tapCreation: true)
        }
        self.tap = tap
        tapFormat = try tap.format()
        Log.tap.info(
            "Tap format [mode \(self.configuration.tapMode.rawValue, privacy: .public)]: \(self.tapFormat.logDescription, privacy: .public); output device \(device.name, privacy: .public) at \((try? AudioDevices.nominalSampleRate(of: deviceID)) ?? 0) Hz"
        )
        Log.tap.info("exclusion-check: description stored by the HAL: \(tap.currentDescriptionSummary(), privacy: .public)")
        guard tapFormat.mChannelsPerFrame >= 1 else {
            throw EngineError("Il tap non ha canali")
        }

        // Aggregate, and where the tap ended up inside it (waits up to 3 s
        // for the HAL to finish building it; fails if the tap stream can't
        // be identified with certainty).
        let aggregate = try AggregateDevice.create(
            mainDeviceUID: device.uid, tapUID: tap.uid, driftCompensation: configuration.tapDriftCompensation)
        self.aggregate = aggregate
        let layout = try AggregateLayout.waitForLayout(
            aggregate: aggregate, outputDevice: deviceID, tap: tap, tapFormat: tapFormat)
        self.layout = layout

        // Buffer size (clamped to what the device allows).
        let range = (try? aggregate.bufferFrameSizeRange()) ?? 0...Int.max
        let frames = BufferSize.clamp(configuration.bufferFrames, minimum: range.lowerBound, maximum: range.upperBound)
        do {
            try aggregate.setBufferFrameSize(frames)
        } catch {
            Log.engine.error("\(error.localizedDescription, privacy: .public); continuing with the current size")
        }

        sampleRate = try aggregate.nominalSampleRate()
        deviceSampleRate = (try? AudioDevices.nominalSampleRate(of: deviceID)) ?? sampleRate

        // Render state.
        // Tap channels feeding L/R: 2-channel tap -> 0/1; a device tap that
        // kept the device's full layout -> the device's preferred stereo pair.
        let tapChannels = layout.inputLayout.locations(ofStream: layout.tapStreamIndex)
        guard !tapChannels.isEmpty else { throw EngineError("Lo stream del tap non ha canali") }
        var preferredStereo: (Int, Int)?
        if tapChannels.count > 2 {
            let tappedID = tappedDeviceUID.flatMap(AudioDevices.deviceID(forUID:)) ?? deviceID
            preferredStereo = AudioDevices.preferredStereoChannels(of: tappedID)
        }
        let tapPair = TapChannelSelection.stereoPair(tapChannels: tapChannels.count, preferredStereo: preferredStereo)
        let tapLeft = tapChannels[tapPair.left], tapRight = tapChannels[tapPair.right]
        Log.tap.info(
            "Tap stream has \(tapChannels.count) channel(s); using tap channels \(tapPair.left + 1)/\(tapPair.right + 1) as L/R (preferred stereo \(preferredStereo.map { "\($0.0)/\($0.1)" } ?? "n/a", privacy: .public))"
        )
        let pair =
            configuration.outputPair.right < layout.outputLayout.channelCount ? configuration.outputPair : .firstPair
        let renderConfiguration = RenderConfiguration(
            inputLayout: layout.inputLayout, tapLeft: tapLeft, tapRight: tapRight,
            outputLayout: layout.outputLayout, sampleRate: sampleRate)
        let renderState = RenderStateHandle(
            configuration: renderConfiguration, gain: configuration.gain, bypass: configuration.bypass,
            outputPair: pair)
        self.renderState = renderState
        let statePointer = UnsafeMutableRawPointer(renderState.pointer)

        // IOProc (plain C function, render state as client data).
        var procID: AudioDeviceIOProcID?
        let ioProc = unsafeBitCast(roomEQRender as NullableIOProc, to: AudioDeviceIOProc.self)
        try AudioObject.check(
            AudioDeviceCreateIOProcID(aggregate.objectID, ioProc, statePointer, &procID),
            "Creazione della callback audio")
        guard let procID else { throw EngineError("Creazione della callback audio: ID mancante") }
        ioProcID = procID

        // Only the tap stream is needed as input.
        do {
            try aggregate.setInputStreamUsage(
                ioProc: procID, enabled: layout.inputStreams.indices.map { $0 == layout.tapStreamIndex })
            Log.engine.info("Hardware input streams disabled for our IOProc (only the tap stream is on)")
        } catch {
            Log.engine.error("Could not restrict input stream usage: \(error.localizedDescription, privacy: .public)")
        }

        registerListeners(deviceID: deviceID, statePointer: statePointer, queue: listenerQueue, signal: signal)

        do {
            try AudioObject.check(AudioDeviceStart(aggregate.objectID, procID), "Avvio dell'audio")
        } catch {
            throw AudioCapturePermissionError.classify(error, tapCreation: false)
        }
        started = true

        let info = makeInfo(range: range)
        Log.engine.info(
            "Session \(self.id) running: \(self.sampleRate) Hz, buffer \(info.bufferFrames), pair \(pair.description, privacy: .public)"
        )
        logLatencyDiagnostics(context: "at start")
        return info
    }

    private func registerListeners(
        deviceID: AudioObjectID, statePointer: UnsafeMutableRawPointer, queue: DispatchQueue,
        signal: @escaping (SessionSignal) -> Void
    ) {
        guard let aggregate, let tap else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let wildcard = kAudioObjectPropertyScopeWildcard
        // Each listener is optional: if one can't be registered (e.g. an
        // object doesn't support that property) we log it and carry on.
        func listen(
            _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, handler: @escaping () -> Void
        ) {
            do {
                listeners.append(
                    try PropertyListener(
                        object: object, address: AudioObject.address(selector, scope), queue: queue, handler: handler))
            } catch {
                Log.engine.error("Listener not installed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let configurationChanged = { signal(.configurationMayHaveChanged) }
        // Format.
        listen(aggregate.objectID, kAudioDevicePropertyNominalSampleRate, handler: configurationChanged)
        listen(deviceID, kAudioDevicePropertyNominalSampleRate, handler: configurationChanged)
        listen(tap.objectID, kAudioTapPropertyFormat, handler: configurationChanged)
        // Stream layout: if it changes, the render state's tables are stale
        // (the kernel would only output silence) -> rebuild.
        for object in [aggregate.objectID, deviceID] {
            listen(object, kAudioDevicePropertyStreamConfiguration, wildcard, handler: configurationChanged)
            listen(object, kAudioDevicePropertyStreams, wildcard, handler: configurationChanged)
            listen(object, kAudioDevicePropertyDeviceHasChanged, handler: configurationChanged)
        }
        // Device presence and IO health.
        listen(deviceID, kAudioDevicePropertyDeviceIsAlive) { signal(.deviceMayBeGone) }
        listen(system, kAudioHardwarePropertyDevices) { signal(.deviceMayBeGone) }
        listen(aggregate.objectID, kAudioDevicePropertyIOStoppedAbnormally) { signal(.ioStoppedAbnormally) }
        listen(aggregate.objectID, kAudioDevicePropertyBufferFrameSize) { signal(.bufferSizeChanged) }
        listen(system, kAudioHardwarePropertyProcessObjectList) { signal(.processListChanged) }
        if configuration.tapMode == .device {
            // The tap follows the system default output: rebuild if it moves.
            listen(system, kAudioHardwarePropertyDefaultOutputDevice, handler: configurationChanged)
        }

        // Overloads arrive synchronously on the IO thread: C listener.
        do {
            let proc = unsafeBitCast(roomEQOverloadListener as NullableListenerProc, to: AudioObjectPropertyListenerProc.self)
            realtimeListeners.append(
                try RealtimeListener(
                    object: aggregate.objectID, address: AudioObject.address(kAudioDeviceProcessorOverload),
                    proc: proc, clientData: statePointer))
        } catch {
            Log.engine.error("Overload listener not installed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Running

    private func makeInfo(range: ClosedRange<Int>) -> SessionInfo {
        let (latency, frames) = currentLatency()
        return SessionInfo(
            sessionID: id,
            outputDevice: outputDevice!,
            sampleRate: sampleRate,
            bufferFrames: frames,
            bufferSizeOptions: BufferSize.options(minimum: range.lowerBound, maximum: range.upperBound),
            outputPair: renderState!.outputPair,
            latency: latency,
            renderState: renderState!,
            tapMode: configuration.tapMode,
            tapFormatSummary: AudioFormatText.summary(
                sampleRate: tapFormat.mSampleRate, channels: Int(tapFormat.mChannelsPerFrame)))
    }

    /// Latency estimate at the current buffer size and output pair.
    /// Input side = the tap path only: sub-tap extra latency + aggregate
    /// input safety offset + tap stream latency (NOT the hardware inputs'
    /// device latency). Output side = aggregate output device latency +
    /// output safety offset + latency of the stream we write to.
    func currentLatency() -> (LatencyBreakdown, bufferFrames: Int) {
        guard let aggregate, let layout else {
            return (LatencyBreakdown(components: LatencyComponents(), sampleRate: sampleRate), 0)
        }
        let frames: Int
        do {
            frames = try aggregate.bufferFrameSize()
        } catch {
            Log.engine.warning("Buffer size unreadable: \(error.localizedDescription, privacy: .public)")
            frames = configuration.bufferFrames
        }
        let pair = renderState?.outputPair ?? .firstPair
        let outputStreamIndex = layout.outputLayout.location(ofChannel: pair.left)?.stream ?? 0
        let input = kAudioObjectPropertyScopeInput, output = kAudioObjectPropertyScopeOutput
        let components = LatencyComponents(
            inputTapExtraFrames: tapExtraLatency(aggregate),
            inputSafetyOffsetFrames: aggregate.safetyOffset(scope: input),
            inputStreamFrames: DeviceStreams.latency(ofStream: layout.tapStream.objectID),
            bufferFrames: frames,
            outputDeviceFrames: aggregate.deviceLatency(scope: output),
            outputSafetyOffsetFrames: aggregate.safetyOffset(scope: output),
            outputStreamFrames: DeviceStreams.latency(ofStream: layout.outputStreams[outputStreamIndex].objectID))
        return (LatencyBreakdown(components: components, sampleRate: sampleRate), frames)
    }

    /// Which audio to capture. Device mode taps output stream 0 of the
    /// SYSTEM DEFAULT output device (where apps play), even if RoomEQ plays
    /// to another device; in that case the rates may differ and the
    /// aggregate resamples (logged).
    private func tapTarget(outputDevice: OutputDeviceInfo) -> TapTarget {
        switch configuration.tapMode {
        case .global:
            tappedDeviceUID = nil
            return .global
        case .device:
            let tapped = currentTapDeviceUID(fallback: outputDevice.uid) ?? outputDevice.uid
            tappedDeviceUID = tapped
            if tapped != outputDevice.uid {
                let tappedRate = AudioDevices.deviceID(forUID: tapped).flatMap { try? AudioDevices.nominalSampleRate(of: $0) }
                let outputRate = try? AudioDevices.nominalSampleRate(of: outputDevice.objectID)
                Log.tap.notice(
                    "Device tap on the system default output \(tapped, privacy: .public) (\(tappedRate ?? 0) Hz), playing to \(outputDevice.name, privacy: .public) (\(outputRate ?? 0) Hz)\(tappedRate != outputRate ? " — rates differ, the aggregate will resample" : "", privacy: .public)"
                )
            }
            return .device(uid: tapped, stream: 0, mixdown: configuration.tapMixdown ?? true)
        }
    }

    /// Creates the tap. In device mode, unless `tapMixdown` is forced, tries
    /// mixdown and then no mixdown, and for each also tries setting
    /// kAudioTapPropertyFormat to the device rate if it is settable; keeps
    /// the first tap whose rate equals the tapped device's rate (no
    /// resampling in the aggregate), else the first one created.
    private func createTap(outputDevice: OutputDeviceInfo) throws -> ProcessTap {
        let target = tapTarget(outputDevice: outputDevice)
        guard case .device(let uid, let stream, _) = target else {
            return try ProcessTap.create(excludedBundleIDs: configuration.excludedBundleIDs, target: target)
        }
        let wantedRate = AudioDevices.deviceID(forUID: uid).flatMap { try? AudioDevices.nominalSampleRate(of: $0) }
        let candidates: [Bool] = configuration.tapMixdown.map { [$0] } ?? [true, false]
        var fallback: ProcessTap?
        for mixdown in candidates {
            let candidate: ProcessTap
            do {
                candidate = try ProcessTap.create(
                    excludedBundleIDs: configuration.excludedBundleIDs,
                    target: .device(uid: uid, stream: stream, mixdown: mixdown))
            } catch {
                if let fallback { return fallback }
                throw error
            }
            let rate = (try? candidate.format())?.mSampleRate ?? 0
            if let wantedRate, rate == wantedRate {
                Log.tap.notice("Device tap (mixdown \(mixdown)) runs at the device rate \(rate) Hz: using it")
                fallback?.destroy()
                return candidate
            }
            if let wantedRate {
                let attempt = candidate.trySetSampleRate(wantedRate)
                if attempt.succeeded {
                    Log.tap.notice("Device tap (mixdown \(mixdown)) set to \(wantedRate) Hz via kAudioTapPropertyFormat: using it")
                    fallback?.destroy()
                    return candidate
                }
                Log.tap.notice(
                    "Device tap (mixdown \(mixdown)) at \(rate) Hz, device at \(wantedRate) Hz; format change: \(attempt.report, privacy: .public)"
                )
            }
            if fallback == nil { fallback = candidate } else { candidate.destroy() }
        }
        Log.tap.notice("No device tap at the device rate; using the first candidate (the aggregate will resample)")
        return fallback!
    }

    /// UID of the device a device-mode tap should follow: the system default
    /// output (ignoring RoomEQ's own aggregate), else `fallback`.
    private func currentTapDeviceUID(fallback: String) -> String? {
        guard let uid = AudioDevices.defaultOutputDeviceUID(), !uid.hasPrefix(AudioDevices.ownAggregateUIDPrefix) else {
            return fallback
        }
        return uid
    }

    private func tapExtraLatency(_ aggregate: AggregateDevice) -> Int {
        if let cachedTapExtraLatency { return cachedTapExtraLatency }
        let value = aggregate.subTapExtraLatency()
        cachedTapExtraLatency = value
        return value
    }

    /// Logs everything that goes into the latency estimate, plus the raw
    /// aggregate values, tagged with the tap mode, so modes can be compared.
    func logLatencyDiagnostics(context: String) {
        guard let aggregate else { return }
        let (latency, frames) = currentLatency()
        let input = kAudioObjectPropertyScopeInput, output = kAudioObjectPropertyScopeOutput
        Log.engine.notice(
            "Latency [\(context, privacy: .public)] mode=\(self.configuration.tapMode.rawValue, privacy: .public) drift=\(self.configuration.tapDriftCompensation) target=\(self.tap?.target.description ?? "?", privacy: .public) tap=\(self.tapFormat.mSampleRate) Hz/\(self.tapFormat.mChannelsPerFrame) ch device=\(self.sampleRate) Hz buffer=\(frames): safety in \(aggregate.safetyOffset(scope: input)) out \(aggregate.safetyOffset(scope: output)), device latency in \(aggregate.deviceLatency(scope: input)) (not counted) out \(aggregate.deviceLatency(scope: output)) -> \(latency.detail, privacy: .public) = \(latency.totalMilliseconds) ms"
        )
    }

    /// Changes the IO buffer size while running.
    func setBufferSize(_ requested: Int) throws -> (LatencyBreakdown, bufferFrames: Int) {
        guard let aggregate else { throw EngineError("Motore non avviato") }
        let range = try aggregate.bufferFrameSizeRange()
        try aggregate.setBufferFrameSize(BufferSize.clamp(requested, minimum: range.lowerBound, maximum: range.upperBound))
        return currentLatency()
    }

    /// Returns a reason if the sample rate, tap format or stream layout no
    /// longer match what the session was built for, nil otherwise.
    func configurationChangeReason() -> String? {
        guard let aggregate, let tap, let outputDevice, let layout else { return nil }
        if configuration.tapMode == .device, let tapped = tappedDeviceUID,
            let current = currentTapDeviceUID(fallback: outputDevice.uid), current != tapped
        {
            return "uscita di sistema cambiata (tap su \(current))"
        }
        if let rate = try? aggregate.nominalSampleRate(), rate != sampleRate {
            return "frequenza del dispositivo aggregato cambiata (\(sampleRate) -> \(rate) Hz)"
        }
        if let rate = try? AudioDevices.nominalSampleRate(of: outputDevice.objectID), rate != deviceSampleRate {
            return "frequenza di \(outputDevice.name) cambiata (\(deviceSampleRate) -> \(rate) Hz)"
        }
        if let format = try? tap.format(),
            format.mSampleRate != tapFormat.mSampleRate || format.mChannelsPerFrame != tapFormat.mChannelsPerFrame
        {
            return "formato del tap cambiato (\(format.logDescription))"
        }
        let inputCounts = try? AudioObject.bufferChannelCounts(aggregate.objectID, scope: kAudioObjectPropertyScopeInput)
        let outputCounts = try? AudioObject.bufferChannelCounts(aggregate.objectID, scope: kAudioObjectPropertyScopeOutput)
        if inputCounts != layout.inputLayout.bufferChannelCounts
            || outputCounts != layout.outputLayout.bufferChannelCounts
        {
            return "disposizione degli stream cambiata (ingresso \(inputCounts ?? []), uscita \(outputCounts ?? []))"
        }
        let inputIDs = (try? DeviceStreams.streams(of: aggregate.objectID, scope: kAudioObjectPropertyScopeInput))?
            .map(\.objectID)
        let outputIDs = (try? DeviceStreams.streams(of: aggregate.objectID, scope: kAudioObjectPropertyScopeOutput))?
            .map(\.objectID)
        if inputIDs != layout.inputStreams.map(\.objectID) || outputIDs != layout.outputStreams.map(\.objectID) {
            return "stream del dispositivo aggregato sostituiti"
        }
        return nil
    }

    /// True while the output device is still connected.
    func outputDeviceIsPresent() -> Bool {
        guard let outputDevice else { return false }
        guard let id = AudioDevices.deviceID(forUID: outputDevice.uid) else { return false }
        return AudioDevices.isAlive(id)
    }

    /// Fallback for excluding apps launched after the tap was created.
    ///
    /// On macOS 26 the tap also carries `bundleIDs`, which should already
    /// exclude such apps. Whether it does is NOT documented, so when an
    /// excluded app appears we log the tap's stored description
    /// ("exclusion-check") and, unless disabled, add the new process object
    /// to the tap via kAudioTapPropertyDescription.
    func handleProcessListChanged() {
        guard let tap else { return }
        let alive = Set((try? AudioProcesses.processObjectIDs()) ?? [])
        let matches = AudioProcesses.processObjects(matching: tap.excludedBundleIDs)
        let newcomers = matches.filter { !tap.excludedProcesses.contains($0.object) }
        guard !newcomers.isEmpty else { return }

        let names = newcomers.map { "\($0.bundleID) (\($0.object))" }
        Log.tap.notice(
            "exclusion-check: excluded app(s) started after the tap: \(names, privacy: .public). Tap description now: \(tap.currentDescriptionSummary(), privacy: .public)"
        )
        guard configuration.processListFallbackEnabled else {
            Log.tap.notice(
                "exclusion-check: fallback DISABLED — relying on bundleIDs only. If the app is heard through RoomEQ, bundleIDs alone does not work."
            )
            return
        }
        do {
            // Keep only processes that still exist, plus the new ones.
            let stillAlive = tap.excludedProcesses.filter { alive.contains($0) }
            try tap.replaceExcludedProcesses(stillAlive + newcomers.map(\.object))
        } catch {
            Log.tap.error("exclusion-check: tap update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Stop

    /// Stops and destroys everything, in the safe order: listeners (the
    /// real-time one first), IO, IOProc (after this the render state is no
    /// longer used by Core Audio), aggregate, tap.
    /// Safe to call more than once and after a partial start.
    func teardown() {
        realtimeListeners.forEach { $0.remove() }
        realtimeListeners.removeAll()
        listeners.forEach { $0.remove() }
        listeners.removeAll()
        if let aggregate, let procID = ioProcID {
            if started {
                let status = AudioDeviceStop(aggregate.objectID, procID)
                if status != noErr {
                    Log.engine.error("AudioDeviceStop: \(describeOSStatus(status), privacy: .public)")
                }
                started = false
            }
            let status = AudioDeviceDestroyIOProcID(aggregate.objectID, procID)
            if status != noErr {
                Log.engine.error("AudioDeviceDestroyIOProcID: \(describeOSStatus(status), privacy: .public)")
            }
            ioProcID = nil
        }
        aggregate?.destroy()
        aggregate = nil
        tap?.destroy()
        tap = nil
        renderState = nil
        Log.engine.info("Session \(self.id) torn down")
    }
}
