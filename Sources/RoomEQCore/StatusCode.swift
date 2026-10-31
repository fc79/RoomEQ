// Human-readable formatting of Core Audio OSStatus codes.
//
// Many Core Audio errors are "four-character codes": 32-bit integers whose
// four bytes are ASCII letters (e.g. 'nope' = kAudioHardwareIllegalOperationError).
// Showing them as text makes error messages searchable and understandable.

/// Returns the four-character representation of `code` (e.g. `"nope"`),
/// or `nil` if its four bytes are not all printable ASCII.
public func fourCharCodeString(_ code: UInt32) -> String? {
    let bytes = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
    return String(decoding: bytes, as: UTF8.self)
}

/// Formats an OSStatus for humans: `'nope' (1852797029)` for four-character
/// codes, or just the number (e.g. `-50`) otherwise.
public func describeOSStatus(_ status: Int32) -> String {
    if let text = fourCharCodeString(UInt32(bitPattern: status)) {
        return "'\(text)' (\(status))"
    }
    return "\(status)"
}
