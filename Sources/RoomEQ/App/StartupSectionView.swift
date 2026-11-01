// The "Avvio" section (collapsible, summary "All'accesso" / "Manuale"):
// open RoomEQ at login, with the macOS hint and its (dismissible) error.

import RoomEQCore
import SwiftUI

struct StartupSectionView: View {
    let controller: AudioEngineController

    var body: some View {
        CollapsibleSection(
            title: "Avvio", summary: controller.launchAtLogin ? "All'accesso" : "Manuale",
            hasError: controller.launchAtLoginError != nil, storageKey: "startup"
        ) {
            Toggle(
                "Apri all'accesso",
                isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) })
            )
            .toggleStyle(.switch)
            if let hint = controller.launchAtLoginHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.launchAtLoginStatus == .requiresApproval {
                Button("Apri Elementi login") { controller.openLoginItemsSettings() }
            }
            if let error = controller.launchAtLoginError {
                DismissibleMessage(text: error) { controller.clearLaunchAtLoginError() }
            }
        }
    }

    private var needsAttention: Bool {
        controller.launchAtLoginStatus == .requiresApproval || controller.launchAtLoginStatus == .unavailable
    }
}
