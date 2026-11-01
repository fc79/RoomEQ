// The "Uscita e scheda" section (collapsible, summary "Quantum LT 16 · 44,1 kHz · buffer 64"):
// macOS output device, channel pair (only on devices with more than 2
// channels), sound-card sample rate and buffer size. Output errors are shown
// here, dismissible.
//
// Changing the output device changes the macOS default output (RoomEQ
// follows it). Changing the sample rate changes it for EVERY app using the
// card, so it is confirmed first (inline card).

import RoomEQCore
import SwiftUI

struct OutputSectionView: View {
    let controller: AudioEngineController

    @Environment(ConfirmationPresenter.self) private var confirmations

    private var isBusy: Bool { controller.isChangingOutputDevice || controller.isChangingSampleRate }

    var body: some View {
        CollapsibleSection(
            title: "Uscita e scheda", summary: summary, hasError: controller.outputError != nil, storageKey: "output") {
            if let error = controller.outputError {
                DismissibleMessage(text: error) { controller.clearOutputError() }
            }
            devicePicker
            if controller.availableChannelPairs.count >= 2 { channelsPicker }
            sampleRatePicker
            bufferPicker
        }
    }

    /// "Quantum LT 16 · 44,1 kHz · buffer 64" (device, sample rate, buffer; parts
    /// that are unknown are left out).
    private var summary: String {
        var parts: [String] = []
        if let name = controller.effectiveOutputDevice?.name { parts.append(name) }
        if let rate = controller.currentSampleRate { parts.append(AudioFormatText.kilohertz(rate)) }
        parts.append("buffer \(controller.bufferSize)")
        return parts.joined(separator: " · ")
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
        }
    }

    /// "Scarlett 2i2 (USB · 48 kHz)".
    private static func title(of option: OutputDeviceOption) -> String {
        var details = [option.transportName]
        if let rate = option.nominalSampleRate { details.append(AudioFormatText.kilohertz(rate)) }
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
                Text("Frequenza di campionamento").font(.callout)
                Spacer()
                if controller.isChangingSampleRate { ProgressView().controlSize(.small) }
                Picker(
                    "Frequenza di campionamento",
                    selection: Binding<Double?>(
                        get: { currentRate },
                        set: { if let rate = $0, rate != currentRate { requestRate(rate) } })
                ) {
                    if currentRate == nil { Text("—").tag(Double?.none) }
                    ForEach(controller.availableSampleRates, id: \.self) { rate in
                        Text(AudioFormatText.kilohertz(rate)).tag(Optional(rate))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(isBusy || controller.availableSampleRates.isEmpty)
            }
            Text("Vale per tutte le app, compreso Ableton.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func requestRate(_ rate: Double) {
        confirmations.present(
            InlineConfirmation(
                title: "Cambiare la frequenza di campionamento a \(AudioFormatText.kilohertz(rate))?",
                message: "Vale per tutte le app, compreso Ableton."
                    + (controller.isRunning ? " RoomEQ si riavvia per un istante." : ""),
                options: [.standard("Cambia") { [controller] in controller.setDeviceSampleRate(rate) }]))
    }

    /// The current rate as one of the offered values (nil when unknown).
    private var currentRate: Double? {
        guard let rate = controller.currentSampleRate else { return nil }
        return controller.availableSampleRates.first { abs($0 - rate) < 0.5 }
    }

    // MARK: Buffer

    private var bufferPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Buffer").font(.callout)
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
