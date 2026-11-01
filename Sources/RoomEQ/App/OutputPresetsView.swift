// "Impostazioni per uscita": optionally apply a rule automatically when the
// macOS output changes: a preset (e.g. one for the monitors, one for the
// headphones) or "Nessuna correzione" (RoomEQ pauses, audio goes straight to
// the device). Collapsed by default.

import RoomEQCore
import SwiftUI

struct OutputPresetsView: View {
    let controller: AudioEngineController

    @State private var note: InlineNote?

    var body: some View {
        PanelDisclosure(title: "Impostazioni per uscita") {
            Toggle(
                "Usa le impostazioni per uscita",
                isOn: Binding(
                    get: { controller.isPresetPerOutputEnabled },
                    set: { controller.setPresetPerOutputEnabled($0) })
            )
            .toggleStyle(.switch)
            Text(
                controller.isPresetPerOutputEnabled
                    ? "Quando cambi uscita in macOS, RoomEQ applica il preset assegnato. "
                    + "Con «Nessuna correzione» RoomEQ si mette in pausa: l'audio va diretto, senza latenza aggiunta."
                    : "Spento: le impostazioni qui sotto non hanno effetto."
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
                "Impostazione per \(output.name)",
                selection: Binding<RuleChoice>(
                    get: { RuleChoice(output.assignment) },
                    set: { assign($0, to: output) })
            ) {
                Text("Nessuna regola").tag(RuleChoice.none)
                ForEach(controller.presets) { preset in
                    Text(preset.name).tag(RuleChoice.preset(preset.id))
                }
                Divider()
                Text("Nessuna correzione").tag(RuleChoice.noCorrection)
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }

    /// Picker tag for an output's rule (`none` = no rule).
    private enum RuleChoice: Hashable {
        case none
        case preset(UUID)
        case noCorrection

        init(_ assignment: OutputAssignment?) {
            switch assignment {
            case nil: self = .none
            case .preset(let id): self = .preset(id)
            case .noCorrection: self = .noCorrection
            }
        }
    }

    private func assign(_ choice: RuleChoice, to output: KnownOutput) {
        note = nil
        switch choice {
        case .none:
            controller.clearAssignment(deviceUID: output.uid)
        case .noCorrection:
            controller.assignNoCorrection(toDeviceUID: output.uid)
        case .preset(let presetID):
            do {
                try controller.assignPreset(id: presetID, toDeviceUID: output.uid)
            } catch {
                note = .error(error.localizedDescription)
            }
        }
    }
}
