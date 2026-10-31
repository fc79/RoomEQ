// "Impostazioni": open at login and start RoomEQ when it opens.

import RoomEQCore
import SwiftUI

struct SettingsSectionView: View {
    let controller: AudioEngineController

    var body: some View {
        PanelDisclosure(title: "Impostazioni") {
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

            Toggle(
                "Accendi RoomEQ all'apertura",
                isOn: Binding(
                    get: { controller.autoStartEngineOnLaunch },
                    set: { controller.setAutoStartEngineOnLaunch($0) })
            )
            .toggleStyle(.switch)
            Text("All'apertura dell'app la correzione parte da sola, senza premere l'interruttore in alto.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var needsAttention: Bool {
        controller.launchAtLoginStatus == .requiresApproval || controller.launchAtLoginStatus == .unavailable
    }
}
