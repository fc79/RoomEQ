// Login item, auto-start, quick EQ toggle and menu-bar state (stage 4).
//
// Login item: SMAppService.mainApp (macOS 13+). macOS records the app by its
// path and code signature. RoomEQ is ad-hoc signed and rebuilt into ./build,
// so after a rebuild macOS may treat it as a different item (status
// "requires approval" or not found): it works best with the app copied to
// /Applications. `launchAtLoginHint` explains what to do.

import AppKit
import Foundation
import RoomEQCore
import ServiceManagement

extension AudioEngineController {
    // MARK: Quick toggle and menu-bar icon

    /// EQ on <-> off (click-free crossfade), for the menu bar.
    func toggleEQ() { setEQEnabled(!isEQEnabled) }

    /// State for a 3-state menu-bar icon (off / EQ on / EQ off) plus starting and error.
    var menuBarState: MenuBarState {
        switch state {
        case .stopped, .stopping: return .stopped
        case .starting: return .starting
        case .failed: return .failed
        case .running: return isEQEnabled ? .active : .bypassed
        }
    }

    // MARK: Auto-start

    /// Start the engine automatically when RoomEQ opens (default off).
    var autoStartEngineOnLaunch: Bool { settings.autoStartEngineOnLaunch }

    func setAutoStartEngineOnLaunch(_ enabled: Bool) {
        guard enabled != settings.autoStartEngineOnLaunch else { return }
        settings.autoStartEngineOnLaunch = enabled
        saveSettings()
    }

    // MARK: Login item

    /// True when registered (enabled or waiting for approval).
    var launchAtLogin: Bool { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }

    /// Italian hint for the current status, nil when nothing to do.
    var launchAtLoginHint: String? {
        switch launchAtLoginStatus {
        case .requiresApproval:
            return "Per completare, consenti RoomEQ in Impostazioni di Sistema › Generali › Elementi login."
        case .unavailable:
            return "macOS non trova RoomEQ come elemento di login: copia RoomEQ nella cartella Applicazioni e riprova."
        case .enabled, .disabled:
            return Self.isInApplicationsFolder
                ? nil : "L'apertura al login funziona meglio con RoomEQ nella cartella Applicazioni."
        }
    }

    /// Registers / unregisters RoomEQ as a login item. Errors in `lastSettingsError`.
    func setLaunchAtLogin(_ enabled: Bool) {
        lastSettingsError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastSettingsError = enabled
                ? "Impossibile attivare l'apertura al login: \(error.localizedDescription)"
                : "Impossibile disattivare l'apertura al login: \(error.localizedDescription)"
            Log.app.error("Login item: \(error.localizedDescription, privacy: .public)")
        }
        refreshLaunchAtLoginStatus()
    }

    /// Re-reads the status (call when the panel opens: the user may have
    /// changed it in System Settings).
    func refreshLaunchAtLoginStatus() {
        let status: LaunchAtLoginStatus
        switch SMAppService.mainApp.status {
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = .unavailable
        case .notRegistered: status = .disabled
        @unknown default: status = .disabled
        }
        if status != launchAtLoginStatus { launchAtLoginStatus = status }
    }

    /// Opens System Settings › Generali › Elementi login.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func clearSettingsError() { lastSettingsError = nil }

    private static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}
