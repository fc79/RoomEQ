// "Preset per uscita": optionally apply a preset automatically when the macOS
// output changes (e.g. one for the monitors, one for the headphones).
// Collapsed by default.

import RoomEQCore
import SwiftUI

struct OutputPresetsView: View {
    let controller: AudioEngineController

    @State private var note: InlineNote?

    var body: some View {
        PanelDisclosure(title: "Preset per uscita") {
            Toggle(
                "Cambia preset in base all'uscita",
                isOn: Binding(
                    get: { controller.isPresetPerOutputEnabled },
                    set: { controller.setPresetPerOutputEnabled($0) })
            )
            .toggleStyle(.switch)
            Text(
                controller.isPresetPerOutputEnabled
                    ? "Quando cambi uscita in macOS, RoomEQ applica il preset assegnato a quell'uscita."
                    : "Spento: le assegnazioni qui sotto non hanno effetto."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            let outputs = controller.knownOutputs
            if outputs.isEmpty {
                Text("Nessuna uscita trovata").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(outputs) { output in
                row(for: output)
            }
            InlineNoteView(note: note)
        }
    }

    private func row(for output: KnownOutput) -> some View {
        let isInUse = controller.outputDeviceOptions.contains { $0.uid == output.uid && $0.isDefault }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(output.isConnected ? output.name : "\(output.name) (scollegato)")
                    .font(.callout)
                    .foregroundStyle(output.isConnected ? .primary : .secondary)
                    .lineLimit(2)
                if isInUse {
                    Text("in uso").font(.caption2).foregroundStyle(.secondary)
                }
                if output.hasRememberedEdits {
                    Text("modifiche non salvate ricordate")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            Picker(
                "Preset per \(output.name)",
                selection: Binding<UUID?>(
                    get: { output.assignedPresetID },
                    set: { assign($0, to: output) })
            ) {
                Text("Nessuno").tag(UUID?.none)
                ForEach(controller.presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }

    private func assign(_ presetID: UUID?, to output: KnownOutput) {
        note = nil
        guard let presetID else {
            controller.clearAssignment(deviceUID: output.uid)
            return
        }
        do {
            try controller.assignPreset(id: presetID, toDeviceUID: output.uid)
        } catch {
            note = .error(error.localizedDescription)
        }
    }
}
