// Enumeration of audio devices.

import CoreAudio
import Foundation
import RoomEQCore

/// An output-capable audio device, as shown in the device picker.
struct OutputDeviceInfo: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let outputChannelCount: Int
    let inputChannelCount: Int

    var id: String { uid }
}

enum AudioDevices {
    /// UID prefix of the private aggregate devices RoomEQ creates. Used to hide
    /// them from the device list and to find leftovers.
    static let ownAggregateUIDPrefix = "com.federicociapi.RoomEQ.aggregate"

    static func allDeviceIDs() throws -> [AudioObjectID] {
        try AudioObject.readArray(
            AudioObjectID(kAudioObjectSystemObject), AudioObject.address(kAudioHardwarePropertyDevices),
            element: AudioObjectID(kAudioObjectUnknown), "Lettura elenco dispositivi")
    }

    static func uid(of device: AudioObjectID) -> String? {
        try? AudioObject.readString(device, AudioObject.address(kAudioDevicePropertyDeviceUID), "Lettura UID")
    }

    static func name(of device: AudioObjectID) -> String {
        (try? AudioObject.readString(device, AudioObject.address(kAudioObjectPropertyName), "Lettura nome"))
            ?? "Dispositivo \(device)"
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        let alive: UInt32 =
            (try? AudioObject.read(
                device, AudioObject.address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0), "IsAlive"))
            ?? 0
        return alive != 0
    }

    static func nominalSampleRate(of device: AudioObjectID) throws -> Double {
        try AudioObject.read(
            device, AudioObject.address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0),
            "Lettura frequenza di campionamento")
    }

    /// The device with the given UID, if currently present.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        (try? allDeviceIDs())?.first { self.uid(of: $0) == uid }
    }

    static func info(for device: AudioObjectID) -> OutputDeviceInfo? {
        guard let uid = uid(of: device) else { return nil }
        return OutputDeviceInfo(
            objectID: device,
            uid: uid,
            name: name(of: device),
            outputChannelCount: AudioObject.channelCount(device, scope: kAudioObjectPropertyScopeOutput),
            inputChannelCount: AudioObject.channelCount(device, scope: kAudioObjectPropertyScopeInput))
    }

    /// All devices with at least one output channel, excluding RoomEQ's own
    /// aggregate devices.
    static func outputDevices() -> [OutputDeviceInfo] {
        let ids = (try? allDeviceIDs()) ?? []
        return ids.compactMap(info(for:))
            .filter { $0.outputChannelCount > 0 && !$0.uid.hasPrefix(ownAggregateUIDPrefix) }
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        let id: AudioObjectID? = try? AudioObject.read(
            AudioObjectID(kAudioObjectSystemObject),
            AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice),
            initial: AudioObjectID(kAudioObjectUnknown), "Lettura uscita predefinita")
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// `kAudioDevicePropertyTransportType` (e.g. built-in, USB, aggregate, virtual).
    static func transportType(of device: AudioObjectID) -> UInt32 {
        (try? AudioObject.read(
            device, AudioObject.address(kAudioDevicePropertyTransportType), initial: UInt32(0), "Tipo trasporto")) ?? 0
    }

    /// Output-capable physical devices: no aggregates (ours or others), no
    /// virtual devices.
    static func physicalOutputDevices() -> [OutputDeviceInfo] {
        outputDevices().filter {
            let transport = transportType(of: $0.objectID)
            return transport != kAudioDeviceTransportTypeAggregate
                && transport != kAudioDeviceTransportTypeAutoAggregate
                && transport != kAudioDeviceTransportTypeVirtual
        }
    }

    /// `kAudioDevicePropertyActualSampleRate` (measured), 0 if unavailable.
    static func actualSampleRate(of device: AudioObjectID) -> Double {
        (try? AudioObject.read(
            device, AudioObject.address(kAudioDevicePropertyActualSampleRate), initial: Float64(0),
            "Frequenza effettiva")) ?? 0
    }

    /// UID of the system default output device (where apps play).
    static func defaultOutputDeviceUID() -> String? {
        defaultOutputDeviceID().flatMap(uid(of:))
    }

    /// `kAudioDevicePropertyPreferredChannelsForStereo` (1-based channel
    /// numbers), or nil if the device doesn't report it.
    static func preferredStereoChannels(of device: AudioObjectID) -> (Int, Int)? {
        let pair: (UInt32, UInt32)? = try? AudioObject.read(
            device,
            AudioObject.address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput),
            initial: (UInt32(0), UInt32(0)), "Canali stereo preferiti")
        guard let pair, pair.0 > 0, pair.1 > 0 else { return nil }
        return (Int(pair.0), Int(pair.1))
    }

    /// Automatic choice: the first device whose name contains "Quantum",
    /// otherwise the system default output, otherwise the first device.
    /// (Pure: pass `defaultOutputDeviceID()` read on a background queue.)
    static func preferredOutputDevice(in devices: [OutputDeviceInfo], defaultOutputID: AudioObjectID?)
        -> OutputDeviceInfo?
    {
        if let quantum = devices.first(where: { $0.name.localizedCaseInsensitiveContains("Quantum") }) {
            return quantum
        }
        if let defaultOutputID, let device = devices.first(where: { $0.objectID == defaultOutputID }) {
            return device
        }
        return devices.first
    }
}
