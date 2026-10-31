// Latency, levels and diagnostics. Separate views so that only they are
// redrawn at the meters' refresh rate (~25 times per second), not the panel.

import RoomEQCore
import SwiftUI

/// "Latenza e livelli": latency as a big number, peak meters, CLIP badge.
struct LatencyLevelsSectionView: View {
    let controller: AudioEngineController

    var body: some View {
        let meters = controller.meters
        let counters = Self.counterLines(for: meters)
        return PanelSection(title: "Latenza e livelli") {
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
    private static func counterLines(for meters: MeterSnapshot) -> [String] {
        var lines: [String] = []
        if meters.overloads > 0 { lines.append("Sovraccarichi (xrun): \(meters.overloads)") }
        if meters.nonFiniteSamples > 0 { lines.append("Campioni NaN: \(meters.nonFiniteSamples)") }
        if meters.invalidCycles > 0 { lines.append("Cicli non validi: \(meters.invalidCycles)") }
        return lines
    }
}

/// "Diagnostica": technical details, collapsed by default.
struct DiagnosticsSectionView: View {
    let controller: AudioEngineController

    var body: some View {
        let meters = controller.meters
        let ring = controller.ringStatus
        return PanelDisclosure(title: "Diagnostica") {
            Group {
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
    }

    /// Linear peak as "−12,3 dB" (or "−∞ dB").
    private static func peakText(_ peak: Float) -> String {
        Format.decibels(peak > 0 ? 20 * log10(peak) : -.infinity)
    }
}
