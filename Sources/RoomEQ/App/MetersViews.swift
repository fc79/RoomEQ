// Levels (always visible, under the preset row) and diagnostics (the last
// collapsible section). Separate views, and the diagnostics' content a view
// of its own that exists only while the section is open, so that only these
// are redrawn at the meters' refresh rate (~25 times per second), not the panel.

import RoomEQCore
import SwiftUI

/// "Livelli": compact L/R peak meters, CLIP badge and, when it clips, why
/// (with the button that lowers the preamp).
struct LevelsView: View {
    let controller: AudioEngineController

    var body: some View {
        let meters = controller.meters
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(spacing: 3) {
                    LevelMeterRow(channel: "L", peak: meters.outputPeakLeft)
                    LevelMeterRow(channel: "R", peak: meters.outputPeakRight)
                }
                clipBadge
            }
            clipExplanation
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

    /// Why it clips: the correction (with a preamp suggestion) and/or the source.
    @ViewBuilder
    private var clipExplanation: some View {
        let clip = controller.clipStatus
        if clip.isClipping {
            VStack(alignment: .leading, spacing: 4) {
                if clip.eqCausedClipping {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(
                            clip.maxProcessingOverDecibels.map {
                                String(localized: "La correzione supera 0 dB di \(Format.signedDecibels($0, plusSign: true))")
                            } ?? String(localized: "La correzione supera 0 dB")
                        )
                        .font(.callout)
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
                        clip.maxInputOverDecibels.map {
                            String(localized: "Il segnale arriva già oltre 0 dB (\(Format.signedDecibels($0, plusSign: true))) dall'app: non dipende da RoomEQ")
                        } ?? String(localized: "Il segnale arriva già oltre 0 dB dall'app: non dipende da RoomEQ")
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// "Diagnostica": every technical detail (no summary in the title).
struct DiagnosticsSectionView: View {
    let controller: AudioEngineController

    var body: some View {
        CollapsibleSection(title: "Diagnostica", storageKey: "diagnostics") {
            DiagnosticsContent(controller: controller)
        }
    }
}

/// The lines of the diagnostics; reads the meters, so it must exist only
/// while the section is open.
private struct DiagnosticsContent: View {
    let controller: AudioEngineController

    var body: some View {
        let meters = controller.meters
        let ring = controller.ringStatus
        let clip = controller.clipStatus
        VStack(alignment: .leading, spacing: 3) {
            // "—" whenever there is no running session (latency is nil).
            Text("Latenza: \(controller.latency == nil ? "—" : controller.latencySummary)")
            Text("Formato tap: \(controller.tapFormatDescription ?? "—")")
            if controller.isRunning {
                if let frames = controller.ringDelayFrames, let ms = controller.ringDelayMilliseconds {
                    Text("Ritardo anello: \(frames) frame (\(AudioFormatText.milliseconds(ms)))")
                }
                Text("Underrun \(ring.underrunCycles) · buchi \(ring.gapCycles) · sovrascritti \(ring.overwrittenCycles)")
                Text(
                    "Clip: ingresso \(clip.inputClippedSamples) · correzione \(clip.processingClippedSamples) · uscita \(clip.outputClippedSamples)"
                )
                Text("Sovraccarichi (xrun): uscita \(meters.overloads) · cattura \(ring.captureOverloads)")
                Text("Campioni NaN: \(meters.nonFiniteSamples) · cicli non validi: \(meters.invalidCycles)")
                Text(
                    "Ingresso L \(Self.peakText(meters.inputPeakLeft)) · R \(Self.peakText(meters.inputPeakRight))\nUscita L \(Self.peakText(meters.outputPeakLeft)) · R \(Self.peakText(meters.outputPeakRight))"
                )
                .monospacedDigit()
            } else {
                Text("Gli altri valori compaiono quando la correzione è attiva.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Linear peak as "−12,3 dB" (or "—" for silence, below -90 dB).
    private static func peakText(_ peak: Float) -> String {
        Format.decibels(peak > 0 ? 20 * log10(peak) : -.infinity)
    }
}
