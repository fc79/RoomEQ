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
