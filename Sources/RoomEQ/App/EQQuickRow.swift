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

    /// A preset switch waiting for the user's decision.
    private struct PendingSwitch {
        let target: EQPreset
        /// Name of the preset with unsaved edits; nil = the sound is in no preset.
        let activeName: String?
        /// The target is the preset being edited: this only discards the edits.
        let isRevert: Bool
    }

    @State private var pendingSwitch: PendingSwitch?
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
        .alert(
            "Modifiche non salvate",
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            presenting: pendingSwitch
        ) { pending in
            if !pending.isRevert {
                Button(pending.activeName == nil ? "Salva come nuovo preset e cambia" : "Salva e cambia") {
                    saveThenApply(pending.target)
                }
            }
            Button(pending.isRevert ? "Ripristina" : "Cambia senza salvare", role: .destructive) {
                apply(pending.target)
            }
            Button("Annulla", role: .cancel) {}
        } message: { pending in
            if let name = pending.activeName {
                Text("Le modifiche non salvate a «\(name)» andranno perse. Continuare?")
            } else {
                Text("Il suono attuale non è salvato in nessun preset e andrà perso. Puoi salvarlo come «\(controller.suggestedNewPresetName)». Continuare?")
            }
        }
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
        if controller.hasUnsavedChanges {
            let active = controller.activePreset
            pendingSwitch = PendingSwitch(
                target: preset, activeName: active?.name, isRevert: active != nil && preset.id == active?.id)
        } else if preset.id != controller.activePresetID {
            apply(preset)
        }
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
