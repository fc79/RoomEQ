import Testing
@testable import RoomEQCore

@Suite("Channel layout")
struct ChannelLayoutTests {
    @Test func interleavedStreams() {
        // e.g. aggregate input: 18 hardware channels in one stream + stereo tap.
        let layout = BufferListLayout(streams: [
            StreamFormatInfo(channels: 18, isInterleaved: true),
            StreamFormatInfo(channels: 2, isInterleaved: true),
        ])
        #expect(layout.bufferChannelCounts == [18, 2])
        #expect(layout.firstBufferOfStream == [0, 1])
        #expect(layout.channelCount == 20)
        #expect(layout.location(ofChannel: 18) == ChannelLocation(buffer: 1, offset: 0, stride: 2, stream: 1))
        #expect(layout.locations(ofStream: 1).map(\.offset) == [0, 1])
        #expect(layout.matches(reportedBufferChannelCounts: [18, 2]))
        #expect(!layout.matches(reportedBufferChannelCounts: [2, 18]))
    }

    @Test func nonInterleavedStream() {
        let layout = BufferListLayout(streams: [
            StreamFormatInfo(channels: 2, isInterleaved: false),
            StreamFormatInfo(channels: 4, isInterleaved: true),
        ])
        #expect(layout.bufferChannelCounts == [1, 1, 4])
        #expect(layout.firstBufferOfStream == [0, 2])
        #expect(layout.location(ofChannel: 1) == ChannelLocation(buffer: 1, offset: 0, stride: 1, stream: 0))
        #expect(layout.location(ofChannel: 5) == ChannelLocation(buffer: 2, offset: 3, stride: 4, stream: 1))
        #expect(layout.location(ofChannel: 6) == nil)
    }

    @Test func manyMonoStreams() {
        let layout = BufferListLayout(streams: Array(repeating: StreamFormatInfo(channels: 1, isInterleaved: true), count: 10))
        #expect(layout.bufferChannelCounts == Array(repeating: 1, count: 10))
        #expect(layout.location(ofChannel: 9)?.buffer == 9)
    }
}
