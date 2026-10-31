// Capture-side aggregate device and device property helpers.
//
// Split engine: the capture aggregate is a PRIVATE aggregate that contains
// ONLY the process tap (no sub-devices, drift compensation off). The tapped
// device is never a sub-device of any aggregate, which avoids the HAL error
// "IOContext ... is already registered" (device tap + same device as
// sub-device in one aggregate). Measured: such an aggregate runs on the
// tapped device's clock and sample timeline (drift ~0 ppm, offset 0).
//
// The aggregate and the tap are private ("not persistent across launches"
// per the header): only this process can see them, and we rely on the HAL
// (coreaudiod) destroying them when the process exits — including a crash or
// kill -9, where none of our clean-up code runs (the tapped apps are then
// unmuted, and our IOProc on the output device dies with the process).
// Verify in the live test: kill -9 RoomEQ while running -> apps audible again.

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

    /// Restricts which INPUT streams `ioProc` receives on `device`
    /// (`kAudioDevicePropertyIOProcStreamUsage`).
    static func setInputStreamUsage(device objectID: AudioObjectID, ioProc: AudioDeviceIOProcID, enabled: [Bool]) throws {
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

    /// `kAudioStreamPropertyLatency` in frames; 0 (with a warning) if unreadable.
    static func latency(ofStream stream: AudioStreamID) -> Int {
        do {
            return Int(
                try AudioObject.read(
                    stream, AudioObject.address(kAudioStreamPropertyLatency), initial: UInt32(0), "Latenza stream"))
        } catch {
            Log.engine.warning("Latency of stream \(stream) unreadable, using 0: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

/// IO properties shared by the capture aggregate and the output device.
enum DeviceIO {
    static func bufferFrameSize(_ device: AudioObjectID) throws -> Int {
        Int(
            try AudioObject.read(
                device, AudioObject.address(kAudioDevicePropertyBufferFrameSize), initial: UInt32(0),
                "Lettura dimensione buffer"))
    }

    static func bufferFrameSizeRange(_ device: AudioObjectID) throws -> ClosedRange<Int> {
        let range = try AudioObject.read(
            device, AudioObject.address(kAudioDevicePropertyBufferFrameSizeRange), initial: AudioValueRange(),
            "Lettura intervallo dimensione buffer")
        let low = Int(range.mMinimum.rounded(.up))
        let high = max(low, Int(range.mMaximum.rounded(.down)))
        return low...high
    }

    /// Per-process IO buffer size (the HAL runs the device at the smallest
    /// size requested by its clients).
    static func setBufferFrameSize(_ device: AudioObjectID, _ frames: Int) throws {
        try AudioObject.write(
            device, AudioObject.address(kAudioDevicePropertyBufferFrameSize), value: UInt32(frames),
            "Impostazione dimensione buffer")
    }

    /// `kAudioDevicePropertyUsesVariableBufferFrameSizes`: the largest block
    /// the device may pass when its block sizes vary (nil if not reported).
    static func variableBufferFrameSize(_ device: AudioObjectID) -> Int? {
        let address = AudioObject.address(kAudioDevicePropertyUsesVariableBufferFrameSizes)
        guard AudioObject.has(device, address),
            let frames: UInt32 = try? AudioObject.read(device, address, initial: UInt32(0), "Buffer variabile"),
            frames > 0
        else { return nil }
        return Int(frames)
    }

    /// `kAudioDevicePropertyLatency` in frames; 0 (with a warning) if unreadable.
    static func latency(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        frames(device, kAudioDevicePropertyLatency, scope, "device latency")
    }

    /// `kAudioDevicePropertySafetyOffset` in frames; 0 (with a warning) if unreadable.
    static func safetyOffset(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        frames(device, kAudioDevicePropertySafetyOffset, scope, "safety offset")
    }

    private static func frames(
        _ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
        _ name: String
    ) -> Int {
        do {
            return Int(try AudioObject.read(device, AudioObject.address(selector, scope), initial: UInt32(0), name))
        } catch {
            Log.engine.warning("Device \(device) \(name, privacy: .public) unreadable, using 0: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

/// An owned private capture aggregate (tap only). Call `destroy()` when done.
final class AggregateDevice {
    static let deviceName = "RoomEQ Capture"

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

    /// Private aggregate containing ONLY `tapUID`, drift compensation off
    /// (no resampling), no sub-devices.
    static func createCapture(tapUID: String) throws -> AggregateDevice {
        let uid = "\(AudioDevices.ownAggregateUIDPrefix).capture.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: deviceName,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            // Start returns immediately; the tap delivers silence until apps play.
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 0]
            ],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try AudioObject.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "Creazione dell'aggregato di cattura")
        Log.engine.info("Capture aggregate \(id) created (tap only, drift compensation off)")
        return AggregateDevice(objectID: id, uid: uid)
    }

    /// Active sub-devices; must stay empty (checked at start).
    func activeSubDeviceIDs() -> [AudioObjectID] {
        (try? AudioObject.readArray(
            objectID, AudioObject.address(kAudioAggregateDevicePropertyActiveSubDeviceList),
            element: AudioObjectID(kAudioObjectUnknown), "Sub-device attivi")) ?? []
    }

    func nominalSampleRate() throws -> Double { try AudioDevices.nominalSampleRate(of: objectID) }

    func subTapIDs() -> [AudioObjectID] {
        (try? AudioObject.readArray(
            objectID, AudioObject.address(kAudioAggregateDevicePropertySubTapList),
            element: AudioObjectID(kAudioObjectUnknown), "Lettura sub-tap")) ?? []
    }

    /// Sum of `kAudioSubTapPropertyExtraLatency` (Float64 frames). Read once
    /// per session; '!obj' (not implemented) is expected and logged at debug.
    func subTapExtraLatency() -> Int {
        var total = 0.0
        for subTap in subTapIDs() {
            do {
                total += try AudioObject.read(
                    subTap, AudioObject.address(kAudioSubTapPropertyExtraLatency), initial: Float64(0),
                    "Latenza extra sub-tap")
            } catch {
                Log.engine.debug("Sub-tap \(subTap) extra latency unavailable, using 0: \(error.localizedDescription, privacy: .public)")
            }
        }
        return Int(total.rounded())
    }

    /// Waits (monotonic clock, max `timeout`) until the aggregate exposes
    /// exactly one input stream (the tap) with `channels` channels. Blocks:
    /// engine queue only.
    func waitForTapStream(channels: Int, timeout: Duration = .seconds(3)) throws -> StreamInfo {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var last: [StreamInfo] = []
        while clock.now < deadline {
            last = (try? DeviceStreams.streams(of: objectID, scope: kAudioObjectPropertyScopeInput)) ?? []
            if last.count == 1, Int(last[0].format.mChannelsPerFrame) == channels { return last[0] }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw EngineError(
            "Lo stream del tap non è comparso nell'aggregato di cattura (\(last.count) stream, "
                + "attesi 1 con \(channels) canali)")
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        let status = AudioHardwareDestroyAggregateDevice(objectID)
        if status == noErr {
            Log.engine.info("Capture aggregate \(self.objectID) destroyed")
        } else {
            Log.engine.error(
                "Destroying aggregate \(self.objectID) failed: \(describeOSStatus(status), privacy: .public)")
        }
    }
}
