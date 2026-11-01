// "Regole per uscita" (collapsible, summary "Nessuna regola" / "N regole"):
// for each output, optionally a rule applied automatically when the macOS
// output changes: a preset (e.g. one for the monitors, one for the
// headphones) or "Nessuna correzione" (RoomEQ steps aside, audio goes
// straight to the device). The rules are always active (no switch).

import RoomEQCore
import SwiftUI

struct OutputRulesView: View {
    let controller: AudioEngineController

    @State private var note: InlineNote?

    var body: some View {
        CollapsibleSection(title: "Regole per uscita", summary: summary, storageKey: "rules") {
            Text(
                "Per ogni uscita: «Preset attuale» non cambia il suono, un preset lo cambia, "
                    + "«Nessuna correzione» fa da parte RoomEQ e l'audio va diretto, senza latenza."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        let outputs = controller.knownOutputs
            if outputs.isEmpty {
                Text("Nessuna uscita trovata").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(outputs) { output in
                row(for: output)
            }
            InlineNoteView(note: note)
        }
    }

    /// "Nessuna regola", "1 regola", "N regole" (outputs with a rule).
    private var summary: String {
        let count = controller.knownOutputs.filter { $0.assignment != nil }.count
        switch count {
        case 0: return "Nessuna regola"
        case 1: return "1 regola"
        default: return "\(count) regole"
        }
    }

    private func row(for output: KnownOutput) -> some View {
        let isInUse = controller.outputDeviceOptions.contains { $0.uid == output.uid && $0.isDefault }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(output.isConnected ? output.name : "\(output.name) (scollegato)")
                    .font(.body)
                    .foregroundStyle(output.isConnected ? .primary : .secondary)
                    .lineLimit(2)
                if isInUse {
                    Text("in uso").font(.callout).foregroundStyle(.secondary)
                }
                if output.hasRememberedEdits {
                    Text("modifiche non salvate ricordate")
                        .font(.callout)
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
                Text("Preset attuale").tag(RuleChoice.none)
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

    /// Picker tag for an output's rule (`none` = no rule, shown as
    /// "Preset attuale": the current sound stays, corrected).
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
