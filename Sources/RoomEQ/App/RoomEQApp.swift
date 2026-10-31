// App entry point: a menu-bar-only app (LSUIElement in Info.plist).
//
// The panel is `MenuPanelView` (MenuPanelView.swift), made of one view per
// block (EQQuickRow, EQSectionView, OutputSectionView, OutputPresetsView,
// ExclusionsView, SettingsSectionView, MetersSectionViews); shared pieces are
// in PanelComponents.swift.

import SwiftUI

@main
struct RoomEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar icon that changes with the engine state and the EQ on/off, so
/// both are visible without opening the panel. A separate view so that it observes the controller.
struct MenuBarIcon: View {
    let controller: AudioEngineController

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel(description)
    }

    private var symbolName: String {
        switch controller.menuBarState {
        case .stopped: "speaker.slash"
        case .starting: "hourglass"
        case .active: "slider.vertical.3"
        case .bypassed: "waveform"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var description: String {
        switch controller.menuBarState {
        case .stopped: "RoomEQ spento"
        case .starting: "RoomEQ in avvio"
        case .active: "RoomEQ attivo, EQ accesa"
        case .bypassed: "RoomEQ attivo, EQ spenta"
        case .failed: "RoomEQ: errore"
        }
    }
}
