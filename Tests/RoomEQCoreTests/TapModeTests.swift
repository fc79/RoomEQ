import CoreAudio
import Testing
@testable import RoomEQCore

@Suite("Tap mode helpers")
struct TapModeTests {
    @Test func defaultsAndLabels() {
        #expect(TapMode.defaultMode == .device)
        #expect(TapMode(rawValue: "global") == .global)
        #expect(TapMode.allCases.map(\.displayName) == ["Dispositivo", "Globale"])
    }

    @Test func stereoPairSelection() {
        #expect(TapChannelSelection.stereoPair(tapChannels: 1, preferredStereo: nil) == (0, 0))
        #expect(TapChannelSelection.stereoPair(tapChannels: 2, preferredStereo: (3, 4)) == (0, 1))
        // Device tap with the Quantum's 10 channels: use the preferred stereo pair.
        #expect(TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (1, 2)) == (0, 1))
        #expect(TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (3, 4)) == (2, 3))
        // Invalid preferences fall back to 1-2.
        #expect(TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (11, 12)) == (0, 1))
        #expect(TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (2, 2)) == (0, 1))
        #expect(TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: nil) == (0, 1))
    }

    @Test func formatText() {
        #expect(AudioFormatText.summary(sampleRate: 44100, channels: 2) == "44,1 kHz · 2 ch")
        #expect(AudioFormatText.kilohertz(48000) == "48 kHz")
        #expect(AudioFormatText.kilohertz(88200) == "88,2 kHz")
        #expect(AudioFormatText.kilohertz(96000) == "96 kHz")
    }

    /// A device tap that kept the device's 10-channel layout: the render
    /// kernel must take channels 3/4 (preferred stereo) and route them to
    /// the chosen output pair, silencing everything else.
    @Test func tenChannelDeviceTapIsRoutedFromPreferredPair() {
        let frames = 8
        let inputLayout = BufferListLayout(streams: [
            StreamFormatInfo(channels: 18, isInterleaved: true),  // hardware inputs (disabled)
            StreamFormatInfo(channels: 10, isInterleaved: true),  // device tap
        ])
        let tapChannels = inputLayout.locations(ofStream: 1)
        let pair = TapChannelSelection.stereoPair(tapChannels: 10, preferredStereo: (3, 4))
        let outputLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 10, isInterleaved: true)])
        let config = RenderConfiguration(
            inputLayout: inputLayout, tapLeft: tapChannels[pair.left], tapRight: tapChannels[pair.right],
            outputLayout: outputLayout, sampleRate: 44100)
        let handle = RenderStateHandle(
            configuration: config, gain: 1, bypass: false, outputPair: OutputChannelPair(left: 0))

        let input = TestBufferList(channelCounts: [18, 10], frames: frames, hasData: [false, true])
        for frame in 0..<frames {
            for channel in 0..<10 { input.set(buffer: 1, channel: channel, frame: frame, 0.9) }  // noise elsewhere
            input.set(buffer: 1, channel: 2, frame: frame, 0.25)
            input.set(buffer: 1, channel: 3, frame: frame, -0.5)
        }
        let output = TestBufferList(channelCounts: [10], frames: frames, fill: 0.7)
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)

        #expect(output.get(buffer: 0, channel: 0, frame: 4) == 0.25)
        #expect(output.get(buffer: 0, channel: 1, frame: 4) == -0.5)
        for channel in 2..<10 { #expect(output.get(buffer: 0, channel: channel, frame: 4) == 0) }
    }

    @Test func diagnosticPeaksAreIndependentOfUIMeters() {
        let inputLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 2, isInterleaved: true)])
        let taps = inputLayout.locations(ofStream: 0)
        let outputLayout = BufferListLayout(streams: [StreamFormatInfo(channels: 2, isInterleaved: true)])
        let config = RenderConfiguration(
            inputLayout: inputLayout, tapLeft: taps[0], tapRight: taps[1], outputLayout: outputLayout,
            sampleRate: 44100)
        let handle = RenderStateHandle(configuration: config, gain: 0.5, bypass: false, outputPair: .firstPair)
        let input = TestBufferList(channelCounts: [2], frames: 4, fill: 0.8)
        let output = TestBufferList(channelCounts: [2], frames: 4)
        RenderKernel.render(state: handle.pointer, input: UnsafePointer(input.pointer), output: output.pointer)

        _ = handle.readMeters()  // the UI reads (and resets) its peaks first
        let diagnostic = handle.readDiagnosticPeaks()
        #expect(abs(diagnostic.input - 0.8) < 1e-6)
        #expect(abs(diagnostic.output - 0.4) < 1e-6)
        #expect(handle.readDiagnosticPeaks().input == 0)
    }
}
