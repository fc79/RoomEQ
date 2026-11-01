// "App escluse" (collapsible, summary: the app names when 1–2, else "N app"):
// apps whose audio does NOT go through RoomEQ (e.g. Ableton Live, which has
// its own correction). RoomEQ itself is always excluded (not listed).

import AppKit
import RoomEQCore
import SwiftUI
import UniformTypeIdentifiers

struct ExclusionsView: View {
    let controller: AudioEngineController

    @Environment(ConfirmationPresenter.self) private var confirmations
    @Environment(\.fileChooser) private var fileChooser
    @State private var note: InlineNote?

    var body: some View {
        CollapsibleSection(title: "App escluse", summary: summary, storageKey: "exclusions") {
            if controller.excludedApps.isEmpty {
                Text("Nessuna app esclusa").font(.body).foregroundStyle(.secondary)
            }
            ForEach(controller.excludedApps) { app in
                row(for: app)
            }
            addMenu
            InlineNoteView(note: note)
        }
    }

    /// "Ableton Live", "Ableton Live, REW", "3 app", "Nessuna".
    private var summary: String {
        let apps = controller.excludedApps
        switch apps.count {
        case 0: return String(localized: "Nessuna")
        case 1, 2: return apps.map(\.name).joined(separator: ", ")
        default: return String(localized: "\(apps.count) app")
        }
    }

    // MARK: Excluded apps

    private func row(for app: ExcludedApp) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: controller.icon(forBundleID: app.bundleID))
                .resizable()
                .frame(width: 22, height: 22)
                .opacity(app.isInstalled ? 1 : 0.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).font(.body)
                    if !app.isInstalled {
                        Text("non installata").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let warning = app.warning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button {
                note = nil
                controller.removeExcludedApp(bundleID: app.bundleID)
                controller.refreshCandidateApps()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Smetti di escludere «\(app.name)»")
            .accessibilityLabel("Rimuovi «\(app.name)» dalle app escluse")
        }
    }

    // MARK: Adding

    private var addMenu: some View {
        Menu {
            if controller.candidateApps.isEmpty {
                Text("Nessun'altra app aperta")
            }
            ForEach(controller.candidateApps) { app in
                Button {
                    request(app, presenter: confirmations)
                } label: {
                    Label {
                        Text(app.isPlayingAudio ? String(localized: "\(app.name) · sta suonando") : app.name)
                    } icon: {
                        Image(nsImage: controller.icon(forBundleID: app.bundleID).resized(toSide: 16))
                    }
                }
            }
            Divider()
            Button("Scegli dalle Applicazioni…") { chooseApp() }
        } label: {
            Label("Aggiungi app…", systemImage: "plus")
        }
        .fixedSize()
    }

    /// Adds the app, after asking if the exclusion has a warning (e.g. REW).
    private func request(_ app: AppInfo, presenter: ConfirmationPresenter) {
        note = nil
        if let warning = controller.warningForExcluding(bundleID: app.bundleID) {
            presenter.present(
                InlineConfirmation(
                    title: "Escludere «\(app.name)»?", message: warning,
                    options: [.standard("Escludi") { add(app) }]))
        } else {
            add(app)
        }
    }

    private func add(_ app: AppInfo) {
        do {
            try controller.addExcludedApp(app)
            note = nil
        } catch {
            note = .error(error.localizedDescription)
        }
        controller.refreshCandidateApps()
    }

    /// Opens the app chooser without blocking, keeping the menu bar panel
    /// open meanwhile (`FileChooser`, StatusItemController.swift).
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Scegli un'app da escludere")
        panel.message = String(localized: "Scegli l'app il cui audio non deve passare da RoomEQ.")
        panel.prompt = String(localized: "Escludi")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        // The environment must not be read inside the completion handler
        // (the panel may have closed meanwhile): take what it needs now.
        let presenter = confirmations
        fileChooser(panel) { [self] url in
            guard let url else { return }
            guard let app = controller.appInfo(forBundleURL: url) else {
                note = .error(String(localized: "Questa app non ha un identificativo valido: non posso escluderla."))
                return
            }
            request(app, presenter: presenter)
        }
    }
}
