// One running instance of the audio path: tap + aggregate + IOProc + listeners.
//
// Lifecycle: init -> start() -> (running) -> teardown(). A session is never
// restarted; the engine creates a new one instead. All methods must be called
// on the engine queue (see AudioEngine).

import CoreAudio
import Foundation
import RoomEQCore

/// The IOProc: called by Core Audio once per IO cycle on its real-time thread.
///
/// A C function pointer rather than AudioDeviceCreateIOProcIDWithBlock:
/// both run directly on the HAL IO thread, but invoking a Swift closure
/// through a block retains/releases the closure context on every cycle
/// (verified in the disassembly), while a C function involves no reference
/// counting at all. `clientData` is the `RenderState` pointer, kept alive by
/// the session until the IOProc is destroyed.
private func roomEQIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    RenderKernel.render(
        state: clientData.assumingMemoryBound(to: RenderState.self), input: inputData, output: outputData)
    return noErr
}

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
    let outputDevice: OutputDeviceInfo
    let sampleRate: Double
    let bufferFrames: Int
    let bufferSizeOptions: [Int]
    let outputPair: OutputChannelPair
    let latency: LatencyBreakdown
    let renderState: RenderStateHandle
    let tapFormatDescription: String
}

/// Raw notifications from Core Audio listeners, forwarded to the engine queue.
enum SessionSignal {
    case formatMayHaveChanged
    case deviceMayBeGone
    case ioStoppedAbnormally
    case bufferSizeChanged
    case processListChanged
}

final class EngineSession {
    let id: Int
    let configuration: EngineConfiguration
    private(set) var outputDevice: OutputDeviceInfo?
    private(set) var sampleRate: Double = 0
    private(set) var renderState: RenderStateHandle?
    /// Set once a restart has been requested, to avoid asking twice.
    var restartRequested = false

    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private var layout: AggregateLayout?
    private var tapFormat = AudioStreamBasicDescription()
    /// Output device's own nominal rate at start (normally == sampleRate).
    private var deviceSampleRate: Double = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false
    private var listeners: [PropertyListener] = []

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
        let tap = try ProcessTap.create(excludedBundleIDs: configuration.excludedBundleIDs)
        self.tap = tap
        tapFormat = try tap.format()
        Log.tap.info("Tap format: \(self.tapFormat.logDescription, privacy: .public)")
        Log.tap.info("exclusion-check: description stored by the HAL: \(tap.currentDescriptionSummary(), privacy: .public)")
        guard tapFormat.mChannelsPerFrame == 1 || tapFormat.mChannelsPerFrame == 2 else {
            throw EngineError("Il tap ha \(tapFormat.mChannelsPerFrame) canali (attesi 1 o 2)")
        }

        // Aggregate.
        let hardwareInputStreams =
            (try? DeviceStreams.streams(of: deviceID, scope: kAudioObjectPropertyScopeInput).count) ?? 0
        let aggregate = try AggregateDevice.create(mainDeviceUID: device.uid, tapUID: tap.uid)
        self.aggregate = aggregate
        aggregate.waitForStreams(minimumInputStreams: hardwareInputStreams + 1)

        // Buffer size (clamped to what the device allows).
        let range = (try? aggregate.bufferFrameSizeRange()) ?? 0...Int.max
        let frames = BufferSize.clamp(configuration.bufferFrames, minimum: range.lowerBound, maximum: range.upperBound)
        do {
            try aggregate.setBufferFrameSize(frames)
        } catch {
            Log.engine.error("\(error.localizedDescription, privacy: .public); continuing with the current size")
        }

        // Layout and render state.
        let layout = try AggregateLayout.analyze(
            aggregate: aggregate, outputDevice: deviceID, tap: tap, tapFormat: tapFormat)
        self.layout = layout
        sampleRate = try aggregate.nominalSampleRate()
        deviceSampleRate = (try? AudioDevices.nominalSampleRate(of: deviceID)) ?? sampleRate

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

        // IOProc: a plain C function called on the HAL real-time IO thread,
        // with the render state pointer as client data (see roomEQIOProc).
        var procID: AudioDeviceIOProcID?
        try AudioObject.check(
            AudioDeviceCreateIOProcID(
                aggregate.objectID, roomEQIOProc, UnsafeMutableRawPointer(renderState.pointer), &procID),
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

        registerListeners(deviceID: deviceID, queue: listenerQueue, signal: signal)

        try AudioObject.check(AudioDeviceStart(aggregate.objectID, procID), "Avvio dell'audio")
        started = true

        let info = makeInfo(range: range)
        Log.engine.info(
            "Session \(self.id) running: \(self.sampleRate) Hz, buffer \(info.bufferFrames), pair \(pair.description, privacy: .public), latency \(info.latency.detail, privacy: .public)"
        )
        return info
    }

    private func registerListeners(
        deviceID: AudioObjectID, queue: DispatchQueue, signal: @escaping (SessionSignal) -> Void
    ) {
        guard let aggregate, let tap, let renderState else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        // Each listener is optional: if one can't be registered (e.g. an
        // object doesn't support that property) we log it and carry on.
        func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
            do {
                listeners.append(
                    try PropertyListener(object: object, address: AudioObject.address(selector), queue: queue, handler: handler))
            } catch {
                Log.engine.error("Listener not installed: \(error.localizedDescription, privacy: .public)")
            }
        }
        listen(aggregate.objectID, kAudioDevicePropertyNominalSampleRate) { signal(.formatMayHaveChanged) }
        listen(deviceID, kAudioDevicePropertyNominalSampleRate) { signal(.formatMayHaveChanged) }
        listen(tap.objectID, kAudioTapPropertyFormat) { signal(.formatMayHaveChanged) }
        listen(deviceID, kAudioDevicePropertyDeviceIsAlive) { signal(.deviceMayBeGone) }
        listen(system, kAudioHardwarePropertyDevices) { signal(.deviceMayBeGone) }
        listen(aggregate.objectID, kAudioDevicePropertyIOStoppedAbnormally) { signal(.ioStoppedAbnormally) }
        listen(aggregate.objectID, kAudioDevicePropertyBufferFrameSize) { signal(.bufferSizeChanged) }
        listen(system, kAudioHardwarePropertyProcessObjectList) { signal(.processListChanged) }
        // Overloads are only counted; the handle is an atomic counter.
        listen(aggregate.objectID, kAudioDeviceProcessorOverload) { renderState.recordOverload() }
    }

    // MARK: Running

    private func makeInfo(range: ClosedRange<Int>) -> SessionInfo {
        let (latency, frames) = currentLatency()
        return SessionInfo(
            outputDevice: outputDevice!,
            sampleRate: sampleRate,
            bufferFrames: frames,
            bufferSizeOptions: BufferSize.options(minimum: range.lowerBound, maximum: range.upperBound),
            outputPair: renderState!.outputPair,
            latency: latency,
            renderState: renderState!,
            tapFormatDescription: tapFormat.logDescription)
    }

    /// Latency at the current buffer size and output pair.
    func currentLatency() -> (LatencyBreakdown, bufferFrames: Int) {
        guard let aggregate, let layout else {
            return (LatencyBreakdown(components: LatencyComponents(), sampleRate: sampleRate), 0)
        }
        let frames = (try? aggregate.bufferFrameSize()) ?? configuration.bufferFrames
        let pair = renderState?.outputPair ?? .firstPair
        let outputStreamIndex = layout.outputLayout.location(ofChannel: pair.left)?.stream ?? 0
        let input = kAudioObjectPropertyScopeInput, output = kAudioObjectPropertyScopeOutput
        let components = LatencyComponents(
            inputDeviceFrames: aggregate.deviceLatency(scope: input),
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

    /// Returns a reason if the sample rate or tap format no longer match
    /// what the session was built for, nil otherwise.
    func formatChangeReason() -> String? {
        guard let aggregate, let tap, let outputDevice else { return nil }
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

    /// Stops and destroys everything, in the safe order: listeners, IO,
    /// IOProc (after this the render state is no longer used), aggregate, tap.
    /// Safe to call more than once and after a partial start.
    func teardown() {
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
