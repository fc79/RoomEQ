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
    let tapFormatDescription: String
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
            tap = try ProcessTap.create(excludedBundleIDs: configuration.excludedBundleIDs)
        } catch {
            throw AudioCapturePermissionError.classify(error, tapCreation: true)
        }
        self.tap = tap
        tapFormat = try tap.format()
        Log.tap.info("Tap format: \(self.tapFormat.logDescription, privacy: .public)")
        Log.tap.info("exclusion-check: description stored by the HAL: \(tap.currentDescriptionSummary(), privacy: .public)")
        guard tapFormat.mChannelsPerFrame == 1 || tapFormat.mChannelsPerFrame == 2 else {
            throw EngineError("Il tap ha \(tapFormat.mChannelsPerFrame) canali (attesi 1 o 2)")
        }

        // Aggregate, and where the tap ended up inside it (waits up to 3 s
        // for the HAL to finish building it; fails if the tap stream can't
        // be identified with certainty).
        let aggregate = try AggregateDevice.create(mainDeviceUID: device.uid, tapUID: tap.uid)
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
        let tapChannels = layout.inputLayout.locations(ofStream: layout.tapStreamIndex)
        guard let tapLeft = tapChannels.first else { throw EngineError("Lo stream del tap non ha canali") }
        let tapRight = tapChannels.count > 1 ? tapChannels[1] : tapLeft
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
            "Session \(self.id) running: \(self.sampleRate) Hz, buffer \(info.bufferFrames), pair \(pair.description, privacy: .public), latency estimate \(info.latency.detail, privacy: .public) (aggregate input-scope device latency \(aggregate.deviceLatency(scope: kAudioObjectPropertyScopeInput)) frames NOT counted: hardware inputs only)"
        )
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
            tapFormatDescription: tapFormat.logDescription)
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
            inputTapExtraFrames: aggregate.subTapExtraLatency(),
            inputSafetyOffsetFrames: aggregate.safetyOffset(scope: input),
            inputStreamFrames: DeviceStreams.latency(ofStream: layout.tapStream.objectID),
            bufferFrames: frames,
            outputDeviceFrames: aggregate.deviceLatency(scope: output),
            outputSafetyOffsetFrames: aggregate.safetyOffset(scope: output),
            outputStreamFrames: DeviceStreams.latency(ofStream: layout.outputStreams[outputStreamIndex].objectID))
        return (LatencyBreakdown(components: components, sampleRate: sampleRate), frames)
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
