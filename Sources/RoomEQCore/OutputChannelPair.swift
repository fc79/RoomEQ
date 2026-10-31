// A stereo pair of adjacent device output channels (1–2, 3–4, ...).

/// A pair of adjacent output channels. `left` is the 0-based index of the
/// left channel; the right channel is always `left + 1`.
public struct OutputChannelPair: Hashable, Sendable, Identifiable, CustomStringConvertible {
    /// 0-based index of the left channel (always even).
    public let left: Int

    /// 0-based index of the right channel.
    public var right: Int { left + 1 }

    public var id: Int { left }

    /// Channels 1–2 (indices 0 and 1).
    public static let firstPair = OutputChannelPair(left: 0)

    /// Creates the pair starting at the given 0-based channel. Odd values are
    /// rounded down so that pairs are always 1–2, 3–4, ...
    public init(left: Int) {
        self.left = max(0, left - (left % 2))
    }

    /// 1-based label as shown on the interface, e.g. "1–2".
    public var description: String { "\(left + 1)–\(right + 1)" }

    /// All complete pairs available on a device with `channelCount` outputs.
    /// A 10-channel device gives 1–2, 3–4, 5–6, 7–8, 9–10. A trailing odd
    /// channel is not offered.
    public static func available(forChannelCount channelCount: Int) -> [OutputChannelPair] {
        guard channelCount >= 2 else { return [] }
        return stride(from: 0, to: channelCount - 1, by: 2).map { OutputChannelPair(left: $0) }
    }

    /// Packs the pair into one 32-bit value so it can be published to the
    /// real-time thread with a single atomic store (left and right always
    /// change together).
    public var packed: UInt32 { UInt32(left) | (UInt32(right) << 16) }

    /// Inverse of `packed`: returns (left, right).
    @inline(__always)
    public static func unpack(_ value: UInt32) -> (left: Int, right: Int) {
        (Int(value & 0xFFFF), Int(value >> 16))
    }
}
