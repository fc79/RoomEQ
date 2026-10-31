// The "Uscita" section: macOS output device, channel pair, sound-card sample
// rate and buffer size.
//
// Changing the output device changes the macOS default output (RoomEQ
// follows it). Changing the sample rate changes it for EVERY app using the
// card, so it is confirmed first.

import RoomEQCore
import SwiftUI

struct OutputSectionView: View {
    let controller: AudioEngineController

    /// A sample rate waiting for the user's confirmation.
    @State private var pendingRate: Double?

    private var isBusy: Bool { controller.isChangingOutputDevice || controller.isChangingSampleRate }

    var body: some View {
        PanelSection(title: "Uscita") {
            devicePicker
            channelsPicker
            sampleRatePicker
            bufferPicker
        }
        .alert(
            pendingRate.map { "Cambiare la frequenza della scheda a \(Format.sampleRate($0))?" } ?? "",
            isPresented: Binding(get: { pendingRate != nil }, set: { if !$0 { pendingRate = nil } }),
            presenting: pendingRate
        ) { rate in
            Button("Cambia") { controller.setDeviceSampleRate(rate) }
            Button("Annulla", role: .cancel) {}
        } message: { _ in
            Text(
                "Vale per tutte le app, compreso Ableton."
                    + (controller.isRunning ? " RoomEQ si riavvia per un istante." : ""))
        }
    }

    // MARK: Device

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Uscita audio").font(.callout)
                Spacer()
                if controller.isChangingOutputDevice { ProgressView().controlSize(.small) }
            }
            Picker(
                "Uscita audio",
                selection: Binding<String?>(
                    get: { controller.outputDeviceOptions.first { $0.isDefault }?.uid },
                    set: { if let uid = $0 { controller.setSystemOutputDevice(uid: uid) } })
            ) {
                ForEach(controller.outputDeviceOptions) { option in
                    Text(Self.title(of: option)).tag(Optional(option.uid))
                }
            }
            .labelsHidden()
            .disabled(isBusy || controller.outputDeviceOptions.isEmpty)
            Text("Cambia l'uscita audio di macOS")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// "Scarlett 2i2 (USB · 48 kHz)".
    private static func title(of option: OutputDeviceOption) -> String {
        var details = [option.transportName]
        if let rate = option.nominalSampleRate { details.append(Format.sampleRate(rate)) }
        details.removeAll { $0.isEmpty }
        return details.isEmpty ? option.name : "\(option.name) (\(details.joined(separator: " · ")))"
    }

    // MARK: Channels

    private var channelsPicker: some View {
        HStack {
            Text("Canali").font(.callout)
            Spacer()
            Picker(
                "Canali",
                selection: Binding(
                    get: { controller.outputChannelPair },
                    set: { controller.setOutputChannelPair($0) })
            ) {
                ForEach(controller.availableChannelPairs) { pair in
                    Text("Canali \(pair.description)").tag(pair)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(controller.availableChannelPairs.count < 2)
        }
    }

    // MARK: Sample rate

    private var sampleRatePicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Frequenza scheda").font(.callout)
                Spacer()
                if controller.isChangingSampleRate { ProgressView().controlSize(.small) }
                Picker(
                    "Frequenza scheda",
                    selection: Binding<Double?>(
                        get: { currentRate },
                        set: { if let rate = $0, rate != currentRate { pendingRate = rate } })
                ) {
                    if currentRate == nil { Text("—").tag(Double?.none) }
                    ForEach(controller.availableSampleRates, id: \.self) { rate in
                        Text(Format.sampleRate(rate)).tag(Optional(rate))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(isBusy || controller.availableSampleRates.isEmpty)
            }
            Text("Vale per tutte le app che usano questa scheda")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// The current rate as one of the offered values (nil when unknown).
    private var currentRate: Double? {
        guard let rate = controller.currentSampleRate else { return nil }
        return controller.availableSampleRates.first { abs($0 - rate) < 0.5 }
    }

    // MARK: Buffer

    private var bufferPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Buffer (frame)").font(.callout)
            Picker(
                "Buffer",
                selection: Binding(
                    get: { controller.bufferSize },
                    set: { controller.setBufferSize($0) })
            ) {
                ForEach(controller.bufferSizeOptions, id: \.self) { frames in
                    Text(String(frames)).tag(frames)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}
