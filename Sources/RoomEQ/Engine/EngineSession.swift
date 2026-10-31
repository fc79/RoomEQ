// One running instance of the SPLIT audio path:
//
//   tap (device tap on the output device, no mixdown, muted while read)
//     -> capture aggregate (tap only, no sub-devices, drift off)
//     -> capture IOProc: writes the source L/R into the ring (sample time)
//   output IOProc directly on the output device:
//     reads the ring at a fixed delay -> render chain -> chosen output pair
//
// Never any sample-rate conversion: tap, device and capture aggregate must
// run at the same rate or the session refuses to start.
//
// Lifecycle: init -> start() -> (running) -> teardown(). A session is never
// restarted; the engine creates a new one. All methods run on the engine
// queue (see AudioEngine).

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
typealias NullableIOProc = @convention(c) (
    AudioObjectID,
    UnsafePointer<AudioTimeStamp>?,
    UnsafePointer<AudioBufferList>?,
    UnsafePointer<AudioTimeStamp>?,
    UnsafeMutablePointer<AudioBufferList>?,
    UnsafePointer<AudioTimeStamp>?,
    UnsafeMutableRawPointer?
) -> OSStatus

/// Capture IOProc (capture aggregate): tap -> ring. Client data: SplitLink.
/// Plain C functions, not blocks: invoking a Swift closure through a block
/// retains/releases its context every cycle; a C function involves no ARC.
private func captureIOProc(
    _ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>?, _ input: UnsafePointer<AudioBufferList>?,
    _ inputTime: UnsafePointer<AudioTimeStamp>?, _ output: UnsafeMutablePointer<AudioBufferList>?,
    _ outputTime: UnsafePointer<AudioTimeStamp>?, _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    CaptureKernel.capture(
        clientData.assumingMemoryBound(to: SplitLink.self), now: now, input: input, inputTime: inputTime)
    return noErr
}

/// Output IOProc (physical device): ring -> render chain -> device.
/// Client data: SplitOutputContext (render state + link).
private func outputIOProc(
    _ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>?, _ input: UnsafePointer<AudioBufferList>?,
    _ inputTime: UnsafePointer<AudioTimeStamp>?, _ output: UnsafeMutablePointer<AudioBufferList>?,
    _ outputTime: UnsafePointer<AudioTimeStamp>?, _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let context = clientData.assumingMemoryBound(to: SplitOutputContext.self)
    SplitOutputKernel.render(
        state: context.pointee.state, link: context.pointee.link, outputTime: outputTime, output: output)
    return noErr
}

private typealias NullableListenerProc = @convention(c) (
    AudioObjectID, UInt32, UnsafePointer<AudioObjectPropertyAddress>?, UnsafeMutableRawPointer?
) -> OSStatus

/// kAudioDeviceProcessorOverload on the output device. Core Audio calls it
/// SYNCHRONOUSLY from the IO thread: one atomic increment only.
private func outputOverloadListener(
    _ object: AudioObjectID, _ count: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>?, _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    RenderKernel.recordOverload(state: clientData.assumingMemoryBound(to: RenderState.self))
    return noErr
}

/// kAudioDeviceProcessorOverload on the capture aggregate (same rules).
private func captureOverloadListener(
    _ object: AudioObjectID, _ count: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>?, _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    CaptureKernel.recordOverload(clientData.assumingMemoryBound(to: SplitLink.self))
    return noErr
}

// MARK: - Types

/// What the user asked for.
struct EngineConfiguration: Equatable {
    /// Always the macOS default output device (chosen by the controller).
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
    let delayFrames: Int
    let renderState: RenderStateHandle
    let link: SplitLinkHandle
    /// Short UI text, e.g. "44,1 kHz · 10 ch".
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
    /// operation) as a likely refusal. Not documented for taps.
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
    case processListChanged
}

// MARK: - Session

final class EngineSession {
    /// Ring capacity per channel (frames).
    static let ringCapacity = 8192
    /// Extra frames added to the measured read-ahead need.
    static let delayMargin: Int64 = 32
    /// Warm-up: settle, then measure for this long.
    static let warmupSettle = 0.2
    static let warmupMeasure = 0.5
    /// Delay increases allowed per session after underruns.
    static let maxDelayIncreases = 6

    let id: Int
    let configuration: EngineConfiguration
    private(set) var outputDevice: OutputDeviceInfo?
    private(set) var sampleRate: Double = 0
    private(set) var renderState: RenderStateHandle?
    private(set) var link: SplitLinkHandle?
    /// Set once a restart has been requested, to avoid asking twice.
    var restartRequested = false
    /// A debounced configuration check is pending for this session.
    var configurationCheckScheduled = false
    /// Last latency sent to the controller (to avoid duplicate events).
    var lastEmittedLatency: LatencyBreakdown?

    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private var tapFormat = AudioStreamBasicDescription()
    private var tapStream: StreamInfo?
    private var captureLayout: BufferListLayout?
    private var outputStreams: [StreamInfo] = []
    private var outputLayout: BufferListLayout?
    private var bufferFrames = 0
    private var deviceSampleRate: Double = 0
    private var captureSampleRate: Double = 0
    private var cachedTapExtraLatency: Int?
    private var outputContext: UnsafeMutablePointer<SplitOutputContext>?
    private var captureProcID: AudioDeviceIOProcID?
    private var outputProcID: AudioDeviceIOProcID?
    private var captureStarted = false
    private var outputStarted = false
    private var listeners: [PropertyListener] = []
    private var realtimeListeners: [RealtimeListener] = []
    private var delayIncreases = 0
    private var underrunsSeen: UInt64 = 0

    init(id: Int, configuration: EngineConfiguration) {
        self.id = id
        self.configuration = configuration
    }

    // MARK: Start

    /// Builds and starts everything, including the warm-up that fixes the
    /// delay (blocks ~0.7 s). On error, call `teardown()`.
    func start(listenerQueue: DispatchQueue, signal: @escaping (SessionSignal) -> Void) throws -> SessionInfo {
        // Output device (= tapped device).
        guard let deviceID = AudioDevices.deviceID(forUID: configuration.outputDeviceUID),
            let device = AudioDevices.info(for: deviceID)
        else { throw EngineError("Dispositivo di uscita non trovato (\(configuration.outputDeviceUID))") }
        guard device.outputChannelCount >= 2 else { throw EngineError("\(device.name) ha meno di 2 canali di uscita") }
        outputDevice = device

        // Which output stream holds the preferred stereo channels?
        outputStreams = try DeviceStreams.streams(of: deviceID, scope: kAudioObjectPropertyScopeOutput)
        let preferred = AudioDevices.preferredStereoChannels(of: deviceID)
        let leftChannel = preferred?.0 ?? 1
        var streamIndex = 0, streamFirstChannel = 1, firstChannel = 1
        for (index, stream) in outputStreams.enumerated() {
            let count = Int(stream.format.mChannelsPerFrame)
            if leftChannel >= firstChannel && leftChannel < firstChannel + count {
                streamIndex = index
                streamFirstChannel = firstChannel
                break
            }
            firstChannel += count
        }
        Log.engine.info(
            "Starting session \(self.id) on \(device.name, privacy: .public): output streams \(self.outputStreams.map { Int($0.format.mChannelsPerFrame) }, privacy: .public) ch, preferred stereo \(preferred.map { "\($0.0)/\($0.1)" } ?? "n/a (1/2)", privacy: .public) -> tapping stream \(streamIndex)"
        )

        // Tap (own process excluded — mandatory, see ProcessTap).
        let tap: ProcessTap
        do {
            tap = try ProcessTap.create(
                excludedBundleIDs: configuration.excludedBundleIDs, deviceUID: device.uid, stream: UInt(streamIndex))
        } catch {
            throw AudioCapturePermissionError.classify(error, tapCreation: true)
        }
        self.tap = tap
        tapFormat = try tap.format()
        Log.tap.info("Tap format: \(self.tapFormat.logDescription, privacy: .public)")
        Log.tap.info("exclusion-check: description stored by the HAL: \(tap.currentDescriptionSummary(), privacy: .public)")
        guard tapFormat.isFloat32, tapFormat.mChannelsPerFrame >= 1 else {
            throw EngineError("Formato del tap non supportato: \(tapFormat.logDescription)")
        }

        // Capture aggregate: the tap only. Never the device as a sub-device.
        let aggregate = try AggregateDevice.createCapture(tapUID: tap.uid)
        self.aggregate = aggregate
        guard aggregate.activeSubDeviceIDs().isEmpty else {
            throw EngineError("L'aggregato di cattura contiene un dispositivo: avvio annullato")
        }
        let tapStream = try aggregate.waitForTapStream(channels: Int(tapFormat.mChannelsPerFrame))
        self.tapStream = tapStream
        guard tapStream.format.isFloat32 else {
            throw EngineError("Formato dello stream di cattura non supportato: \(tapStream.format.logDescription)")
        }

        // No sample-rate conversion, ever.
        deviceSampleRate = (try? AudioDevices.nominalSampleRate(of: deviceID)) ?? 0
        captureSampleRate = (try? aggregate.nominalSampleRate()) ?? 0
        if let violation = SampleRateGuard.violation(
            tapRate: tapFormat.mSampleRate, deviceRate: deviceSampleRate, captureRate: captureSampleRate)
        {
            Log.engine.error(
                "Rate mismatch: tap \(self.tapFormat.mSampleRate), device \(self.deviceSampleRate), capture \(self.captureSampleRate)")
            throw EngineError(violation)
        }
        sampleRate = deviceSampleRate

        // Layouts, cross-checked with what the HAL will hand the IOProcs.
        let captureLayout = BufferListLayout(streams: [tapStream.formatInfo])
        let outputLayout = BufferListLayout(streams: outputStreams.map(\.formatInfo))
        let reportedCapture = try AudioObject.bufferChannelCounts(aggregate.objectID, scope: kAudioObjectPropertyScopeInput)
        let reportedOutput = try AudioObject.bufferChannelCounts(deviceID, scope: kAudioObjectPropertyScopeOutput)
        guard captureLayout.matches(reportedBufferChannelCounts: reportedCapture),
            outputLayout.matches(reportedBufferChannelCounts: reportedOutput)
        else {
            throw EngineError(
                "Disposizione buffer inattesa: cattura \(reportedCapture) vs \(captureLayout.bufferChannelCounts), "
                    + "uscita \(reportedOutput) vs \(outputLayout.bufferChannelCounts)")
        }
        if let bad = outputStreams.first(where: { !$0.format.isFloat32 }) {
            throw EngineError("Formato di uscita non supportato: \(bad.format.logDescription)")
        }
        self.captureLayout = captureLayout
        self.outputLayout = outputLayout

        // Source = preferred stereo channels within the tapped stream.
        let tapChannels = captureLayout.locations(ofStream: 0)
        let sourcePair = TapChannelSelection.stereoPair(
            tapChannels: tapChannels.count,
            preferredStereo: TapChannelSelection.preferredWithinStream(preferred, streamFirstChannel: streamFirstChannel))
        let sourceLeft = tapChannels[sourcePair.left], sourceRight = tapChannels[sourcePair.right]
        Log.tap.info("Source = tap channels \(sourcePair.left + 1)/\(sourcePair.right + 1) of \(tapChannels.count)")

        // Buffer size: same on both sides, within both ranges.
        let captureRange = (try? DeviceIO.bufferFrameSizeRange(aggregate.objectID)) ?? 0...4096
        let deviceRange = (try? DeviceIO.bufferFrameSizeRange(deviceID)) ?? 0...4096
        let low = max(captureRange.lowerBound, deviceRange.lowerBound)
        let high = max(low, min(captureRange.upperBound, deviceRange.upperBound))
        let frames = BufferSize.clamp(configuration.bufferFrames, minimum: low, maximum: high)
        try DeviceIO.setBufferFrameSize(aggregate.objectID, frames)
        try DeviceIO.setBufferFrameSize(deviceID, frames)
        bufferFrames = (try? DeviceIO.bufferFrameSize(deviceID)) ?? frames

        // Shared state for the two IOProcs.
        let maxOutputFrames = max(4096, deviceRange.upperBound)
        let link = SplitLinkHandle(
            configuration: SplitLinkConfiguration(
                captureLayout: captureLayout, captureLeft: sourceLeft, captureRight: sourceRight,
                ringCapacity: Self.ringCapacity, maxOutputFrames: maxOutputFrames))
        self.link = link
        let pair = configuration.outputPair.right < outputLayout.channelCount ? configuration.outputPair : .firstPair
        let renderState = RenderStateHandle(
            configuration: RenderConfiguration(
                inputLayout: captureLayout, tapLeft: sourceLeft, tapRight: sourceRight, outputLayout: outputLayout,
                sampleRate: sampleRate),
            gain: configuration.gain, bypass: configuration.bypass, outputPair: pair)
        self.renderState = renderState
        let context = UnsafeMutablePointer<SplitOutputContext>.allocate(capacity: 1)
        context.initialize(to: SplitOutputContext(state: renderState.pointer, link: link.pointer))
        outputContext = context

        // IOProcs.
        var captureID: AudioDeviceIOProcID?
        try AudioObject.check(
            AudioDeviceCreateIOProcID(
                aggregate.objectID, unsafeBitCast(captureIOProc as NullableIOProc, to: AudioDeviceIOProc.self),
                link.rawPointer, &captureID),
            "Creazione della callback di cattura")
        captureProcID = captureID
        var outputID: AudioDeviceIOProcID?
        try AudioObject.check(
            AudioDeviceCreateIOProcID(
                deviceID, unsafeBitCast(outputIOProc as NullableIOProc, to: AudioDeviceIOProc.self),
                UnsafeMutableRawPointer(context), &outputID),
            "Creazione della callback di uscita")
        outputProcID = outputID
        guard let captureID, let outputID else { throw EngineError("Creazione delle callback: ID mancante") }

        // Never read the device's hardware inputs (no microphone use).
        let deviceInputs = (try? DeviceStreams.streams(of: deviceID, scope: kAudioObjectPropertyScopeInput))?.count ?? 0
        if deviceInputs > 0 {
            do {
                try DeviceStreams.setInputStreamUsage(
                    device: deviceID, ioProc: outputID, enabled: Array(repeating: false, count: deviceInputs))
            } catch {
                Log.engine.error("Could not disable device inputs: \(error.localizedDescription, privacy: .public)")
            }
        }

        registerListeners(deviceID: deviceID, queue: listenerQueue, signal: signal)

        // Start: capture first, then output (which stays silent while warming up).
        do {
            try AudioObject.check(AudioDeviceStart(aggregate.objectID, captureID), "Avvio della cattura")
            captureStarted = true
            try AudioObject.check(AudioDeviceStart(deviceID, outputID), "Avvio dell'uscita")
            outputStarted = true
        } catch {
            throw AudioCapturePermissionError.classify(error, tapCreation: false)
        }

        let delay = try warmUpAndFixDelay(link: link)
        let info = makeInfo(range: low...high, delay: Int(delay))
        Log.engine.notice(
            "Session \(self.id) running on \(device.name, privacy: .public): \(self.sampleRate) Hz, buffer \(self.bufferFrames), pair \(pair.description, privacy: .public), delay \(delay) frames; latency \(info.latency.detail, privacy: .public) = \(info.latency.totalMilliseconds) ms"
        )
        return info
    }

    /// Warm-up: the output IOProc is silent and measures how far ahead of the
    /// written data it would read. Settle, measure, derive the timeline
    /// offset from the first timestamps, fix the delay.
    private func warmUpAndFixDelay(link: SplitLinkHandle) throws -> Int64 {
        Thread.sleep(forTimeInterval: Self.warmupSettle)
        link.resetWarmupMeasurement()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        Thread.sleep(forTimeInterval: Self.warmupMeasure)
        var measurement = link.warmupMeasurement()
        while (measurement.maxNeed == nil || measurement.samples < 10) && clock.now < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            measurement = link.warmupMeasurement()
        }
        let status = link.status()
        guard let maxNeed = measurement.maxNeed, measurement.samples >= 10 else {
            throw EngineError(
                "Avvio non riuscito: la cattura non riceve dati dal tap "
                    + "(cicli cattura \(status.captureCycles), non validi \(status.captureInvalidCycles), "
                    + "cicli uscita \(status.outputCycles))")
        }

        var offset: Int64 = 0
        if let stamps = link.firstTimestamps() {
            offset = SplitTimeline.offset(
                capture: stamps.capture, output: stamps.output, sampleRate: sampleRate,
                ticksPerSecond: Self.ticksPerSecond)
            Log.engine.notice(
                "Timeline: first capture stamp \(stamps.capture.0)@\(stamps.capture.1), first output stamp \(stamps.output.0)@\(stamps.output.1) -> offset \(offset) frames (expected 0)"
            )
        } else {
            Log.engine.error("Timeline: first timestamps unavailable, assuming offset 0")
        }
        let delay = SplitTimeline.delay(
            maxNeed: maxNeed, offset: offset, margin: Self.delayMargin, minimum: Int64(bufferFrames),
            maximum: link.maximumDelay)
        Log.engine.notice(
            "Delay: max read-ahead need \(maxNeed) frames over \(measurement.samples) cycles, offset \(offset), margin \(Self.delayMargin) -> delay \(delay) frames (\(Double(delay) * 1000 / self.sampleRate) ms)"
        )
        link.start(offset: offset, delay: delay)
        return delay
    }

    /// Host ticks per second (mach timebase).
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000_000 * Double(info.denom) / Double(info.numer)
    }()

    private func registerListeners(deviceID: AudioObjectID, queue: DispatchQueue, signal: @escaping (SessionSignal) -> Void) {
        guard let aggregate, let tap, let renderState, let link else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let wildcard = kAudioObjectPropertyScopeWildcard
        // Each listener is optional: if one can't be registered we log it.
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
        let changed = { signal(.configurationMayHaveChanged) }
        listen(tap.objectID, kAudioTapPropertyFormat, handler: changed)
        for object in [aggregate.objectID, deviceID] {
            listen(object, kAudioDevicePropertyNominalSampleRate, handler: changed)
            listen(object, kAudioDevicePropertyStreamConfiguration, wildcard, handler: changed)
            listen(object, kAudioDevicePropertyStreams, wildcard, handler: changed)
            listen(object, kAudioDevicePropertyDeviceHasChanged, handler: changed)
            listen(object, kAudioDevicePropertyIOStoppedAbnormally) { signal(.ioStoppedAbnormally) }
        }
        listen(deviceID, kAudioDevicePropertyDeviceIsAlive) { signal(.deviceMayBeGone) }
        listen(system, kAudioHardwarePropertyDevices) { signal(.deviceMayBeGone) }
        listen(system, kAudioHardwarePropertyProcessObjectList) { signal(.processListChanged) }

        // Overloads arrive synchronously on the IO threads: C listeners.
        let overload = AudioObject.address(kAudioDeviceProcessorOverload)
        let outputProc = unsafeBitCast(outputOverloadListener as NullableListenerProc, to: AudioObjectPropertyListenerProc.self)
        let captureProc = unsafeBitCast(captureOverloadListener as NullableListenerProc, to: AudioObjectPropertyListenerProc.self)
        do {
            realtimeListeners.append(
                try RealtimeListener(
                    object: deviceID, address: overload, proc: outputProc,
                    clientData: UnsafeMutableRawPointer(renderState.pointer)))
            realtimeListeners.append(
                try RealtimeListener(
                    object: aggregate.objectID, address: overload, proc: captureProc, clientData: link.rawPointer))
        } catch {
            Log.engine.error("Overload listener not installed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Running

    private func makeInfo(range: ClosedRange<Int>, delay: Int) -> SessionInfo {
        SessionInfo(
            sessionID: id,
            outputDevice: outputDevice!,
            sampleRate: sampleRate,
            bufferFrames: bufferFrames,
            bufferSizeOptions: BufferSize.options(minimum: range.lowerBound, maximum: range.upperBound),
            outputPair: renderState!.outputPair,
            latency: currentLatency(),
            delayFrames: delay,
            renderState: renderState!,
            link: link!,
            tapFormatSummary: AudioFormatText.summary(
                sampleRate: tapFormat.mSampleRate, channels: Int(tapFormat.mChannelsPerFrame)))
    }

    /// Latency estimate with the chosen delay (see LatencyComponents.split):
    /// tap extra + tap stream latency + delay + output device latency +
    /// output stream latency, with the delay broken down into capture safety
    /// offset, both buffers, ring time and output safety offset.
    func currentLatency() -> LatencyBreakdown {
        guard let aggregate, let outputDevice, let link, let outputLayout else {
            return LatencyBreakdown(components: LatencyComponents(), sampleRate: sampleRate)
        }
        if cachedTapExtraLatency == nil { cachedTapExtraLatency = aggregate.subTapExtraLatency() }
        let pair = renderState?.outputPair ?? .firstPair
        let streamIndex = outputLayout.location(ofChannel: pair.left)?.stream ?? 0
        let output = kAudioObjectPropertyScopeOutput
        let components = LatencyComponents.split(
            delayFrames: Int(link.status().delayFrames),
            tapExtraFrames: cachedTapExtraLatency ?? 0,
            tapStreamFrames: tapStream.map { DeviceStreams.latency(ofStream: $0.objectID) } ?? 0,
            captureSafetyOffsetFrames: DeviceIO.safetyOffset(aggregate.objectID, scope: kAudioObjectPropertyScopeInput),
            bufferFrames: bufferFrames,
            outputSafetyOffsetFrames: DeviceIO.safetyOffset(outputDevice.objectID, scope: output),
            outputDeviceFrames: DeviceIO.latency(outputDevice.objectID, scope: output),
            outputStreamFrames: outputStreams.indices.contains(streamIndex)
                ? DeviceStreams.latency(ofStream: outputStreams[streamIndex].objectID) : 0)
        return LatencyBreakdown(components: components, sampleRate: sampleRate)
    }

    /// Called about once a second: if underruns happened since the last
    /// call, increase the delay by one step (the output IOProc fades across
    /// the change). Returns the new latency if the delay changed.
    func adaptDelayIfNeeded() -> LatencyBreakdown? {
        guard let link else { return nil }
        let status = link.status()
        defer { underrunsSeen = status.underrunCycles }
        guard status.underrunCycles > underrunsSeen else { return nil }
        let newUnderruns = status.underrunCycles - underrunsSeen
        guard delayIncreases < Self.maxDelayIncreases else {
            Log.engine.error("Underruns (+\(newUnderruns)) but the delay was already increased \(self.delayIncreases) times")
            return nil
        }
        let step = Int64(max(32, bufferFrames / 2))
        let delay = min(status.delayFrames + step, link.maximumDelay)
        guard delay > status.delayFrames else { return nil }
        delayIncreases += 1
        link.setDelay(delay)
        Log.engine.notice(
            "Underruns (+\(newUnderruns), missing \(status.missingFrames) frames total): delay \(status.delayFrames) -> \(delay) frames")
        return currentLatency()
    }

    /// Returns a reason if the sample rate, tap format or stream layout no
    /// longer match what the session was built for, nil otherwise.
    func configurationChangeReason() -> String? {
        guard let aggregate, let tap, let outputDevice, let captureLayout, let outputLayout else { return nil }
        if let format = try? tap.format(),
            format.mSampleRate != tapFormat.mSampleRate || format.mChannelsPerFrame != tapFormat.mChannelsPerFrame
        {
            return "formato del tap cambiato (\(format.logDescription))"
        }
        if let rate = try? AudioDevices.nominalSampleRate(of: outputDevice.objectID), rate != deviceSampleRate {
            return "frequenza di \(outputDevice.name) cambiata (\(deviceSampleRate) -> \(rate) Hz)"
        }
        if let rate = try? aggregate.nominalSampleRate(), rate != captureSampleRate {
            return "frequenza di cattura cambiata (\(captureSampleRate) -> \(rate) Hz)"
        }
        let captureCounts = try? AudioObject.bufferChannelCounts(aggregate.objectID, scope: kAudioObjectPropertyScopeInput)
        let outputCounts = try? AudioObject.bufferChannelCounts(outputDevice.objectID, scope: kAudioObjectPropertyScopeOutput)
        if captureCounts != captureLayout.bufferChannelCounts || outputCounts != outputLayout.bufferChannelCounts {
            return "disposizione degli stream cambiata (cattura \(captureCounts ?? []), uscita \(outputCounts ?? []))"
        }
        let outputIDs = (try? DeviceStreams.streams(of: outputDevice.objectID, scope: kAudioObjectPropertyScopeOutput))?
            .map(\.objectID)
        if outputIDs != outputStreams.map(\.objectID) { return "stream di uscita sostituiti" }
        if !aggregate.activeSubDeviceIDs().isEmpty { return "l'aggregato di cattura ha acquisito un dispositivo" }
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
            let stillAlive = tap.excludedProcesses.filter { alive.contains($0) }
            try tap.replaceExcludedProcesses(stillAlive + newcomers.map(\.object))
        } catch {
            Log.tap.error("exclusion-check: tap update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Stop

    /// Stops and destroys everything, in the safe order: listeners (the
    /// real-time ones first), output IO, capture IO, both IOProcs (after this
    /// Core Audio no longer touches the shared state), aggregate, tap, then
    /// the shared state. Safe to call more than once and after a partial start.
    func teardown() {
        realtimeListeners.forEach { $0.remove() }
        realtimeListeners.removeAll()
        listeners.forEach { $0.remove() }
        listeners.removeAll()

        let deviceID = outputDevice?.objectID
        if let deviceID, let outputProcID, outputStarted {
            report(AudioDeviceStop(deviceID, outputProcID), "AudioDeviceStop (output)")
            outputStarted = false
        }
        if let aggregate, let captureProcID, captureStarted {
            report(AudioDeviceStop(aggregate.objectID, captureProcID), "AudioDeviceStop (capture)")
            captureStarted = false
        }
        if let deviceID, let outputProcID {
            report(AudioDeviceDestroyIOProcID(deviceID, outputProcID), "AudioDeviceDestroyIOProcID (output)")
            self.outputProcID = nil
        }
        if let aggregate, let captureProcID {
            report(AudioDeviceDestroyIOProcID(aggregate.objectID, captureProcID), "AudioDeviceDestroyIOProcID (capture)")
            self.captureProcID = nil
        }
        aggregate?.destroy()
        aggregate = nil
        tap?.destroy()
        tap = nil
        if let outputContext {
            outputContext.deinitialize(count: 1)
            outputContext.deallocate()
            self.outputContext = nil
        }
        renderState = nil
        link = nil
        Log.engine.info("Session \(self.id) torn down")
    }

    private func report(_ status: OSStatus, _ operation: String) {
        if status != noErr { Log.engine.error("\(operation, privacy: .public): \(describeOSStatus(status), privacy: .public)") }
    }
}
