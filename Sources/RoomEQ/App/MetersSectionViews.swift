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
                clipBadge
            }
            clipExplanation
            ForEach(counters, id: \.self) { line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: CLIP

    /// Red "CLIP" badge; a click resets the indicator. When nothing clips it
    /// stays in the layout, invisible and inert, so the meters don't move.
    private var clipBadge: some View {
        let isClipping = controller.clipStatus.isClipping
        return Button { controller.resetClipIndicators() } label: { ClipBadge() }
            .buttonStyle(.plain)
            .help("Clic per azzerare")
            .accessibilityLabel("Saturazione: clic per azzerare")
            .opacity(isClipping ? 1 : 0)
            .allowsHitTesting(isClipping)
            .accessibilityHidden(!isClipping)
    }

    /// Why it clips: the EQ (with a preamp suggestion) and/or the source.
    @ViewBuilder
    private var clipExplanation: some View {
        let clip = controller.clipStatus
        if clip.isClipping {
            VStack(alignment: .leading, spacing: 4) {
                if clip.eqCausedClipping {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(
                            clip.maxProcessingOverDecibels.map {
                                "L'EQ supera 0 dB di \(Format.signedDecibels($0, plusSign: true))"
                            } ?? "L'EQ supera 0 dB"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let suggested = controller.suggestedPreampForClipping {
                            Button("Preamp a \(Format.signedDecibels(suggested))") {
                                controller.setPreamp(suggested)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if clip.sourceClipping {
                    Text(
                        "Il segnale arriva già oltre 0 dB"
                            + (clip.maxInputOverDecibels.map { " (\(Format.signedDecibels($0, plusSign: true)))" } ?? "")
                            + " dall'app: non dipende da RoomEQ"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
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
                    let clip = controller.clipStatus
                    Text(
                        "Clip: ingresso \(clip.inputClippedSamples) · EQ \(clip.processingClippedSamples) · uscita \(clip.outputClippedSamples)"
                    )
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
