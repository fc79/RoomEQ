// The "Registra" row of the panel (always visible, under the levels):
//   stopped:   [● Registra] [Brave, Spotify · salta silenzio ⌄]
//              the button opens the app picker in place (checkboxes, apps
//              playing first, "Salta il silenzio");
//   recording: [■ Ferma] ● 03:27 ............ Mostra nel Finder
//              then one level per app ("in pausa · silenzio" while "skip
//              silence" waits for it).
// Notices (lost audio, disk almost full) and the result ("Salvati 2 file")
// appear under the row, like the other messages of the panel.
//
// Pure view over `RecordingController`.

import RoomEQCore
import SwiftUI

struct RecordingRowView: View {
    let recorder: RecordingController

    @State private var showsPicker = false
    @State private var listHeight: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recorder.isRecording { recordingRow } else { idleRow }
            if !recorder.isRecording, recorder.chosen.isEmpty {
                Text("Scegli almeno un'app da registrare.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if showsPicker, !recorder.isRecording { picker }
            if recorder.isRecording { levels }
            messages
        }
    }

    // MARK: Rows

    private var idleRow: some View {
        HStack(spacing: 8) {
            Button {
                showsPicker = false
                recorder.start()
            } label: {
                Label {
                    recorder.isStarting ? Text("Avvio…") : Text("Registra")
                } icon: {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(recorder.canStart ? Color.red : Color.secondary)
                }
            }
            .disabled(!recorder.canStart)
            Button {
                showsPicker.toggle()
                if showsPicker { recorder.refreshApps() }
            } label: {
                HStack(spacing: 4) {
                    Text(pickerTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsPicker ? 180 : 0))
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel(Text("App da registrare: \(recorder.summary)"))
            .accessibilityValue(showsPicker ? Text("aperto") : Text("chiuso"))
        }
    }

    private var pickerTitle: String {
        recorder.skipSilence
            ? String(localized: "\(recorder.summary) · salta silenzio") : recorder.summary
    }

    private var recordingRow: some View {
        HStack(spacing: 8) {
            Button {
                recorder.stop()
            } label: {
                Label("Ferma", systemImage: "stop.fill")
            }
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(Format.duration(recorder.elapsed))
                    .font(.body.monospacedDigit().weight(.semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Registrazione in corso, \(Format.duration(recorder.elapsed))"))
            Spacer(minLength: 4)
            Button("Mostra nel Finder") { recorder.showInFinder() }
                .buttonStyle(.link)
        }
    }

    // MARK: Picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("App da registrare")
                Spacer()
                Text("un file per app")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if recorder.apps.isEmpty {
                Text("Nessuna app aperta.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // About 7 rows, then the list scrolls in place (a long list of
            // open apps must not push the panel off the screen).
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recorder.apps) { app in
                        Toggle(isOn: Binding(get: { app.isChosen }, set: { recorder.setChosen($0, app: app) })) {
                            HStack {
                                Text(app.name).lineLimit(1)
                                Spacer(minLength: 6)
                                if app.isPlaying {
                                    Label("sta suonando", systemImage: "waveform")
                                        .font(.callout)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), 168))
            Divider().padding(.vertical, 2)
            Toggle(isOn: Binding(get: { recorder.skipSilence }, set: { recorder.skipSilence = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Salta il silenzio")
                    Text("Dopo 2 s di silenzio il file si chiude; quando l'app riprende ne inizia uno nuovo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    // MARK: While recording

    private var levels: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(recorder.live) { app in
                if app.isPaused {
                    HStack(spacing: 8) {
                        Text(app.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .frame(width: 90, alignment: .leading)
                        Text("in pausa · silenzio")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    LevelMeterRow(channel: app.name, peak: app.level, labelWidth: 90)
                }
            }
        }
    }

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        if let notice = recorder.notice {
            Text(notice)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let failure = recorder.failure {
            DismissibleMessage(text: failure) { recorder.clearFailure() }
        }
        if !recorder.isRecording, let saved = recorder.savedSummary {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(saved)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !recorder.savedFiles.isEmpty {
                    Button("Mostra nel Finder") { recorder.showInFinder() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                Spacer(minLength: 0)
                Button {
                    recorder.clearSaved()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Chiudi il messaggio")
                .accessibilityLabel("Chiudi il messaggio")
            }
        }
    }
}
