// The "Filtri e preamp" section of the menu panel (collapsible, summary
// "4 filtri · preamp −3,5 dB"): curve graph, preamp, filter list, REW import.
// Warnings about a filter appear under that filter only (EQBandsList).
//
// Pure view over `AudioEngineController` (reads the observable properties,
// calls its methods).

import AppKit
import RoomEQCore
import SwiftUI
import UniformTypeIdentifiers

struct FiltersSectionView: View {
    let controller: AudioEngineController

    @State private var importWarningsExpanded = false
    @Environment(ConfirmationPresenter.self) private var confirmations

    var body: some View {
        CollapsibleSection(
            title: "Filtri e preamp", summary: summary, hasError: controller.lastImportError != nil, storageKey: "filters") {
            EQCurveGraph(controller: controller)
            preampBlock
            EQBandsList(controller: controller)
            importBlock
        }
    }

    /// "4 filtri · preamp −3,5 dB"; with some filters switched off,
    /// "3 di 4 filtri · preamp −3,5 dB".
    private var summary: String {
        let total = controller.bands.count
        let active = controller.bands.filter(\.isEnabled).count
        let filters: String
        switch (total, active) {
        case (0, _): filters = "Nessun filtro"
        case (1, _): filters = "1 filtro"
        case _ where active < total: filters = "\(active) di \(total) filtri"
        default: filters = "\(total) filtri"
        }
        return "\(filters) · preamp \(Format.signedDecibels(controller.preampDecibels))"
    }

    // MARK: Preamp

    private var preampBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preamp").font(.body)
                Spacer()
                Text(Format.signedDecibels(controller.preampDecibels))
                    .font(.body.monospacedDigit())
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
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Applica") { controller.setPreamp(suggested) }
                    .controlSize(.small)
                    .disabled(abs(controller.preampDecibels - suggested) < 0.05)
            }
        }
    }

    // MARK: Import

    private var importBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Importa da REW…") {
                    // Unsaved work is never replaced without asking.
                    if controller.hasUnsavedChanges { requestImport() } else { chooseREWFile() }
                }
                    .disabled(controller.isImporting)
                if controller.isImporting {
                    ProgressView().controlSize(.small)
                    Text("Importazione in corso…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let summary = controller.lastImportSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            importWarnings
            if let error = controller.lastImportError {
                DismissibleMessage(text: error) { controller.clearImportError() }
            }
        }
    }

    private func requestImport() {
        let message =
            controller.activePreset.map {
                "I filtri importati sostituiscono il suono attuale: le modifiche non salvate a «\($0.name)» andranno perse."
            } ?? "I filtri importati sostituiscono il suono attuale, che non è salvato in nessun preset e andrà perso."
        confirmations.present(
            InlineConfirmation(
                title: "Importare da REW?", message: message,
                options: [.destructive("Scegli il file…") { chooseREWFile() }]))
    }

    @ViewBuilder
    private var importWarnings: some View {
        let warnings = controller.lastImportWarnings
        if warnings.count > 3 {
            DisclosureGroup(isExpanded: $importWarningsExpanded) {
                warningLines(warnings)
            } label: {
                Text("\(warnings.count) avvisi sull'importazione")
                    .font(.callout.weight(.medium))
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
                    .font(.callout)
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
}
