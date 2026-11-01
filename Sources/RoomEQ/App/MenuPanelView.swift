// The menu-bar panel.
//
// Pure view over `AudioEngineController`: it only reads the observable
// properties and calls the controller's methods. Layout (top to bottom):
//   fixed:      header (RoomEQ + the one "Correzione" switch, status line,
//                       errors and notices)
//               Preset row (menu, "Salva" when needed)
//               Livelli (meters, CLIP)
//   scrollable: collapsible sections, all closed by default (their state is
//               remembered), each with a short summary: Filtri e preamp,
//               Uscita e scheda, Regole per uscita, App escluse, Avvio,
//               Diagnostica
//   fixed:      footer (Esci)
//   over all:   the inline confirmation card (see InlineConfirmation)
// With every section closed the panel needs no scrolling. Each block is its
// own view file so blocks can be moved or reused.

import AppKit
import RoomEQCore
import SwiftUI

struct MenuPanelView: View {
    let controller: AudioEngineController

    /// The sections never grow beyond this height (then they scroll); header,
    /// preset row, levels and footer stay outside it, always visible.
    private static let scrollMaxHeight: CGFloat = 520

    @State private var scrollContentHeight: CGFloat = 200
    /// The unreadable-settings notice the user has dismissed (the notice is
    /// owned by the controller, which has no way to clear it).
    @State private var dismissedSettingsNotice: String?
    /// Confirmations of every section are shown by the overlay below.
    @State private var confirmations = ConfirmationPresenter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            PresetRowView(controller: controller)
            LevelsView(controller: controller)
            Divider()
            ScrollView {
                sections
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { scrollContentHeight = $0 }
            }
            .frame(height: min(max(scrollContentHeight, 1), Self.scrollMaxHeight))
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400)
        // Opening/closing a section changes the height: keep the top edge
        // under the menu bar (PanelWindowAnchor.swift).
        .keepsTopEdgeAnchored()
        .disabled(confirmations.current != nil)  // only the card answers
        .overlay { confirmationOverlay }
        .environment(confirmations)
        .onAppear(perform: refreshOnOpen)
        // The panel keeps its view between openings, so onAppear alone is
        // not enough: refresh whenever the panel window becomes key again
        // (not for the file choosers it opens).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard !(notification.object is NSOpenPanel) else { return }
            refreshOnOpen()
        }
    }

    /// The confirmation card over the dimmed panel (no separate window).
    @ViewBuilder
    private var confirmationOverlay: some View {
        if let confirmation = confirmations.current {
            ZStack(alignment: .top) {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { confirmations.dismiss() }
                InlineConfirmationCard(
                    confirmation: confirmation,
                    choose: { confirmations.choose($0) },
                    cancel: { confirmations.dismiss() }
                )
                .padding(14)
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 8) {
            FiltersSectionView(controller: controller)
            Divider()
            OutputSectionView(controller: controller)
            Divider()
            OutputRulesView(controller: controller)
            Divider()
            ExclusionsView(controller: controller)
            Divider()
            StartupSectionView(controller: controller)
            Divider()
            DiagnosticsSectionView(controller: controller)
        }
        .padding(.trailing, 6)  // room for the scroll bar
    }

    /// Things that can change outside the app while the panel is closed.
    private func refreshOnOpen() {
        controller.refreshLaunchAtLoginStatus()
        controller.refreshCandidateApps()
    }

    // MARK: Header: title, switch, status, errors

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RoomEQ").font(.title2.weight(.bold))
                Spacer()
                Toggle(
                    "Correzione",
                    isOn: Binding(get: { controller.isCorrectionOn }, set: { controller.setCorrectionOn($0) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
                .disabled(controller.state == .stopping)
                .help("Correzione")
                .accessibilityLabel("Correzione")
            }
            // While paused ("no correction" output) the status stands out.
            Text(controller.statusLine)
                .font(.callout.weight(controller.state == .paused ? .semibold : .regular))
                .foregroundStyle(controller.state == .paused ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            engineMessage
            if let notice = controller.settingsNotice, notice != dismissedSettingsNotice {
                DismissibleMessage(text: notice, color: .orange) { dismissedSettingsNotice = notice }
            }
            if let error = controller.saveError {
                DismissibleMessage(text: error) { controller.clearSaveError() }
            }
        }
    }

    /// An engine error (red, with "Riprova") when the correction has failed;
    /// otherwise a plain note, e.g. "X è stato scollegato: audio su Y".
    @ViewBuilder
    private var engineMessage: some View {
        if let message = controller.lastError {
            if controller.state == .failed {
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                // The switch stays on after an error: retry without toggling it.
                Button("Riprova") { controller.retry() }
                    .controlSize(.small)
            } else {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Esci") {
                controller.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
