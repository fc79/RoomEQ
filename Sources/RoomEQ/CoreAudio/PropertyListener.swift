// A registered Core Audio property listener that can be removed later.

import CoreAudio
import Foundation
import RoomEQCore

/// Registers `handler` for changes of `address` on `object`. The handler runs
/// on `queue`. Call `remove()` to unregister (also done on deinit).
final class PropertyListener {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var registered = false

    init(
        object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
        handler: @escaping () -> Void
    ) throws {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        var address = address
        try AudioObject.check(
            AudioObjectAddPropertyListenerBlock(object, &address, queue, block),
            "Registrazione listener '\(fourCharCodeString(address.mSelector) ?? "?")'")
        registered = true
    }

    func remove() {
        guard registered else { return }
        registered = false
        var address = address
        let status = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        if status != noErr {
            // Expected when the object is already gone (e.g. device unplugged).
            Log.engine.debug(
                "Removing listener \(fourCharCodeString(self.address.mSelector) ?? "?", privacy: .public) on \(self.object): \(describeOSStatus(status), privacy: .public)"
            )
        }
    }

    deinit { remove() }
}

/// A listener registered with a plain C callback (`AudioObjectAddPropertyListener`).
///
/// For notifications Core Audio delivers SYNCHRONOUSLY from the IO thread
/// (kAudioDeviceProcessorOverload, kAudioDevicePropertyDeviceIsRunning, see
/// AudioHardware.h): a block listener would make the IO thread wait for our
/// dispatch queue. The C callback runs inline instead, so it must be
/// real-time safe (no allocation, locks, ARC, logging): ours only increments
/// an atomic counter. `clientData` must stay valid until `remove()` returns.
final class RealtimeListener {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    private let proc: AudioObjectPropertyListenerProc
    private let clientData: UnsafeMutableRawPointer
    private var registered = false

    init(
        object: AudioObjectID, address: AudioObjectPropertyAddress,
        proc: AudioObjectPropertyListenerProc, clientData: UnsafeMutableRawPointer
    ) throws {
        self.object = object
        self.address = address
        self.proc = proc
        self.clientData = clientData
        var address = address
        try AudioObject.check(
            AudioObjectAddPropertyListener(object, &address, proc, clientData),
            "Registrazione listener RT '\(fourCharCodeString(address.mSelector) ?? "?")'")
        registered = true
    }

    func remove() {
        guard registered else { return }
        registered = false
        var address = address
        let status = AudioObjectRemovePropertyListener(object, &address, proc, clientData)
        if status != noErr {
            Log.engine.debug(
                "Removing RT listener on \(self.object): \(describeOSStatus(status), privacy: .public)")
        }
    }

    deinit { remove() }
}
