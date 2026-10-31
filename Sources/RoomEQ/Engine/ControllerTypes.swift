// Value types exposed by AudioEngineController to the UI (stage 4).

import Foundation
import RoomEQCore

/// An app in the exclusion list (RoomEQ itself is never listed: it is
/// always excluded).
struct ExcludedApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    /// Installed app's name, or the last known one.
    let name: String
    /// Installed app bundle (for the icon: `NSWorkspace.shared.icon(forFile: url.path)`),
    /// nil when not installed.
    let url: URL?
    /// Italian warning about this exclusion (REW), else nil.
    let warning: String?

    var id: String { bundleID }
    var isInstalled: Bool { url != nil }
}

/// A candidate app to exclude (running regular apps, or one picked in Finder).
struct AppInfo: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let url: URL?
    /// Currently running.
    let isRunning: Bool
    /// Currently sending audio to an output (Core Audio process list).
    let isPlayingAudio: Bool
    /// Italian warning if excluded (REW), else nil.
    var warning: String? { ExclusionRules.warning(forBundleID: bundleID) }

    var id: String { bundleID }
}

/// An output device for the output menu.
struct OutputDeviceOption: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    /// "USB", "Bluetooth", "Integrato", "HDMI", "Virtuale"…
    let transportName: String
    let outputChannelCount: Int
    let nominalSampleRate: Double?
    /// It is the macOS default output (the one RoomEQ uses).
    let isDefault: Bool

    var id: String { uid }
}

/// An output known to RoomEQ (connected now, or remembered), for the
/// per-output preset assignments.
struct KnownOutput: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    let isConnected: Bool
    /// Assigned preset (nil = none, or the preset no longer exists).
    let assignedPresetID: UUID?
    /// Unsaved edits are remembered for this output.
    let hasRememberedEdits: Bool

    var id: String { uid }
}

/// "Open at login" status (SMAppService.mainApp).
enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    /// Registered, but the user must allow it in System Settings ›
    /// Generali › Elementi login (`openLoginItemsSettings()`).
    case requiresApproval
    /// macOS can't find the app as a login item (typically: not in /Applications).
    case unavailable
}

/// Three states (plus transitions) for the menu-bar icon.
enum MenuBarState: Equatable, Sendable {
    /// Engine off: audio goes straight to the speakers.
    case stopped
    case starting
    /// Running with the EQ on.
    case active
    /// Running with the EQ off (original sound through RoomEQ).
    case bypassed
    /// Stopped because of an error (`lastError`).
    case failed
}
