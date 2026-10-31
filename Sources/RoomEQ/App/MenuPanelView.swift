// The menu-bar panel.
//
// Pure view over `AudioEngineController`: it only reads the observable
// properties and calls the controller's methods. Layout (top to bottom):
//   fixed:      header (RoomEQ on/off, status, errors)
//               quick row (Correzione EQ on/off + preset switcher)
//   scrollable: EQ, Uscita, Preset per uscita, App escluse, Impostazioni,
//               Latenza e livelli, Diagnostica
//   fixed:      footer (Esci)
// Each block is its own view file so blocks can be moved or reused.

import AppKit
import RoomEQCore
import SwiftUI

struct MenuPanelView: View {
    let controller: AudioEngineController

    /// The scrollable middle of the panel never grows beyond this height
    /// (header, quick row and footer stay outside it, always visible).
    private static let scrollMaxHeight: CGFloat = 440

    @State private var scrollContentHeight: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            EQQuickRow(controller: controller)
            Divider()
            ScrollView {
                scrollContent
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { scrollContentHeight = $0 }
            }
            .frame(height: min(max(scrollContentHeight, 1), Self.scrollMaxHeight))
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear(perform: refreshOnOpen)
        // The panel keeps its view between openings, so onAppear alone is
        // not enough: refresh whenever the panel window becomes key again
        // (not for the file choosers it opens).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard !(notification.object is NSOpenPanel) else { return }
            refreshOnOpen()
        }
    }

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            EQSectionView(controller: controller)
            Divider()
            OutputSectionView(controller: controller)
            Divider()
            OutputPresetsView(controller: controller)
            Divider()
            ExclusionsView(controller: controller)
            Divider()
            SettingsSectionView(controller: controller)
            Divider()
            LatencyLevelsSectionView(controller: controller)
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

    // MARK: Header: title, on/off, status, errors

    private var isActive: Bool { controller.isRunning || controller.state == .starting }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RoomEQ").font(.title2.weight(.bold))
                Spacer()
                Toggle(
                    "Attiva RoomEQ",
                    isOn: Binding(get: { isActive }, set: { _ in controller.toggle() })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
                .disabled(controller.state == .stopping)
            }
            Text(controller.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = controller.lastError {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = controller.lastSettingsError {
                DismissibleMessage(text: error) { controller.clearSettingsError() }
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
