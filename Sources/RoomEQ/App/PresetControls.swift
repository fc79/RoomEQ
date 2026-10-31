// Preset management inside the EQ section: Salva, Salva come…, and the "…"
// menu (Rinomina, Duplica, Elimina). Naming happens inline (no sheet: sheets
// are unreliable inside a menu-bar window) with live validation.
//
// Switching preset is in the quick row (EQQuickRow.swift).

import RoomEQCore
import SwiftUI

struct PresetControls: View {
    let controller: AudioEngineController

    private enum Editor: Equatable {
        case saveAs
        case rename(UUID)
    }

    @State private var editor: Editor?
    @State private var nameText = ""
    @State private var note: InlineNote?
    @State private var pendingDelete: EQPreset?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            buttonsRow
            if editor != nil { nameEditor }
            InlineNoteView(note: note)
        }
        .task(id: note?.id) {
            // Confirmations fade away; errors stay until the next action.
            guard let current = note, !current.isError else { return }
            try? await Task.sleep(for: .seconds(4))
            if note == current { note = nil }
        }
        .alert(
            "Eliminare il preset?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { preset in
            Button("Elimina", role: .destructive) { delete(preset) }
            Button("Annulla", role: .cancel) {}
        } message: { preset in
            Text(deleteMessage(for: preset))
        }
    }

    // MARK: Buttons

    private var buttonsRow: some View {
        HStack(spacing: 6) {
            Text("Preset").font(.callout)
            Spacer()
            Button("Salva") {
                // No active preset (e.g. deleted): saving means "Salva come…".
                if controller.activePreset == nil { startEditing(.saveAs) } else { saveToActive() }
            }
                .disabled(!controller.hasUnsavedChanges)
                .help(controller.activePreset == nil
                    ? "Salva il suono attuale come nuovo preset" : "Salva le modifiche nel preset attuale")
            Button("Salva come…") { startEditing(.saveAs) }
                .help("Salva il suono attuale come nuovo preset")
            Menu {
                Button("Rinomina…") {
                    if let active = controller.activePreset { startEditing(.rename(active.id)) }
                }
                .disabled(controller.activePreset == nil)
                Button("Duplica") { duplicateActive() }
                    .disabled(controller.activePreset == nil)
                Divider()
                Button("Elimina…", role: .destructive) { pendingDelete = controller.activePreset }
                    .disabled(controller.activePreset == nil || controller.presets.count < 2)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Altre azioni sul preset")
            .accessibilityLabel("Altre azioni sul preset")
        }
    }

    // MARK: Name editor

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editor == .saveAs ? "Nome del nuovo preset" : "Nuovo nome del preset")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Nome", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(commitName)
            if let error = nameError {
                Text(error)
                    .font(.caption)
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
            text += " Verrà tolto anche dalle assegnazioni per uscita."
        }
        return text
    }
}
