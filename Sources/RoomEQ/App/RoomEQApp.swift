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

/// Menu bar icon with four looks (applied / starting / not applied / error),
/// so it is clear without opening the panel whether the correction is on
/// (drawings in MenuBarIcons.swift). The accessibility label tells every
/// state apart.
/// A separate view so that it observes the controller.
struct MenuBarIcon: View {
    let controller: AudioEngineController

    var body: some View {
        Image(nsImage: MenuBarIcons.image(for: controller.menuBarState))
            .accessibilityLabel(description)
    }

    private var description: String {
        switch controller.menuBarState {
        case .stopped: "RoomEQ spento"
        case .starting: "RoomEQ in avvio"
        case .active: "RoomEQ attivo, EQ accesa"
        case .bypassed: "RoomEQ attivo, EQ spenta"
        case .failed: "RoomEQ: errore"
        case .paused: "RoomEQ in pausa: nessuna correzione per questa uscita"
        }
    }
}
