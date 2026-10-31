// The always-visible quick row under the header: "Correzione EQ" on/off
// (= bypass) and the preset switcher.
//
// Switching preset replaces the working EQ: when there are unsaved edits the
// user is asked first (save and switch / switch without saving / cancel).

import RoomEQCore
import SwiftUI

struct EQQuickRow: View {
    let controller: AudioEngineController

    /// A preset switch waiting for the user's decision.
    private struct PendingSwitch {
        let target: EQPreset
        /// Name of the preset with unsaved edits.
        let activeName: String
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
                Button("Salva e cambia") { saveThenApply(pending.target) }
            }
            Button(pending.isRevert ? "Ripristina" : "Cambia senza salvare", role: .destructive) {
                apply(pending.target)
            }
            Button("Annulla", role: .cancel) {}
        } message: { pending in
            Text("Le modifiche non salvate a «\(pending.activeName)» andranno perse. Continuare?")
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
                        if controller.isActivePresetModified {
                            Text("●").foregroundStyle(.orange).accessibilityLabel("modificato")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Cambia preset")
            }
            if controller.isActivePresetModified {
                Text("● Modifiche non salvate")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func requestSwitch(to preset: EQPreset) {
        note = nil
        if controller.isActivePresetModified, let active = controller.activePreset {
            pendingSwitch = PendingSwitch(
                target: preset, activeName: active.name, isRevert: preset.id == active.id)
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
            try controller.saveCurrentToActivePreset()
            try controller.applyPreset(id: preset.id)
        } catch {
            note = .error(error.localizedDescription)
        }
    }
}
