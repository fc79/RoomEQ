// The private aggregate device that joins the tap and the output device.
//
// Composition:
//   - sub-device: the selected output device (e.g. Quantum LT 16), which is
//     also the "main" device (its clock drives the aggregate);
//   - tap: our process tap, with drift compensation (the tap's audio is
//     resampled to follow the output device's clock).
// Our IOProc on the aggregate therefore sees, in ONE callback and ONE clock
// domain: input = [output device's own input streams..., tap stream],
// output = [output device's output streams].
//
// The aggregate is private ("not persistent across launches" per the
// header): only this process sees it, and the HAL removes it when the
// process exits — including after a crash (see LeftoverCleanup.swift).

import CoreAudio
import Foundation
import RoomEQCore

/// One stream of a device.
struct StreamInfo {
    let objectID: AudioStreamID
    let format: AudioStreamBasicDescription

    var formatInfo: StreamFormatInfo {
        StreamFormatInfo(channels: Int(format.mChannelsPerFrame), isInterleaved: !format.isNonInterleaved)
    }
}

enum DeviceStreams {
    static func streams(of device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [StreamInfo] {
        let ids = try AudioObject.readArray(
            device, AudioObject.address(kAudioDevicePropertyStreams, scope), element: AudioStreamID(0),
            "Lettura stream del dispositivo")
        return try ids.map { id in
            let format = try AudioObject.read(
                id, AudioObject.address(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription(),
                "Lettura formato stream")
            return StreamInfo(objectID: id, format: format)
        }
    }

    static func latency(ofStream stream: AudioStreamID) -> Int {
        let frames: UInt32? = try? AudioObject.read(
            stream, AudioObject.address(kAudioStreamPropertyLatency), initial: UInt32(0), "Latenza stream")
        return Int(frames ?? 0)
    }
}

/// An owned private aggregate device. Call `destroy()` when done.
final class AggregateDevice {
    static let deviceName = "RoomEQ Aggregate"

    let objectID: AudioObjectID
    let uid: String
    private var destroyed = false

    private init(objectID: AudioObjectID, uid: String) {
        self.objectID = objectID
        self.uid = uid
    }

    deinit {
        if !destroyed { Log.engine.fault("AggregateDevice released without destroy()") }
    }

    static func create(mainDeviceUID: String, tapUID: String) throws -> AggregateDevice {
        let uid = "\(AudioDevices.ownAggregateUIDPrefix).\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: deviceName,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: mainDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            // No tap auto-start: AudioDeviceStart returns immediately and the
            // tap delivers silence until an app plays. (With auto-start the
            // start call would block until audio arrives.) Starting happens on
            // the engine queue anyway, never on the main thread.
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: mainDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 1,
                ]
            ],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try AudioObject.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "Creazione del dispositivo aggregato")
        Log.engine.info("Aggregate created: id \(id), uid \(uid, privacy: .public), main \(mainDeviceUID, privacy: .public)")
        return AggregateDevice(objectID: id, uid: uid)
    }

    /// The HAL may finish building the aggregate's streams asynchronously.
    /// Waits (max `timeout` seconds, polling) until it has at least
    /// `minimumInputStreams` input streams and one output stream.
    /// Blocks the calling thread: only call on the engine queue.
    func waitForStreams(minimumInputStreams: Int, timeout: TimeInterval = 2) {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var inputCount = 0, outputCount = 0
        repeat {
            inputCount = (try? DeviceStreams.streams(of: objectID, scope: kAudioObjectPropertyScopeInput).count) ?? 0
            outputCount = (try? DeviceStreams.streams(of: objectID, scope: kAudioObjectPropertyScopeOutput).count) ?? 0
            if inputCount >= minimumInputStreams && outputCount > 0 { return }
            // If the HAL doesn't include the hardware inputs, fewer streams
            // than expected is the final state: accept it after 0.5 s.
            if inputCount >= 1 && outputCount > 0 && Date().timeIntervalSince(start) > 0.5 {
                Log.engine.notice("Aggregate has \(inputCount) input stream(s), fewer than the \(minimumInputStreams) expected")
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        Log.engine.error(
            "Aggregate streams not complete after \(timeout)s: \(inputCount) input, \(outputCount) output (expected >= \(minimumInputStreams) input)"
        )
    }

    // MARK: Properties

    func nominalSampleRate() throws -> Double { try AudioDevices.nominalSampleRate(of: objectID) }

    func bufferFrameSize() throws -> Int {
        Int(
            try AudioObject.read(
                objectID, AudioObject.address(kAudioDevicePropertyBufferFrameSize), initial: UInt32(0),
                "Lettura dimensione buffer"))
    }

    func bufferFrameSizeRange() throws -> ClosedRange<Int> {
        let range = try AudioObject.read(
            objectID, AudioObject.address(kAudioDevicePropertyBufferFrameSizeRange), initial: AudioValueRange(),
            "Lettura intervallo dimensione buffer")
        let low = Int(range.mMinimum.rounded(.up))
        let high = max(low, Int(range.mMaximum.rounded(.down)))
        return low...high
    }

    /// Sets the IO buffer size. Allowed while running: the HAL reconfigures
    /// the IO cycle and our render code handles any size.
    func setBufferFrameSize(_ frames: Int) throws {
        try AudioObject.write(
            objectID, AudioObject.address(kAudioDevicePropertyBufferFrameSize), value: UInt32(frames),
            "Impostazione dimensione buffer")
    }

    func deviceLatency(scope: AudioObjectPropertyScope) -> Int {
        let frames: UInt32? = try? AudioObject.read(
            objectID, AudioObject.address(kAudioDevicePropertyLatency, scope), initial: UInt32(0), "Latenza")
        return Int(frames ?? 0)
    }

    func safetyOffset(scope: AudioObjectPropertyScope) -> Int {
        let frames: UInt32? = try? AudioObject.read(
            objectID, AudioObject.address(kAudioDevicePropertySafetyOffset, scope), initial: UInt32(0),
            "Safety offset")
        return Int(frames ?? 0)
    }

    /// Object IDs of the aggregate's sub-taps.
    func subTapIDs() -> [AudioObjectID] {
        (try? AudioObject.readArray(
            objectID, AudioObject.address(kAudioAggregateDevicePropertySubTapList),
            element: AudioObjectID(kAudioObjectUnknown), "Lettura sub-tap")) ?? []
    }

    /// Restricts which INPUT streams the IOProc receives
    /// (`kAudioDevicePropertyIOProcStreamUsage`). Disabled streams arrive as
    /// buffers with NULL data. We disable the output device's own hardware
    /// inputs so they are not transferred (and, hopefully, so the system
    /// doesn't consider us a microphone user — unverified, see report).
    func setInputStreamUsage(ioProc: AudioDeviceIOProcID, enabled: [Bool]) throws {
        var address = AudioObject.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try AudioObject.check(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "Lettura uso stream (dimensione)")
        let headerSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let byteCount = max(Int(size), headerSize + enabled.count * MemoryLayout<UInt32>.size)
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self)
        var getSize = UInt32(byteCount)
        try AudioObject.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &getSize, raw), "Lettura uso stream")

        let streamCount = Int(usage.pointee.mNumberStreams)
        guard streamCount == enabled.count else {
            throw EngineError("Uso stream: \(streamCount) stream riportati, \(enabled.count) attesi")
        }
        let flags = (raw + headerSize).assumingMemoryBound(to: UInt32.self)
        for index in 0..<streamCount { flags[index] = enabled[index] ? 1 : 0 }
        try AudioObject.check(
            AudioObjectSetPropertyData(objectID, &address, 0, nil, getSize, raw), "Impostazione uso stream")
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        let status = AudioHardwareDestroyAggregateDevice(objectID)
        if status == noErr {
            Log.engine.info("Aggregate \(self.objectID) destroyed")
        } else {
            Log.engine.error(
                "Destroying aggregate \(self.objectID) failed: \(describeOSStatus(status), privacy: .public)")
        }
    }
}

/// Where everything is inside the aggregate's buffer lists.
struct AggregateLayout {
    let inputStreams: [StreamInfo]
    let outputStreams: [StreamInfo]
    let inputLayout: BufferListLayout
    let outputLayout: BufferListLayout
    /// Index (in `inputStreams`) of the tap's stream.
    let tapStreamIndex: Int
    /// How the tap stream was identified (for the log).
    let identificationMethod: String

    var tapStream: StreamInfo { inputStreams[tapStreamIndex] }

    /// Analyses the aggregate and finds the tap's input stream.
    ///
    /// Identification, most to least reliable:
    ///  1. Ownership: streams owned by the aggregate's sub-tap (or the tap
    ///     object) via `kAudioObjectPropertyOwnedObjects` filtered by stream
    ///     class, matched against the aggregate's input stream IDs.
    ///  2. Position: the aggregate lists sub-device streams first, taps
    ///     after. With H = number of input streams of the output device,
    ///     the tap is stream H, if the aggregate has exactly H + 1 input
    ///     streams and stream H has the tap's channel count.
    ///  3. Fallback: the last input stream whose channel count equals the
    ///     tap's (logged as a warning).
    /// The buffer list layout is then derived from the stream formats and
    /// cross-checked against kAudioDevicePropertyStreamConfiguration.
    static func analyze(
        aggregate: AggregateDevice, outputDevice: AudioObjectID, tap: ProcessTap, tapFormat: AudioStreamBasicDescription
    ) throws -> AggregateLayout {
        let inputs = try DeviceStreams.streams(of: aggregate.objectID, scope: kAudioObjectPropertyScopeInput)
        let outputs = try DeviceStreams.streams(of: aggregate.objectID, scope: kAudioObjectPropertyScopeOutput)
        let hardwareInputs = (try? DeviceStreams.streams(of: outputDevice, scope: kAudioObjectPropertyScopeInput)) ?? []
        let tapChannels = Int(tapFormat.mChannelsPerFrame)

        for (index, stream) in inputs.enumerated() {
            Log.engine.info("Aggregate input stream \(index): id \(stream.objectID), \(stream.format.logDescription, privacy: .public)")
        }
        for (index, stream) in outputs.enumerated() {
            Log.engine.info("Aggregate output stream \(index): id \(stream.objectID), \(stream.format.logDescription, privacy: .public)")
        }

        // 1. Ownership.
        var byOwnership: Int?
        for owner in aggregate.subTapIDs() + [tap.objectID] {
            let owned: [AudioObjectID] =
                (try? AudioObject.readArray(
                    owner, AudioObject.address(kAudioObjectPropertyOwnedObjects),
                    qualifier: AudioClassID(kAudioStreamClassID), element: AudioObjectID(0), "Owned objects")) ?? []
            if let index = inputs.firstIndex(where: { owned.contains($0.objectID) }) {
                byOwnership = index
                break
            }
        }
        // 2. Position.
        var byPosition: Int?
        let h = hardwareInputs.count
        if inputs.count == h + 1, Int(inputs[h].format.mChannelsPerFrame) == tapChannels {
            byPosition = h
        }
        // 3. Fallback.
        let byChannels = inputs.lastIndex { Int($0.format.mChannelsPerFrame) == tapChannels }

        let tapIndex: Int
        let method: String
        if let byOwnership {
            tapIndex = byOwnership
            method = "ownership (position check: \(byPosition.map(String.init) ?? "n/a"))"
        } else if let byPosition {
            tapIndex = byPosition
            method = "position after \(h) hardware input stream(s)"
        } else if let byChannels {
            tapIndex = byChannels
            method = "FALLBACK last \(tapChannels)-channel stream"
            Log.engine.error("Tap stream identified only by channel count; check the stream list above")
        } else {
            throw EngineError("Stream del tap non trovato nel dispositivo aggregato (\(inputs.count) stream di ingresso)")
        }
        if let byOwnership, let byPosition, byOwnership != byPosition {
            Log.engine.error("Tap stream: ownership says \(byOwnership), position says \(byPosition); using ownership")
        }
        Log.engine.info("Tap stream = input stream \(tapIndex), identified by \(method, privacy: .public)")

        // Formats: we only handle Float32 linear PCM.
        guard inputs[tapIndex].format.isFloat32 else {
            throw EngineError("Formato del tap non supportato: \(inputs[tapIndex].format.logDescription)")
        }
        if let bad = outputs.first(where: { !$0.format.isFloat32 }) {
            throw EngineError("Formato di uscita non supportato: \(bad.format.logDescription)")
        }
        guard !outputs.isEmpty else { throw EngineError("Il dispositivo aggregato non ha uscite") }

        // Buffer layouts, cross-checked with what the HAL will hand the IOProc.
        let inputLayout = BufferListLayout(streams: inputs.map(\.formatInfo))
        let outputLayout = BufferListLayout(streams: outputs.map(\.formatInfo))
        let reportedIn = try AudioObject.bufferChannelCounts(aggregate.objectID, scope: kAudioObjectPropertyScopeInput)
        let reportedOut = try AudioObject.bufferChannelCounts(aggregate.objectID, scope: kAudioObjectPropertyScopeOutput)
        guard inputLayout.matches(reportedBufferChannelCounts: reportedIn),
            outputLayout.matches(reportedBufferChannelCounts: reportedOut)
        else {
            throw EngineError(
                "Disposizione buffer inattesa: ingresso \(reportedIn) vs \(inputLayout.bufferChannelCounts), "
                    + "uscita \(reportedOut) vs \(outputLayout.bufferChannelCounts)")
        }

        return AggregateLayout(
            inputStreams: inputs, outputStreams: outputs, inputLayout: inputLayout, outputLayout: outputLayout,
            tapStreamIndex: tapIndex, identificationMethod: method)
    }
}
