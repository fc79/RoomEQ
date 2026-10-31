// App entry point: a menu-bar-only app (LSUIElement in Info.plist).
//
// The panel is `MenuPanelView` (MenuPanelView.swift): still the stage-2 test
// panel (the EQ section is added on top of the stage-3 controller API); the
// final UI can reuse the building blocks in PanelComponents.swift.

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

/// Menu bar icon that changes with the engine state, so on/off is visible
/// without opening the panel. A separate view so that it observes the controller.
struct MenuBarIcon: View {
    let controller: AudioEngineController

    var body: some View {
        Image(systemName: symbolName)
    }

    private var symbolName: String {
        switch controller.state {
        case .running, .starting: "slider.vertical.3"
        case .stopped, .stopping: "speaker.slash"
        case .failed: "exclamationmark.triangle"
        }
    }
}
