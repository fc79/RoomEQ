// The always-visible quick row under the header: "Correzione EQ" on/off
// (= bypass) and the preset switcher.
//
// Switching preset replaces the working EQ: when there is unsaved work
// (`hasUnsavedChanges`: edits to the active preset, or a sound that is in no
// preset, e.g. after deleting the active one) the user is asked first (save
// and switch / switch without saving / cancel). With no active preset,
// "save" creates a new preset with a free name ("Senza nome"…).

import RoomEQCore
import SwiftUI

struct EQQuickRow: View {
    let controller: AudioEngineController

    @Environment(ConfirmationPresenter.self) private var confirmations
    @State private var note: InlineNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            eqToggleRow
            presetRow
            if let message = controller.lastAutomaticPresetSwitch {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InlineNoteView(note: note)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: EQ on/off

    private var eqToggleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Correzione EQ").font(.title3.weight(.semibold))
                Spacer()
                Toggle(
                    "Correzione EQ",
                    isOn: Binding(get: { controller.isEQEnabled }, set: { controller.setEQEnabled($0) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
            }
            if !controller.isEQEnabled {
                Text("EQ spenta (bypass): senti il suono originale")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if !(controller.isRunning || controller.state == .starting) {
                Text("RoomEQ è spento: la correzione non è applicata")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Preset switcher

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Preset").font(.callout).foregroundStyle(.secondary)
                Menu {
                    ForEach(controller.presets) { preset in
                        Button {
                            requestSwitch(to: preset)
                        } label: {
                            if preset.id == controller.activePresetID {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(controller.activePreset?.name ?? "Nessun preset")
                        if controller.hasUnsavedChanges {
                            Text("●").foregroundStyle(.orange).accessibilityLabel("modificato")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Cambia preset")
            }
            if controller.hasUnsavedChanges {
                Text(controller.activePreset == nil ? "● Suono non salvato in nessun preset" : "● Modifiche non salvate")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func requestSwitch(to preset: EQPreset) {
        note = nil
        guard controller.hasUnsavedChanges else {
            if preset.id != controller.activePresetID { apply(preset) }
            return
        }
        let active = controller.activePreset
        var options: [InlineConfirmation.Option] = []
        let message: String
        if let active {
            message = "Le modifiche non salvate a «\(active.name)» andranno perse. Continuare?"
            if preset.id == active.id {
                // Picking the preset being edited: only discards the edits.
                options = [.destructive("Ripristina") { apply(preset) }]
            } else {
                options = [
                    .standard("Salva e cambia") { saveThenApply(preset) },
                    .destructive("Cambia senza salvare") { apply(preset) },
                ]
            }
        } else {
            message =
                "Il suono attuale non è salvato in nessun preset e andrà perso. "
                + "Puoi salvarlo come «\(controller.suggestedNewPresetName)». Continuare?"
            options = [
                .standard("Salva come nuovo preset e cambia") { saveThenApply(preset) },
                .destructive("Cambia senza salvare") { apply(preset) },
            ]
        }
        confirmations.present(InlineConfirmation(title: "Modifiche non salvate", message: message, options: options))
    }

    private func apply(_ preset: EQPreset) {
        do {
            try controller.applyPreset(id: preset.id)
        } catch {
            note = .error(error.localizedDescription)
        }
    }

    private func saveThenApply(_ preset: EQPreset) {
        do {
            if controller.activePreset == nil {
                let saved = try controller.saveCurrentAsNewPreset(name: controller.suggestedNewPresetName)
                note = .info("Suono salvato come «\(saved.name)»")
            } else {
                try controller.saveCurrentToActivePreset()
            }
            try controller.applyPreset(id: preset.id)
        } catch {
            note = .error(error.localizedDescription)
        }
    }
}
