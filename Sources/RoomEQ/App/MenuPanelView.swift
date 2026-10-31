// The menu-bar panel (stage 2 TEST UI: passthrough, no EQ).
//
// Pure view over `AudioEngineController`: it only reads the observable
// properties and calls the controller's methods. Each block is its own
// computed property so blocks can be moved or reused in the final UI.

import AppKit
import RoomEQCore
import SwiftUI

struct MenuPanelView: View {
    let controller: AudioEngineController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            outputSection
            bufferSection
            Divider()
            latencySection
            Divider()
            levelsSection
            Divider()
            exclusionsSection
            Divider()
            diagnosticsSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Header: title, on/off, status

    private var isActive: Bool { controller.isRunning || controller.state == .starting }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RoomEQ").font(.title2.weight(.bold))
                Spacer()
                Toggle(
                    "Attiva RoomEQ",
                    isOn: Binding(get: { isActive }, set: { _ in controller.toggle() })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
                .disabled(controller.state == .stopping)
            }
            Text(controller.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = controller.lastError {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Uscita

    private var outputSection: some View {
        PanelSection(title: "Uscita") {
            // Stage 4 will add a picker that changes the macOS default output.
            Text("Uscita di macOS: \(controller.effectiveOutputDevice?.name ?? "—")")
                .font(.callout)
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
            .disabled(controller.availableChannelPairs.count < 2)
        }
    }

    // MARK: Buffer

    private var bufferSection: some View {
        PanelSection(title: "Buffer (frame)") {
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

    // MARK: Latenza

    private var latencySection: some View {
        PanelSection(title: "Latenza") {
            HStack(alignment: .firstTextBaseline) {
                if controller.isRunning, let latency = controller.latency {
                    Text("\(Format.oneDecimal(latency.totalMilliseconds)) ms")
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                } else {
                    Text("—")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.isRunning, let rate = controller.sampleRate {
                    Text(Format.sampleRate(rate))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if controller.isRunning {
                Text(controller.latencySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Livelli

    private var levelsSection: some View {
        let meters = controller.meters
        let counters = counterLines(for: meters)
        return PanelSection(title: "Livelli") {
            HStack(alignment: .center, spacing: 8) {
                VStack(spacing: 4) {
                    LevelMeterRow(channel: "L", peak: meters.outputPeakLeft)
                    LevelMeterRow(channel: "R", peak: meters.outputPeakRight)
                }
                if meters.clippedSamples > 0 { ClipBadge() }
            }
            ForEach(counters, id: \.self) { line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Only the counters that are not zero.
    private func counterLines(for meters: MeterSnapshot) -> [String] {
        var lines: [String] = []
        if meters.overloads > 0 { lines.append("Sovraccarichi (xrun): \(meters.overloads)") }
        if meters.nonFiniteSamples > 0 { lines.append("Campioni NaN: \(meters.nonFiniteSamples)") }
        if meters.invalidCycles > 0 { lines.append("Cicli non validi: \(meters.invalidCycles)") }
        return lines
    }

    // MARK: Esclusi

    private var exclusionsSection: some View {
        PanelSection(title: "App escluse") {
            if controller.excludedBundleIDs.isEmpty {
                Text("Nessuna").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(controller.excludedBundleIDs, id: \.self) { bundleID in
                    Text(Self.displayName(forBundleID: bundleID)).font(.callout)
                }
            }
        }
    }

    private static func displayName(forBundleID bundleID: String) -> String {
        bundleID == "com.ableton.live" ? "Ableton Live" : Format.appName(forBundleID: bundleID)
    }

    // MARK: Diagnostica

    private var diagnosticsSection: some View {
        let meters = controller.meters
        let ring = controller.ringStatus
        return PanelSection(title: "Diagnostica") {
            Text("Formato tap: \(controller.tapFormatDescription ?? "—")")
            if controller.isRunning {
                if let frames = controller.ringDelayFrames, let ms = controller.ringDelayMilliseconds {
                    Text("Ritardo anello: \(frames) frame (\(Format.oneDecimal(ms)) ms)")
                }
                Text("Underrun \(ring.underrunCycles) · buchi \(ring.gapCycles) · sovrascritti \(ring.overwrittenCycles)")
                Text("Sovraccarichi: uscita \(meters.overloads) · cattura \(ring.captureOverloads)")
                Text(
                    "Ingresso L \(Self.peakText(meters.inputPeakLeft)) · R \(Self.peakText(meters.inputPeakRight))\n"
                        + "Uscita L \(Self.peakText(meters.outputPeakLeft)) · R \(Self.peakText(meters.outputPeakRight))"
                )
                .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Linear peak as "-12,3 dB" (or "-∞ dB").
    private static func peakText(_ peak: Float) -> String {
        Format.decibels(peak > 0 ? 20 * log10(peak) : -.infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Esci") {
                controller.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
