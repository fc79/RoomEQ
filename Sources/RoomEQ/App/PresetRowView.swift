// The single "Preset" row under the header: a menu with the active preset's
// name (and an orange ● when there are unsaved changes), plus a "Salva"
// button that appears only when there is something to save.
//
// The menu lists the presets (✓ on the active one), then "Salva come…",
// "Rinomina…", "Duplica" and "Elimina…". Naming happens inline (no sheet:
// sheets and alerts open separate windows and close the menu-bar panel) with
// live validation; confirmations are the panel's inline card.
//
// Switching preset replaces the working sound: when there is unsaved work
// (`hasUnsavedChanges`: edits to the active preset, or a sound that is in no
// preset, e.g. after deleting the active one) the user is asked first (save
// and switch / switch without saving / cancel). With no active preset,
// "save" creates a new preset with a free name ("Senza nome"…).

import RoomEQCore
import SwiftUI

struct PresetRowView: View {
    let controller: AudioEngineController

    private enum Editor: Equatable {
        case saveAs
        case rename(UUID)
    }

    @State private var editor: Editor?
    @State private var nameText = ""
    @State private var note: InlineNote?
    @Environment(ConfirmationPresenter.self) private var confirmations
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            presetRow
            if editor != nil { nameEditor }
            if let message = controller.lastAutomaticPresetSwitch {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InlineNoteView(note: note)
        }
        .task(id: note?.id) {
            // Confirmations fade away; errors stay until the next action.
            guard let current = note, !current.isError else { return }
            try? await Task.sleep(for: .seconds(4))
            if note == current { note = nil }
        }
    }

    // MARK: The row

    private var presetRow: some View {
        HStack(spacing: 8) {
            Text("Preset").font(.body).foregroundStyle(.secondary)
            Menu {
                presetMenuItems
            } label: {
                HStack(spacing: 4) {
                    Text(controller.activePreset?.name ?? "Nessun preset")
                    if controller.hasUnsavedChanges {
                        Text("●").foregroundStyle(.orange).accessibilityLabel("modificato")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Preset")
            if controller.hasUnsavedChanges {
                Button("Salva") {
                    // No active preset (e.g. deleted): saving means "Salva come…".
                    if controller.activePreset == nil { startEditing(.saveAs) } else { saveToActive() }
                }
                .help(controller.activePreset == nil
                    ? "Salva il suono attuale come nuovo preset" : "Salva le modifiche nel preset attuale")
            }
        }
    }

    @ViewBuilder
    private var presetMenuItems: some View {
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
        Divider()
        Button("Salva come…") { startEditing(.saveAs) }
        Button("Rinomina…") {
            if let active = controller.activePreset { startEditing(.rename(active.id)) }
        }
        .disabled(controller.activePreset == nil)
        Button("Duplica") { duplicateActive() }
            .disabled(controller.activePreset == nil)
        Button("Elimina…", role: .destructive) { requestDelete() }
            .disabled(controller.activePreset == nil || controller.presets.count < 2)
    }

    // MARK: Switching preset

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
                options = [.destructive("Scarta modifiche") { apply(preset) }]
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

    // MARK: Name editor

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editor == .saveAs ? "Nome del nuovo preset" : "Nuovo nome del preset")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Nome", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(commitName)
            if let error = nameError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Annulla") { editor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(editor == .saveAs ? "Salva" : "Rinomina", action: commitName)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommitName)
            }
        }
        .onAppear { nameFieldFocused = true }
    }

    private var trimmedName: String { nameText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var renamedID: UUID? {
        if case .rename(let id) = editor { return id }
        return nil
    }

    /// Live validation; nothing is shown for an empty field (the button is
    /// just disabled).
    private var nameError: String? {
        guard editor != nil, !trimmedName.isEmpty else { return nil }
        return controller.presetNameError(nameText, excluding: renamedID)
    }

    private var canCommitName: Bool { !trimmedName.isEmpty && nameError == nil }

    private func startEditing(_ kind: Editor) {
        note = nil
        switch kind {
        case .saveAs:
            nameText = ""
        case .rename(let id):
            nameText = controller.presets.first { $0.id == id }?.name ?? ""
        }
        editor = kind
        nameFieldFocused = true
    }

    private func commitName() {
        guard canCommitName, let editor else { return }
        do {
            switch editor {
            case .saveAs:
                let preset = try controller.saveCurrentAsNewPreset(name: nameText)
                note = .info("Salvato come «\(preset.name)»")
            case .rename(let id):
                try controller.renamePreset(id: id, name: nameText)
                note = .info("Preset rinominato")
            }
            self.editor = nil
        } catch {
            note = .error(error.localizedDescription)
        }
    }

    // MARK: Actions

    private func saveToActive() {
        note = nil
        do {
            try controller.saveCurrentToActivePreset()
            if let name = controller.activePreset?.name { note = .info("Modifiche salvate in «\(name)»") }
        } catch {
            note = .error(error.localizedDescription)
        }
    }

    private func duplicateActive() {
        guard let active = controller.activePreset else { return }
        note = nil
        do {
            let copy = try controller.duplicatePreset(id: active.id)
            note = .info("Creato «\(copy.name)» (selezionalo dal menu Preset)")
        } catch {
            note = .error(error.localizedDescription)
        }
    }

    private func requestDelete() {
        guard let preset = controller.activePreset else { return }
        confirmations.present(
            InlineConfirmation(
                title: "Eliminare il preset «\(preset.name)»?",
                message: deleteMessage(for: preset),
                options: [.destructive("Elimina") { delete(preset) }]))
    }

    private func delete(_ preset: EQPreset) {
        note = nil
        do {
            try controller.deletePreset(id: preset.id)
            note = .info("Preset «\(preset.name)» eliminato; il suono non è cambiato")
        } catch {
            note = .error(error.localizedDescription)
        }
    }

    private func deleteMessage(for preset: EQPreset) -> String {
        var text = "«\(preset.name)» non sarà più disponibile. Il suono attuale non cambia."
        if controller.presetAssignments.values.contains(preset.id) {
            text += " Verrà tolto anche dalle regole per uscita."
        }
        return text
    }
}
