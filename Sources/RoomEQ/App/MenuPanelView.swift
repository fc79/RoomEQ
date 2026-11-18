// The menu-bar panel, shown in a popover under the menu bar icon
// (StatusItemController.swift). The popover takes this view's ideal size and
// follows it when sections open or close; what must be refreshed at each
// opening is refreshed there too.
//
// Pure view over `AudioEngineController` and `RecordingController`: it only
// reads the observable properties and calls their methods. Layout (top to
// bottom):
//   fixed:      header (RoomEQ + the one "Correzione" switch, status line,
//                       errors and notices)
//               Preset row (menu, "Salva" when needed)
//               Livelli (meters, CLIP)
//               Registra (RecordingRowView: apps, skip silence, levels)
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

/// Height of the visible frame (under the menu bar, above the Dock) of the
/// screen the panel opens on: the status item sets it before showing.
@MainActor
@Observable
final class PanelScreen {
    var visibleHeight: CGFloat = 900
}

struct MenuPanelView: View {
    let controller: AudioEngineController
    let recorder: RecordingController
    let screen: PanelScreen

    /// The sections never grow beyond this height (then they scroll); header,
    /// preset row, levels, recording row and footer stay outside it, always
    /// visible. Lower on a short screen: the whole panel must fit under the
    /// menu bar (see `scrollHeight`).
    private static let scrollMaxHeight: CGFloat = 520

    @State private var scrollContentHeight: CGFloat = 200
    /// Height of everything except the sections' scroll area.
    @State private var fixedHeight: CGFloat = 300
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
            RecordingRowView(recorder: recorder)
            Divider()
            ScrollView {
                sections
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { scrollContentHeight = $0 }
            }
            .frame(height: scrollHeight)
            Divider()
            footer
        }
        .padding(14)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { total in
            fixedHeight = max(0, total - scrollHeight)
        }
        .frame(width: 400)
        .disabled(confirmations.current != nil)  // only the card answers
        // Moving the pointer onto the menu bar makes another app active
        // (macOS 26) while the panel stays open: keep the controls in their
        // active look (blue switch) instead of the grey inactive one.
        .environment(\.appearsActive, true)
        .overlay { confirmationOverlay }
        .environment(confirmations)
    }

    /// The sections' scroll height: their content, at most `scrollMaxHeight`
    /// and at most what is left of the screen under the menu bar after the
    /// fixed parts (so the popover never runs off the top of the screen).
    private var scrollHeight: CGFloat {
        let available = screen.visibleHeight - fixedHeight - 40  // popover arrow and margins
        return max(80, min(max(scrollContentHeight, 1), Self.scrollMaxHeight, available))
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

    // MARK: Header: title, switch, status, errors

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: "RoomEQ").font(.title2.weight(.bold))
                Spacer()
                Toggle(
                    "Correzione",
                    isOn: Binding(get: { controller.isCorrectionOn }, set: { controller.setCorrectionOn($0) })
                )
                .labelsHidden()
                .toggleStyle(AlwaysActiveSwitchStyle())
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
                // applicationWillTerminate closes the recording files first,
                // then shuts the engine down.
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
