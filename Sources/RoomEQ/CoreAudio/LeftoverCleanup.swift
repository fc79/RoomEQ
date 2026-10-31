// Defensive clean-up of Core Audio objects left over by a previous run.
//
// ASSUMPTION (documented, not verifiable from the headers alone):
// RoomEQ only ever creates PRIVATE taps and aggregate devices. Private
// objects are visible only to the process that created them and the HAL
// (coreaudiod) tears them down when that process disconnects — normal quit,
// crash or kill -9 alike. So after a crash nothing should be left behind and
// the mute-when-tapped behaviour ends with the process (apps are audible
// again).
//
// This check is therefore a safety net: at start-up it looks for any VISIBLE
// device whose UID starts with our aggregate prefix, or any tap named
// "RoomEQ Tap", and destroys it. Since we haven't created anything yet at
// that point, anything found cannot belong to the running instance. Another
// running RoomEQ instance's objects are private, hence invisible and safe.

import CoreAudio
import Foundation
import RoomEQCore

enum LeftoverCleanup {
    static func run() {
        var found = 0

        for device in (try? AudioDevices.allDeviceIDs()) ?? [] {
            guard let uid = AudioDevices.uid(of: device), uid.hasPrefix(AudioDevices.ownAggregateUIDPrefix) else {
                continue
            }
            found += 1
            let status = AudioHardwareDestroyAggregateDevice(device)
            Log.engine.notice(
                "Leftover aggregate \(uid, privacy: .public) destroyed: \(describeOSStatus(status), privacy: .public)")
        }

        let taps: [AudioObjectID] =
            (try? AudioObject.readArray(
                AudioObjectID(kAudioObjectSystemObject), AudioObject.address(kAudioHardwarePropertyTapList),
                element: AudioObjectID(kAudioObjectUnknown), "Elenco tap")) ?? []
        for tap in taps where tapName(tap) == ProcessTap.tapName {
            found += 1
            let status = AudioHardwareDestroyProcessTap(tap)
            Log.tap.notice("Leftover tap \(tap) destroyed: \(describeOSStatus(status), privacy: .public)")
        }

        Log.engine.info("Leftover check done: \(found) object(s) found (expected 0, see LeftoverCleanup.swift)")
    }

    /// Name from the tap's description. Taken unretained on purpose (ownership
    /// of the returned object isn't documented; a tiny leak beats a crash).
    private static func tapName(_ tap: AudioObjectID) -> String? {
        var address = AudioObject.address(kAudioTapPropertyDescription)
        var value: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeUnretainedValue().name
    }
}
