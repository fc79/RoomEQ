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
    /// Nominal sample rate when the info was read (nil if unreadable).
    let nominalSampleRate: Double?
    /// `kAudioDevicePropertyTransportType` (0 if unknown).
    let transportType: UInt32

    var id: String { uid }
    /// "USB", "Bluetooth", "Integrato"…
    var transportName: String { TransportType.name(transportType) }
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
            inputChannelCount: AudioObject.channelCount(device, scope: kAudioObjectPropertyScopeInput),
            nominalSampleRate: (try? nominalSampleRate(of: device)).flatMap { $0 > 0 && $0.isFinite ? $0 : nil },
            transportType: transportType(of: device))
    }

    /// All devices with at least one output channel, excluding aggregate
    /// devices (RoomEQ's own and any other: an aggregate is a combination of
    /// devices, not an output to choose).
    static func outputDevices() -> [OutputDeviceInfo] {
        let ids = (try? allDeviceIDs()) ?? []
        return ids.compactMap(info(for:)).filter {
            $0.outputChannelCount > 0 && !$0.uid.hasPrefix(ownAggregateUIDPrefix)
                && !TransportType.isAggregate($0.transportType)
        }
    }

    static func transportType(of device: AudioObjectID) -> UInt32 {
        (try? AudioObject.read(
            device, AudioObject.address(kAudioDevicePropertyTransportType), initial: UInt32(0), "Tipo di collegamento"))
            ?? 0
    }

    /// Rates offered for `device` (`kAudioDevicePropertyAvailableNominalSampleRates`,
    /// ranges expanded to the standard rates inside them).
    static func availableSampleRates(of device: AudioObjectID) -> [Double] {
        let ranges = (try? AudioObject.readArray(
            device, AudioObject.address(kAudioDevicePropertyAvailableNominalSampleRates),
            element: AudioValueRange(mMinimum: 0, mMaximum: 0), "Frequenze disponibili")) ?? []
        return SampleRates.expand(ranges.map { ($0.mMinimum, $0.mMaximum) })
    }

    static func setNominalSampleRate(_ rate: Double, of device: AudioObjectID) throws {
        try AudioObject.write(
            device, AudioObject.address(kAudioDevicePropertyNominalSampleRate), value: Float64(rate),
            "Impostazione della frequenza di campionamento")
    }

    /// The device used for alerts and sound effects.
    static func defaultSystemOutputDeviceID() -> AudioObjectID? {
        let id: AudioObjectID? = try? AudioObject.read(
            AudioObjectID(kAudioObjectSystemObject),
            AudioObject.address(kAudioHardwarePropertyDefaultSystemOutputDevice),
            initial: AudioObjectID(kAudioObjectUnknown), "Lettura uscita effetti sonori")
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Makes `device` the macOS default output. The alert/sound-effects
    /// output is moved too ONLY if it was the same device as the default
    /// output before (i.e. the user never separated them in System
    /// Settings); otherwise it stays where the user put it.
    static func setDefaultOutputDevice(_ device: AudioObjectID) throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let previousDefault = defaultOutputDeviceID()
        let previousSystem = defaultSystemOutputDeviceID()
        try AudioObject.write(
            system, AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice), value: device,
            "Impostazione dell'uscita di macOS")
        if let previousDefault, previousSystem == previousDefault, previousDefault != device {
            do {
                try AudioObject.write(
                    system, AudioObject.address(kAudioHardwarePropertyDefaultSystemOutputDevice), value: device,
                    "Impostazione dell'uscita effetti sonori")
            } catch {
                Log.devices.warning("Sound-effects output not moved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        let id: AudioObjectID? = try? AudioObject.read(
            AudioObjectID(kAudioObjectSystemObject),
            AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice),
            initial: AudioObjectID(kAudioObjectUnknown), "Lettura uscita predefinita")
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
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

}
