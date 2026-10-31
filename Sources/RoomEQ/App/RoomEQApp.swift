// App entry point: a menu-bar-only app (LSUIElement in Info.plist).
//
// The panel is `MenuPanelView` (MenuPanelView.swift): the stage-2 test panel
// plus the EQ section (EQSectionView.swift, EQBandsList.swift,
// EQCurveGraph.swift); the final UI can reuse PanelComponents.swift.

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
    }

    private var symbolName: String {
        switch controller.state {
        case .running, .starting: controller.isEQEnabled ? "slider.vertical.3" : "waveform"
        case .stopped, .stopping: "speaker.slash"
        case .failed: "exclamationmark.triangle"
        }
    }
}
