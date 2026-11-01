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
    /// Preamp as linear gain (0...1, never a boost).
    var gain: Float
    /// EQ bands; the coefficients are computed for the session's actual
    /// sample rate when the render state is built.
    var bands: [EQBand]
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
    /// The delay actually in use (frames).
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
    /// Sample rate, tap format or stream layout may have changed. (Rate
    /// mismatches are additionally muted right away on the listener queue.)
    case configurationMayHaveChanged
    case deviceMayBeGone
    case ioStoppedAbnormally
    case processListChanged
}

// MARK: - Session

/// Result of a maintenance tick (engine queue, every ~100 ms).
enum MaintenanceResult {
    case ok
    /// Delay grown after underruns, or values settled after start.
    case latencyChanged(LatencyBreakdown)
    /// RoomEQ cannot deliver audio: the engine must stop this session now
    /// (releasing the tap) and show `message`.
    case fatal(String)
}

final class EngineSession {
    /// One-block delay increases allowed after underruns before giving up.
    static let maxDelayIncreases = 4
    /// Warm-up timing (seconds). The tapped apps are muted from the first
    /// capture cycle, so the whole warm-up must stay within ~1 s.
    static let warmupSettle = 0.15
    static let warmupWindow = 0.4
    static let warmupDeadline = 1.0

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

    // Maintenance state (engine queue).
    private var health = SplitHealthMonitor()
    private var adaptation = DelayAdaptation(maximumIncreases: EngineSession.maxDelayIncreases)
    private var drift: DriftMonitor?
    private var underrunsSeen: UInt64 = 0
    private var runningSeconds = 0.0
    private var driftAccumulator = 0.0
    private var lastNeedTotals: (sum: Int64, count: Int64) = (0, 0)
    private var latencySettled = false

    init(id: Int, configuration: EngineConfiguration) {
        self.id = id
        self.configuration = configuration
    }

    // MARK: Start

    /// Builds and starts everything, including the warm-up that fixes the
    /// delay (blocks < ~1 s). On error, call `teardown()`.
    func start(listenerQueue: DispatchQueue, signal: @escaping (SessionSignal) -> Void) throws -> SessionInfo {
        // Output device (= tapped device).
        guard let deviceID = AudioDevices.deviceID(forUID: configuration.outputDeviceUID),
            let device = AudioDevices.info(for: deviceID)
        else { throw EngineError("Dispositivo di uscita non trovato (\(configuration.outputDeviceUID))") }
        guard device.outputChannelCount >= 2 else { throw EngineError("\(device.name) ha meno di 2 canali di uscita") }
        outputDevice = device

        // Source: the output stream holding the preferred stereo channels.
        outputStreams = try DeviceStreams.streams(of: deviceID, scope: kAudioObjectPropertyScopeOutput)
        let preferred = AudioDevices.preferredStereoChannels(of: deviceID)
        let streamCounts = outputStreams.map { Int($0.format.mChannelsPerFrame) }
        let source: TapSource
        switch TapSourceSelection.locate(preferred: preferred, streamChannelCounts: streamCounts) {
        case .success(let located): source = located
        case .failure(let error):
            Log.engine.error("Source selection refused: streams \(streamCounts, privacy: .public), preferred \(preferred.map { "\($0.0)/\($0.1)" } ?? "n/a", privacy: .public)")
            throw EngineError(error.message)
        }
        Log.engine.info(
            "Starting session \(self.id) on \(device.name, privacy: .public): output streams \(streamCounts, privacy: .public) ch, preferred stereo \(preferred.map { "\($0.0)/\($0.1)" } ?? "n/a (1/2)", privacy: .public) -> stream \(source.stream), channels \(source.left + 1)/\(source.right + 1)"
        )

        // Tap (own process excluded — mandatory, see ProcessTap).
        let tap: ProcessTap
        do {
            tap = try ProcessTap.create(
                excludedBundleIDs: configuration.excludedBundleIDs, deviceUID: device.uid, stream: UInt(source.stream))
        } catch {
            throw AudioCapturePermissionError.classify(error, tapCreation: true)
        }
        self.tap = tap
        tapFormat = try tap.format()
        Log.tap.info("Tap format: \(self.tapFormat.logDescription, privacy: .public)")
        Log.tap.info("exclusion-check: description stored by the HAL: \(tap.currentDescriptionSummary(), privacy: .public)")
        guard tapFormat.isFloat32, Int(tapFormat.mChannelsPerFrame) == streamCounts[source.stream] else {
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
        try checkRates(deviceID: deviceID, aggregate: aggregate, tap: tap, initial: true)
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
        let tapChannels = captureLayout.locations(ofStream: 0)
        let sourceLeft = tapChannels[source.left], sourceRight = tapChannels[source.right]

        // Buffer size: the same on both sides, within both ranges.
        let captureRange = (try? DeviceIO.bufferFrameSizeRange(aggregate.objectID)) ?? 0...4096
        let deviceRange = (try? DeviceIO.bufferFrameSizeRange(deviceID)) ?? 0...4096
        let low = max(captureRange.lowerBound, deviceRange.lowerBound)
        let high = max(low, min(captureRange.upperBound, deviceRange.upperBound))
        let requested = BufferSize.clamp(configuration.bufferFrames, minimum: low, maximum: high)
        try DeviceIO.setBufferFrameSize(aggregate.objectID, requested)
        try DeviceIO.setBufferFrameSize(deviceID, requested)
        let captureBuffer = (try? DeviceIO.bufferFrameSize(aggregate.objectID)) ?? requested
        bufferFrames = (try? DeviceIO.bufferFrameSize(deviceID)) ?? requested
        let maxCallback = max(
            max(bufferFrames, captureBuffer),
            max(DeviceIO.variableBufferFrameSize(deviceID) ?? 0, DeviceIO.variableBufferFrameSize(aggregate.objectID) ?? 0))

        // Shared state, sized from the configured buffers.
        let captureSafety = DeviceIO.safetyOffset(aggregate.objectID, scope: kAudioObjectPropertyScopeInput)
        let outputSafety = DeviceIO.safetyOffset(deviceID, scope: kAudioObjectPropertyScopeOutput)
        let sizing = SplitLinkSizing.make(
            maxCallbackFrames: maxCallback, safetyOffsets: captureSafety + outputSafety,
            delayIncreases: Self.maxDelayIncreases)
        let link = SplitLinkHandle(
            configuration: SplitLinkConfiguration(
                captureLayout: captureLayout, captureLeft: sourceLeft, captureRight: sourceRight, sizing: sizing))
        self.link = link
        Log.engine.info(
            "Buffers: capture \(captureBuffer), output \(self.bufferFrames), largest callback \(maxCallback); ring \(link.capacity) frames, maximum delay \(link.maximumDelay)"
        )
        let pair = configuration.outputPair.right < outputLayout.channelCount ? configuration.outputPair : .firstPair
        // EQ coefficients for THIS session's sample rate (active from the
        // first rendered sample, no ramp needed).
        let design = EQDesign(bands: configuration.bands, sampleRate: sampleRate)
        for warning in design.warnings {
            Log.engine.notice("EQ at \(self.sampleRate) Hz: \(warning, privacy: .public)")
        }
        let renderState = RenderStateHandle(
            configuration: RenderConfiguration(
                inputLayout: captureLayout, tapLeft: sourceLeft, tapRight: sourceRight, outputLayout: outputLayout,
                sampleRate: sampleRate),
            // The kernel's bypass is never used: switching off stops RoomEQ.
            gain: configuration.gain, bypass: false, outputPair: pair, filters: design.sections)
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
                Log.engine.warning("Could not disable device inputs (continuing): \(error.localizedDescription, privacy: .public)")
            }
        }

        registerListeners(deviceID: deviceID, queue: listenerQueue, signal: signal)
        // Close the window between the first check and the listeners.
        try checkRates(deviceID: deviceID, aggregate: aggregate, tap: tap, initial: false)

        // Start: capture first, then output (silent while warming up).
        do {
            try AudioObject.check(AudioDeviceStart(aggregate.objectID, captureID), "Avvio della cattura")
            captureStarted = true
            try AudioObject.check(AudioDeviceStart(deviceID, outputID), "Avvio dell'uscita")
            outputStarted = true
        } catch {
            throw AudioCapturePermissionError.classify(error, tapCreation: false)
        }

        let delay = try warmUpAndFixDelay(link: link)
        drift = DriftMonitor(sampleRate: sampleRate, bufferFrames: bufferFrames)
        let status = link.status()
        lastNeedTotals = (status.needSum, status.needCount)
        let info = makeInfo(range: low...high, delay: Int(delay))
        Log.engine.notice(
            "Session \(self.id) running on \(device.name, privacy: .public): \(self.sampleRate) Hz, buffer \(self.bufferFrames), pair \(pair.description, privacy: .public), delay \(delay) frames; latency \(info.latency.detail, privacy: .public) = \(info.latency.totalMilliseconds) ms"
        )
        return info
    }

    /// No-SRC guard: tap rate == device nominal rate == capture rate.
    private func checkRates(deviceID: AudioObjectID, aggregate: AggregateDevice, tap: ProcessTap, initial: Bool) throws {
        let tapRate = (try? tap.format().mSampleRate) ?? 0
        let deviceRate = (try? AudioDevices.nominalSampleRate(of: deviceID)) ?? 0
        let captureRate = (try? aggregate.nominalSampleRate()) ?? 0
        if let violation = SampleRateGuard.violation(tapRate: tapRate, deviceRate: deviceRate, captureRate: captureRate) {
            Log.engine.error("Rate mismatch (\(initial ? "start" : "after listeners", privacy: .public)): tap \(tapRate), device \(deviceRate), capture \(captureRate)")
            throw EngineError(violation)
        }
        if initial {
            deviceSampleRate = deviceRate
            captureSampleRate = captureRate
        } else if !SampleRates.same(deviceRate, deviceSampleRate) || !SampleRates.same(captureRate, captureSampleRate) {
            throw EngineError("La frequenza di campionamento è cambiata durante l'avvio: riprova.")
        }
    }

    /// Warm-up: the output IOProc is silent and records `need` every cycle.
    /// A window counts only if both sides ran normally during it (no stall,
    /// gap, overload or invalid cycle); otherwise it is repeated, within
    /// `warmupDeadline`. Delay = max(need) + one block.
    private func warmUpAndFixDelay(link: SplitLinkHandle) throws -> Int64 {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(Self.warmupDeadline)
        Thread.sleep(forTimeInterval: Self.warmupSettle)
        let expectedCycles = Self.warmupWindow * sampleRate / Double(max(1, bufferFrames))
        var attempts = 0
        while true {
            attempts += 1
            let before = link.status()
            let marker = link.needHistoryPosition
            Thread.sleep(forTimeInterval: Self.warmupWindow)
            let after = link.status()
            if WarmupAnalysis.windowIsClean(before: before, after: after, expectedCycles: expectedCycles),
                let needs = link.needValues(since: marker), let stats = WarmupAnalysis.statistics(needs)
            {
                logTimeline(link: link)
                switch DelayPolicy.initialDelay(maxNeed: stats.max, block: bufferFrames, maximum: link.maximumDelay) {
                case .success(let delay):
                    Log.engine.notice(
                        "Delay: need min \(stats.min) / median \(stats.median) / max \(stats.max) frames over \(needs.count) cycles (attempt \(attempts)), margin \(self.bufferFrames) -> delay \(delay) frames (\(Double(delay) * 1000 / self.sampleRate) ms)"
                    )
                    link.setDelay(delay)
                    return delay
                case .failure(let error):
                    Log.engine.error("Delay: need max \(stats.max) exceeds the maximum \(link.maximumDelay)")
                    throw EngineError(error.message)
                }
            }
            Log.engine.notice(
                "Warm-up window \(attempts) rejected: capture +\(after.captureCycles &- before.captureCycles), output +\(after.outputCycles &- before.outputCycles) (expected ~\(Int(expectedCycles))), discontinuities +\(after.discontinuities &- before.discontinuities), overloads +\(after.captureOverloads &- before.captureOverloads), invalid capture +\(after.captureInvalidCycles &- before.captureInvalidCycles) / output +\(after.outputInvalidCycles &- before.outputInvalidCycles)"
            )
            guard clock.now + .seconds(Self.warmupWindow) <= deadline else {
                throw EngineError(
                    "Avvio non riuscito: la cattura o l'uscita non funzionano in modo regolare "
                        + "(cicli cattura \(after.captureCycles), uscita \(after.outputCycles)).")
            }
        }
    }

    /// Diagnostics only: relation of the two timelines from the first
    /// timestamps, when the HAL marked both host times valid.
    private func logTimeline(link: SplitLinkHandle) {
        guard let stamps = link.firstTimestamps() else { return }
        guard stamps.capture.host != 0, stamps.output.host != 0 else {
            Log.engine.info("Timeline: first samples capture \(stamps.capture.sample), output \(stamps.output.sample) (host times not valid)")
            return
        }
        let gap = Double(Int64(bitPattern: stamps.output.host &- stamps.capture.host)) / Self.ticksPerSecond
        let offset = Double(stamps.capture.sample) + gap * sampleRate - Double(stamps.output.sample)
        Log.engine.notice(
            "Timeline (diagnostic): capture \(stamps.capture.sample)@\(stamps.capture.host), output \(stamps.output.sample)@\(stamps.output.host) -> offset \(String(format: "%.1f", offset), privacy: .public) frames (expected 0; not used for reading)"
        )
    }

    /// Host ticks per second (mach timebase), for diagnostics.
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
        // A rate change must not play even briefly with mismatched rates:
        // check right here (listener queue) and mute the output at once;
        // the engine then rebuilds the session.
        let tapID = tap.objectID, aggregateID = aggregate.objectID
        let expectedRate = deviceSampleRate
        let rateChanged = {
            let tapRate = (try? AudioObject.read(
                tapID, AudioObject.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription(),
                "Formato tap").mSampleRate) ?? 0
            let deviceRate = (try? AudioDevices.nominalSampleRate(of: deviceID)) ?? 0
            let captureRate = (try? AudioDevices.nominalSampleRate(of: aggregateID)) ?? 0
            if !SampleRates.same(tapRate, expectedRate) || !SampleRates.same(deviceRate, expectedRate)
                || !SampleRates.same(captureRate, expectedRate)
            {
                link.setMuted(true)
                Log.engine.notice("Rate change detected (tap \(tapRate), device \(deviceRate), capture \(captureRate)): output muted")
            }
            signal(.configurationMayHaveChanged)
        }
        listen(tap.objectID, kAudioTapPropertyFormat, handler: rateChanged)
        for object in [aggregate.objectID, deviceID] {
            listen(object, kAudioDevicePropertyNominalSampleRate, handler: rateChanged)
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

    /// Latency estimate with the active delay (see Latency.swift for why
    /// the safety offsets and buffers are not added on top of the delay).
    func currentLatency() -> LatencyBreakdown {
        guard let aggregate, let outputDevice, let link, let outputLayout else {
            return LatencyBreakdown(components: LatencyComponents(), sampleRate: sampleRate)
        }
        if cachedTapExtraLatency == nil { cachedTapExtraLatency = aggregate.subTapExtraLatency() }
        let pair = renderState?.outputPair ?? .firstPair
        let streamIndex = outputLayout.location(ofChannel: pair.left)?.stream ?? 0
        let output = kAudioObjectPropertyScopeOutput
        let components = LatencyComponents(
            delayFrames: Int(link.status().delayFrames),
            tapExtraFrames: cachedTapExtraLatency ?? 0,
            tapStreamFrames: tapStream.map { DeviceStreams.latency(ofStream: $0.objectID) } ?? 0,
            outputDeviceFrames: DeviceIO.latency(outputDevice.objectID, scope: output),
            outputStreamFrames: outputStreams.indices.contains(streamIndex)
                ? DeviceStreams.latency(ofStream: outputStreams[streamIndex].objectID) : 0,
            bufferFrames: bufferFrames,
            captureSafetyOffsetFrames: DeviceIO.safetyOffset(aggregate.objectID, scope: kAudioObjectPropertyScopeInput),
            outputSafetyOffsetFrames: DeviceIO.safetyOffset(outputDevice.objectID, scope: output))
        return LatencyBreakdown(components: components, sampleRate: sampleRate)
    }

    /// Called every ~100 ms on the engine queue:
    /// 1. health (stalls, unplayable output) -> fatal;
    /// 2. underruns -> grow the delay by one block (fade in the IOProc); at
    ///    the cap -> fatal;
    /// 3. once per second: drift of the mean `need` -> fatal on clock mismatch.
    func maintenanceTick(elapsed: Double) -> MaintenanceResult {
        guard let link else { return .ok }
        let status = link.status()
        runningSeconds += elapsed

        if let problem = health.update(
            captureCycles: status.captureCycles, outputCycles: status.outputCycles,
            badOutputCycles: status.badOutputCycles, elapsed: elapsed)
        {
            Log.engine.error(
                "Health: \(String(describing: problem), privacy: .public) (capture \(status.captureCycles), output \(status.outputCycles), bad \(status.badOutputCycles), gaps \(status.gapCycles), overwritten \(status.overwrittenCycles))"
            )
            return .fatal(problem.message)
        }

        var result = MaintenanceResult.ok
        let newUnderruns = status.underrunCycles &- underrunsSeen
        underrunsSeen = status.underrunCycles
        switch adaptation.evaluate(
            newUnderruns: newUnderruns, currentDelay: status.delayFrames, block: bufferFrames,
            maximum: link.maximumDelay)
        {
        case .none: break
        case .increase(let delay):
            link.setDelay(delay)
            Log.engine.notice(
                "Underruns (+\(newUnderruns), \(status.missingFrames) frames missing so far): delay \(status.delayFrames) -> \(delay) frames (increase \(self.adaptation.increases)/\(Self.maxDelayIncreases))"
            )
            result = .latencyChanged(currentLatency())
        case .fail:
            Log.engine.error("Underruns continue at the delay cap (\(status.delayFrames) frames): stopping")
            return .fatal(DelayAdaptation.failureMessage)
        }

        driftAccumulator += elapsed
        if driftAccumulator >= 1, var drift {
            driftAccumulator = 0
            let count = status.needCount - lastNeedTotals.count
            if count > 0 {
                let mean = Double(status.needSum - lastNeedTotals.sum) / Double(count)
                let mismatch = drift.add(meanNeed: mean, at: runningSeconds)
                self.drift = drift
                if Int(runningSeconds) % 10 == 0 {
                    Log.engine.debug(
                        "Drift: mean need \(String(format: "%.2f", mean), privacy: .public) frames, change \(String(format: "%.2f", drift.lagChange ?? 0), privacy: .public), trend \(drift.trendPPM.map { String(format: "%.2f ppm", $0) } ?? "n/a", privacy: .public)"
                    )
                }
                if mismatch {
                    Log.engine.error(
                        "Drift: clocks differ (change \(drift.lagChange ?? 0) frames, trend \(drift.trendPPM ?? 0) ppm): stopping")
                    return .fatal(DriftMonitor.message)
                }
            }
            lastNeedTotals = (status.needSum, status.needCount)
            if !latencySettled {
                latencySettled = true
                if case .ok = result { result = .latencyChanged(currentLatency()) }
            }
        }
        return result
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
        if let rate = try? AudioDevices.nominalSampleRate(of: outputDevice.objectID), !SampleRates.same(rate, deviceSampleRate) {
            return "frequenza di \(outputDevice.name) cambiata (\(deviceSampleRate) -> \(rate) Hz)"
        }
        if let rate = try? aggregate.nominalSampleRate(), !SampleRates.same(rate, captureSampleRate) {
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
        if link?.status().muted == true { return "uscita silenziata per cambio di frequenza" }
        return nil
    }

    /// True while the output device is still connected.
    func outputDeviceIsPresent() -> Bool {
        guard let outputDevice else { return false }
        guard let id = AudioDevices.deviceID(forUID: outputDevice.uid) else { return false }
        return AudioDevices.isAlive(id)
    }

    /// Applies a changed exclusion list to the running tap (no rebuild).
    func updateExclusions(bundleIDs: [String]) throws {
        guard let tap else { throw EngineError("Nessun tap attivo") }
        try tap.updateExclusions(bundleIDs: bundleIDs)
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

    /// Stops and destroys everything, in the safe order: a short fade-out
    /// (gain ramp), listeners (real-time ones first), output IO, capture IO,
    /// both IOProcs (after this Core Audio no longer touches the shared
    /// state), aggregate, tap, then the shared state. If stopping or
    /// destroying an IOProc fails, the shared state is deliberately LEAKED
    /// (an IOProc might still use it). Safe to call more than once.
    func teardown(fadeOut: Bool = true) {
        if fadeOut, outputStarted, let renderState {
            renderState.setGain(linear: 0)  // 15 ms ramp
            Thread.sleep(forTimeInterval: 0.025)
        }
        realtimeListeners.forEach { $0.remove() }
        realtimeListeners.removeAll()
        listeners.forEach { $0.remove() }
        listeners.removeAll()

        var clean = true
        let deviceID = outputDevice?.objectID
        if let deviceID, let outputProcID, outputStarted {
            clean = report(AudioDeviceStop(deviceID, outputProcID), "AudioDeviceStop (output)") && clean
            outputStarted = false
        }
        if let aggregate, let captureProcID, captureStarted {
            clean = report(AudioDeviceStop(aggregate.objectID, captureProcID), "AudioDeviceStop (capture)") && clean
            captureStarted = false
        }
        if let deviceID, let outputProcID {
            clean = report(AudioDeviceDestroyIOProcID(deviceID, outputProcID), "AudioDeviceDestroyIOProcID (output)") && clean
            self.outputProcID = nil
        }
        if let aggregate, let captureProcID {
            clean = report(AudioDeviceDestroyIOProcID(aggregate.objectID, captureProcID), "AudioDeviceDestroyIOProcID (capture)") && clean
            self.captureProcID = nil
        }
        aggregate?.destroy()
        aggregate = nil
        tap?.destroy()
        tap = nil
        if clean {
            if let outputContext {
                outputContext.deinitialize(count: 1)
                outputContext.deallocate()
            }
        } else {
            // An IOProc may still reference this memory: leak it on purpose.
            if let renderState { _ = Unmanaged.passRetained(renderState) }
            if let link { _ = Unmanaged.passRetained(link) }
            Log.engine.fault("Session \(self.id): IO did not stop cleanly; shared audio state leaked on purpose")
        }
        outputContext = nil
        renderState = nil
        link = nil
        Log.engine.info("Session \(self.id) torn down")
    }

    @discardableResult
    private func report(_ status: OSStatus, _ operation: String) -> Bool {
        if status != noErr { Log.engine.error("\(operation, privacy: .public): \(describeOSStatus(status), privacy: .public)") }
        return status == noErr
    }
}
