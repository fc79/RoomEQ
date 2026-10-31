// Apps excluded from the tap (stage 4). Rules in RoomEQCore (Exclusions.swift).
//
// Applying a change to a running engine:
//   * ADDING an app: live, by updating the tap description (the same
//     mechanism used since stage 2 for excluded apps started after the tap,
//     verified on hardware). If that fails: engine restart.
//   * REMOVING an app: engine restart (about 1 s of silence). Removing a
//     process from a live tap's exclusion list is not verified on hardware
//     yet, so the safe path is used. To try the live path:
//     `defaults write com.federicociapi.RoomEQ LiveExclusionRemoval -bool YES`
//     (it falls back to a restart if Core Audio refuses).
// Restarts caused by these user actions don't count toward the automatic
// restart limit.

import AppKit
import CoreAudio
import Foundation
import RoomEQCore
import UniformTypeIdentifiers

extension AudioEngineController {
    /// Bundle IDs passed to the engine (RoomEQ's own is added by the tap).
    var excludedBundleIDs: [String] { settings.excludedApps.map(\.bundleID) }

    /// Warnings about the current exclusions (e.g. REW), Italian.
    var exclusionWarnings: [String] { excludedApps.compactMap(\.warning) }

    /// Warning to show BEFORE excluding `bundleID` (REW), nil if none.
    func warningForExcluding(bundleID: String) -> String? { ExclusionRules.warning(forBundleID: bundleID) }

    /// Excludes an app (errors: `ExclusionError`, Italian). Allowed for REW
    /// too (with `warningForExcluding`). Applied live.
    func addExcludedApp(bundleID: String) throws {
        let id = try ExclusionRules.validateNew(bundleID, existing: settings.excludedApps, ownBundleID: Self.ownBundleID)
        let name = Self.installedApp(bundleID: id).map { Self.displayName(of: $0) } ?? id
        settings.excludedApps.append(ExcludedAppRecord(bundleID: id, name: name))
        exclusionsChanged(removal: false)
    }

    /// Same, keeping the name of an app picked in Finder / from `candidateApps`.
    func addExcludedApp(_ app: AppInfo) throws {
        let id = try ExclusionRules.validateNew(app.bundleID, existing: settings.excludedApps, ownBundleID: Self.ownBundleID)
        settings.excludedApps.append(ExcludedAppRecord(bundleID: id, name: app.name))
        exclusionsChanged(removal: false)
    }

    /// Stops excluding an app (engine restart if running, see the header).
    func removeExcludedApp(bundleID: String) {
        let before = settings.excludedApps.count
        settings.excludedApps.removeAll { ExclusionRules.same($0.bundleID, bundleID) }
        guard settings.excludedApps.count != before else { return }
        exclusionsChanged(removal: true)
    }

    /// Info about an app picked with NSOpenPanel (an .app bundle), nil if it
    /// has no bundle ID. Does not exclude it: pass it to `addExcludedApp(_:)`.
    func appInfo(forBundleURL url: URL) -> AppInfo? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
        return AppInfo(bundleID: id, name: Self.displayName(of: url), url: url, isRunning: running, isPlayingAudio: false)
    }

    /// Re-reads `candidateApps`: running regular apps (not RoomEQ, not
    /// already excluded), marked when they are playing audio; those first,
    /// then by name. The audio flag is read off the main thread.
    func refreshCandidateApps() {
        let excluded = settings.excludedApps.map(\.bundleID)
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> (String, String, URL?)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                !ExclusionRules.isOwn(id, ownBundleID: Self.ownBundleID),
                !excluded.contains(where: { ExclusionRules.same($0, id) })
            else { return nil }
            return (id, app.localizedName ?? id, app.bundleURL)
        }
        deviceQueue.async { [weak self] in
            let playing = Self.bundleIDsPlayingAudio()
            let apps = running.map { id, name, url in
                AppInfo(
                    bundleID: id, name: name, url: url, isRunning: true,
                    isPlayingAudio: playing.contains { AudioProcesses.bundleID($0, matches: id) })
            }
            .sorted { ($0.isPlayingAudio ? 0 : 1, $0.name.lowercased()) < ($1.isPlayingAudio ? 0 : 1, $1.name.lowercased()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.candidateApps = apps }
            }
        }
    }

    /// App icon for display (generic icon if the app is not installed).
    func icon(forBundleID bundleID: String) -> NSImage {
        if let url = Self.installedApp(bundleID: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    // MARK: Controller-internal

    /// Rebuilds `excludedApps` (display names, install state, warnings).
    func refreshExcludedApps() {
        let apps = settings.excludedApps.map { record in
            let url = Self.installedApp(bundleID: record.bundleID)
            return ExcludedApp(
                bundleID: record.bundleID, name: url.map { Self.displayName(of: $0) } ?? record.name, url: url,
                warning: ExclusionRules.warning(forBundleID: record.bundleID))
        }
        if apps != excludedApps { excludedApps = apps }
    }

    private func exclusionsChanged(removal: Bool) {
        refreshExcludedApps()
        saveSettings()
        switch state {
        case .starting:
            restartIfActive(reason: "app escluse")  // the launch in flight has the old list
        case .running:
            let live = !removal || UserDefaults.standard.bool(forKey: "LiveExclusionRemoval")
            guard live, let sessionID = activeSessionID else {
                restartIfActive(reason: "app escluse")
                return
            }
            engine.updateExclusions(sessionID: sessionID, bundleIDs: excludedBundleIDs) { [weak self] error in
                guard let self, error != nil, self.activeSessionID == sessionID else { return }
                self.restartIfActive(reason: "app escluse")
            }
        case .stopped, .stopping, .failed:
            break
        }
    }

    private static func installedApp(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static func displayName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Bundle IDs of processes currently sending audio to an output.
    nonisolated private static func bundleIDsPlayingAudio() -> [String] {
        let processes = (try? AudioProcesses.processObjectIDs()) ?? []
        return processes.compactMap { process in
            let running: UInt32? = try? AudioObject.read(
                process, AudioObject.address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0),
                "Processo in riproduzione")
            guard running == 1 else { return nil }
            return AudioProcesses.bundleID(of: process)
        }
    }
}
