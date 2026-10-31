// The list of EQ bands (one compact row each, inline editing) with the
// "Aggiungi filtro" / "Ripristina filtri iniziali" buttons.

import RoomEQCore
import SwiftUI

struct EQBandsList: View {
    let controller: AudioEngineController

    /// The band whose editor is open (one at a time).
    @State private var editingID: EQBand.ID?
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.bands.isEmpty {
                Text("Nessun filtro: aggiungine uno o importa da REW.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(controller.bands.enumerated()), id: \.element.id) { index, band in
                EQBandRow(
                    controller: controller,
                    band: band,
                    number: index + 1,
                    isEditing: editingID == band.id,
                    toggleEditing: { editingID = editingID == band.id ? nil : band.id },
                    delete: {
                        if editingID == band.id { editingID = nil }
                        controller.removeBand(id: band.id)
                    })
            }
            buttons
        }
        .confirmationDialog(
            "Sostituire i filtri attuali con i 4 filtri iniziali della misura REW?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Ripristina", role: .destructive) {
                editingID = nil
                controller.resetToDefaultFilters()
            }
            Button("Annulla", role: .cancel) {}
        }
    }

    private var buttons: some View {
        let isFull = controller.bands.count >= EQBand.maximumCount
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    if let band = controller.addBand() { editingID = band.id }
                } label: {
                    Label("Aggiungi filtro", systemImage: "plus")
                }
                .disabled(isFull)
                Spacer()
                Text("\(controller.bands.count) di \(EQBand.maximumCount) filtri")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Ripristina filtri iniziali") { confirmReset = true }
        }
    }
}

// MARK: - One band

private struct EQBandRow: View {
    let controller: AudioEngineController
    let band: EQBand
    let number: Int
    let isEditing: Bool
    let toggleEditing: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            summaryRow
            if let issue = controller.bandIssues[band.id] {
                Text(issue)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
            if isEditing { editor }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 6) {
            Toggle(
                "Filtro F\(number) attivo",
                isOn: Binding(get: { band.isEnabled }, set: { controller.setBandEnabled(id: band.id, $0) })
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            Text("F\(number)").font(.caption.weight(.semibold)).frame(width: 24, alignment: .leading)
            Text(Format.frequency(band.frequency)).frame(width: 66, alignment: .trailing)
            Text(Format.signedDecibels(band.gain)).frame(width: 66, alignment: .trailing)
            Text(Format.qFactor(band.q)).frame(width: 62, alignment: .trailing)
            Spacer(minLength: 0)
            Button(action: toggleEditing) {
                Image(systemName: isEditing ? "pencil.circle.fill" : "pencil")
            }
            .buttonStyle(.borderless)
            .help("Modifica il filtro")
            .accessibilityLabel("Modifica filtro F\(number)")
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Elimina il filtro")
            .accessibilityLabel("Elimina filtro F\(number)")
        }
        .font(.caption.monospacedDigit())
        .opacity(band.isEnabled ? 1 : 0.5)
    }

    // MARK: Inline editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            BandValueField(
                title: "Frequenza", unit: "Hz", maxDecimals: 2, value: band.frequency,
                set: { value in edit { $0.frequency = value } },
                step: { direction in
                    // Fine steps: 0,1 Hz below 100 Hz, 1 Hz below 1 kHz, 10 Hz above.
                    // Going down from exactly 100 Hz uses the step of the range below.
                    let reference = direction < 0 ? band.frequency - 0.0001 : band.frequency
                    let step = reference < 100 ? 0.1 : (reference < 1000 ? 1.0 : 10.0)
                    return round(band.frequency + Double(direction) * step, decimals: 1)
                })
            BandValueField(
                title: "Guadagno", unit: "dB", maxDecimals: 2, value: band.gain,
                set: { value in edit { $0.gain = value } },
                step: { round(band.gain + Double($0) * 0.1, decimals: 1) })
            BandValueField(
                title: "Q", unit: "", maxDecimals: 3, value: band.q,
                set: { value in edit { $0.q = value } },
                step: { round(band.q + Double($0) * 0.01, decimals: 2) })
        }
        .padding(.leading, 22)
        .padding(.vertical, 2)
    }

    /// Changes one parameter of the band and hands the result to the
    /// controller (which clamps it to the accepted range).
    private func edit(_ change: (inout EQBand) -> Void) {
        var edited = band
        change(&edited)
        controller.setBand(edited)
    }

    private func round(_ value: Double, decimals: Int) -> Double {
        let scale = pow(10, Double(decimals))
        return (value * scale).rounded() / scale
    }
}

/// Label + number field (Italian format, committed with Return or when
/// leaving the field) + stepper. `step(+1 / -1)` returns the new value.
private struct BandValueField: View {
    let title: String
    let unit: String
    let maxDecimals: Int
    let value: Double
    let set: (Double) -> Void
    let step: (Int) -> Double

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 66, alignment: .leading)
            TextField(
                title,
                value: Binding(get: { value }, set: set),
                format: Format.fieldStyle(maxDecimals: maxDecimals)
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            Stepper(
                onIncrement: { set(step(1)) },
                onDecrement: { set(step(-1)) }
            ) {
                EmptyView()
            }
            .labelsHidden()
            Text(unit).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
