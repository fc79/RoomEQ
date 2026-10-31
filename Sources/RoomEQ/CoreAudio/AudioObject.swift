// Thin, checked wrappers around the Core Audio property C API.
//
// Every call checks its OSStatus and throws `CoreAudioError`, whose message
// names the operation and shows the four-character error code.
// NOT for use on the real-time thread (these allocate and may block).

import CoreAudio
import Foundation
import os
import RoomEQCore

/// Loggers for `log stream --predicate 'subsystem == "com.federicociapi.RoomEQ"'`.
enum Log {
    static let subsystem = "com.federicociapi.RoomEQ"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let tap = Logger(subsystem: subsystem, category: "tap")
    static let devices = Logger(subsystem: subsystem, category: "devices")
}

/// A failed Core Audio call.
struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation) non riuscito: errore Core Audio \(describeOSStatus(status))"
    }
}

/// A logical engine error (not a Core Audio status).
struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AudioObject {
    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    /// Reads a fixed-size (plain C) value.
    static func read<T>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T, _ operation: String
    ) throws -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, operation)
        return value
    }

    /// Reads a fixed-size value with a qualifier (e.g. PID -> process object).
    static func read<T, Q>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, qualifier: Q, initial: T, _ operation: String
    ) throws -> T {
        var address = address
        var value = initial
        var qualifier = qualifier
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(
                    object, &address, UInt32(MemoryLayout<Q>.size), qualifierPointer, &size, $0)
            }
        }
        try check(status, operation)
        return value
    }

    /// Reads an array of fixed-size values (e.g. a list of AudioObjectIDs).
    static func readArray<T>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, element: T, _ operation: String
    ) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), operation)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: element, count: count)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, operation)
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads an array with a qualifier (e.g. owned objects filtered by class).
    static func readArray<T, Q>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, qualifier: Q, element: T, _ operation: String
    ) throws -> [T] {
        var address = address
        var qualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size)
        var size: UInt32 = 0
        try withUnsafeMutablePointer(to: &qualifier) { q in
            try check(AudioObjectGetPropertyDataSize(object, &address, qualifierSize, q, &size), operation)
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: element, count: count)
        let status = withUnsafeMutablePointer(to: &qualifier) { q in
            values.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(object, &address, qualifierSize, q, &size, $0.baseAddress!)
            }
        }
        try check(status, operation)
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads a CFString property. Core Audio returns these retained (+1):
    /// "The caller is responsible for releasing the returned CFObject."
    static func readString(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ operation: String
    ) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, operation)
        guard let value else { throw EngineError("\(operation): valore mancante") }
        return value.takeRetainedValue() as String
    }

    /// Writes a fixed-size value.
    static func write<T>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, value: T, _ operation: String
    ) throws {
        var address = address
        var value = value
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        try check(status, operation)
    }

    /// Per-buffer channel counts from `kAudioDevicePropertyStreamConfiguration`
    /// — exactly the shape of the AudioBufferList the IOProc will receive.
    static func bufferChannelCounts(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "Lettura configurazione stream")
        guard size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "Lettura configurazione stream")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Total channels of a device in one direction.
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        (try? bufferChannelCounts(device, scope: scope).reduce(0, +)) ?? 0
    }
}

extension AudioStreamBasicDescription {
    var isFloat32: Bool {
        mFormatID == kAudioFormatLinearPCM
            && (mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && mBitsPerChannel == 32
    }

    var isNonInterleaved: Bool { (mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 }

    var logDescription: String {
        let id = fourCharCodeString(mFormatID) ?? "\(mFormatID)"
        return "\(id) \(mSampleRate) Hz, \(mChannelsPerFrame) ch, \(mBitsPerChannel) bit, "
            + "flags 0x\(String(mFormatFlags, radix: 16)), "
            + (isNonInterleaved ? "non-interleaved" : "interleaved")
    }
}
