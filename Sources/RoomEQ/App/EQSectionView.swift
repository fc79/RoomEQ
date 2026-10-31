// The "EQ" section of the menu panel: preset management, preamp, curve graph,
// band list, REW import and filter warnings. (EQ on/off and preset switching
// are in the always-visible quick row, EQQuickRow.swift.)
//
// Pure view over `AudioEngineController` (reads the observable properties,
// calls its methods).

import AppKit
import RoomEQCore
import SwiftUI
import UniformTypeIdentifiers

struct EQSectionView: View {
    let controller: AudioEngineController

    @State private var importWarningsExpanded = false
    /// Asking before an import replaces unsaved work.
    @State private var confirmImport = false

    var body: some View {
        PanelSection(title: "EQ") {
            if let notice = controller.settingsNotice {
                warningLines([notice])
            }
            PresetControls(controller: controller)
            preampBlock
            EQCurveGraph(controller: controller)
            EQBandsList(controller: controller)
            importBlock
            filterWarningsBlock
        }
        .alert("Importare da REW?", isPresented: $confirmImport) {
            Button("Scegli il file…", role: .destructive) { chooseREWFile() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(controller.activePreset.map { "I filtri importati sostituiscono il suono attuale: le modifiche non salvate a «\($0.name)» andranno perse." }
                ?? "I filtri importati sostituiscono il suono attuale, che non è salvato in nessun preset e andrà perso.")
        }
    }

    // MARK: Preamp

    private var preampBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preamp").font(.callout)
                Spacer()
                Text(Format.signedDecibels(controller.preampDecibels))
                    .font(.callout.monospacedDigit())
            }
            // Free slider; the value is rounded to 0,1 dB when it is set.
            Slider(
                value: Binding(
                    get: { controller.preampDecibels },
                    set: { controller.setPreamp(($0 * 10).rounded() / 10) }),
                in: AudioEngineController.preampRange
            ) {
                Text("Preamp")
            }
            .labelsHidden()
            preampAdvice
        }
    }

    @ViewBuilder
    private var preampAdvice: some View {
        let boost = controller.maxCurveBoostDecibels
        if boost > 0 {
            let suggested = controller.suggestedPreampDecibels
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(
                    "La curva amplifica fino a \(Format.signedDecibels(boost, plusSign: true)): "
                        + "preamp consigliato \(Format.signedDecibels(suggested))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Applica") { controller.setPreamp(suggested) }
                    .controlSize(.small)
                    .disabled(abs(controller.preampDecibels - suggested) < 0.05)
            }
        } else {
            Text("La curva non amplifica: preamp 0 dB va bene")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Import

    private var importBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Importa da REW…") {
                    // Unsaved work is never replaced without asking.
                    if controller.hasUnsavedChanges { confirmImport = true } else { chooseREWFile() }
                }
                    .disabled(controller.isImporting)
                if controller.isImporting {
                    ProgressView().controlSize(.small)
                    Text("Importazione in corso…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let summary = controller.lastImportSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            importWarnings
            if let error = controller.lastImportError {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("In REW: EQ › Export filter settings as text")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var importWarnings: some View {
        let warnings = controller.lastImportWarnings
        if warnings.count > 3 {
            DisclosureGroup(isExpanded: $importWarningsExpanded) {
                warningLines(warnings)
            } label: {
                Text("\(warnings.count) avvisi sull'importazione")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        } else if !warnings.isEmpty {
            warningLines(warnings)
        }
    }

    private func warningLines(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Opens the file chooser without blocking (`begin`, not `runModal`).
    /// The app is activated first, otherwise the panel could open behind
    /// other windows (RoomEQ is a menu-bar-only app).
    private func chooseREWFile() {
        let panel = NSOpenPanel()
        panel.title = "Importa filtri da REW"
        panel.message = "Scegli il file di testo esportato da REW (Export filter settings as text)."
        panel.prompt = "Importa"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Text files first, but any file can be chosen.
        panel.allowedContentTypes = [.plainText, .data]
        panel.allowsOtherFileTypes = true
        NSApp.activate()
        panel.begin { [controller] response in
            guard response == .OK, let url = panel.url else { return }
            controller.importREWFile(url: url)
        }
    }

    // MARK: Filter warnings

    @ViewBuilder
    private var filterWarningsBlock: some View {
        if !controller.filterWarnings.isEmpty {
            warningLines(controller.filterWarnings)
        }
    }
}
