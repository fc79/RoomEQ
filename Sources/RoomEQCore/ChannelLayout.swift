// Mapping between device channels and the AudioBufferList passed to an IOProc.
//
// A Core Audio device has one or more *streams*; each stream has N channels.
// In the AudioBufferList handed to a HAL IOProc:
//   - an interleaved stream contributes ONE AudioBuffer with N channels
//     (samples ordered L R L R ...);
//   - a non-interleaved stream contributes N AudioBuffers with 1 channel each.
// Buffers appear in stream order. Device channels are numbered across all
// streams in that same order (channel 0 = first channel of the first stream).
//
// `BufferListLayout` turns a list of stream formats into "where is channel k?"
// answers, so the real-time code only does table look-ups.

/// Channel count and interleaving of one device stream.
public struct StreamFormatInfo: Sendable, Equatable {
    public var channels: Int
    public var isInterleaved: Bool

    public init(channels: Int, isInterleaved: Bool) {
        self.channels = channels
        self.isInterleaved = isInterleaved
    }
}

/// Where a single channel lives inside an AudioBufferList.
public struct ChannelLocation: Sendable, Equatable {
    /// Index of the AudioBuffer in the list.
    public var buffer: Int
    /// Index of the channel inside that (interleaved) buffer.
    public var offset: Int
    /// Number of interleaved channels in that buffer (= distance between two
    /// consecutive samples of this channel).
    public var stride: Int
    /// Index of the device stream the channel belongs to.
    public var stream: Int

    public init(buffer: Int, offset: Int, stride: Int, stream: Int) {
        self.buffer = buffer
        self.offset = offset
        self.stride = stride
        self.stream = stream
    }
}

/// The buffer layout produced by a list of streams.
public struct BufferListLayout: Sendable, Equatable {
    /// Channels per AudioBuffer, in buffer order.
    public let bufferChannelCounts: [Int]
    /// For each stream, the index of its first AudioBuffer.
    public let firstBufferOfStream: [Int]
    /// Location of every device channel, in device channel order.
    public let channels: [ChannelLocation]

    public init(streams: [StreamFormatInfo]) {
        var counts: [Int] = []
        var firstBuffer: [Int] = []
        var locations: [ChannelLocation] = []
        for (streamIndex, stream) in streams.enumerated() {
            firstBuffer.append(counts.count)
            guard stream.channels > 0 else { continue }
            if stream.isInterleaved || stream.channels == 1 {
                let buffer = counts.count
                counts.append(stream.channels)
                for offset in 0..<stream.channels {
                    locations.append(
                        ChannelLocation(buffer: buffer, offset: offset, stride: stream.channels, stream: streamIndex))
                }
            } else {
                for _ in 0..<stream.channels {
                    locations.append(ChannelLocation(buffer: counts.count, offset: 0, stride: 1, stream: streamIndex))
                    counts.append(1)
                }
            }
        }
        bufferChannelCounts = counts
        firstBufferOfStream = firstBuffer
        channels = locations
    }

    /// Total number of device channels.
    public var channelCount: Int { channels.count }

    /// Location of device channel `index` (0-based), or nil if out of range.
    public func location(ofChannel index: Int) -> ChannelLocation? {
        channels.indices.contains(index) ? channels[index] : nil
    }

    /// Locations of the channels that belong to stream `streamIndex`.
    public func locations(ofStream streamIndex: Int) -> [ChannelLocation] {
        channels.filter { $0.stream == streamIndex }
    }

    /// True if this computed layout agrees with the buffer layout Core Audio
    /// actually reports (`kAudioDevicePropertyStreamConfiguration`).
    public func matches(reportedBufferChannelCounts reported: [Int]) -> Bool {
        reported == bufferChannelCounts
    }
}
