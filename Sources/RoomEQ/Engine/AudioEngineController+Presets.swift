// Presets and per-output presets (stage 4). Logic in RoomEQCore
// (Presets.swift); here it is applied to the engine and saved.
//
// Applying a preset only replaces the working bands/preamp: they reach the
// audio thread like any edit, so every band ramps (30 ms, click-free).
// Editing after applying marks the preset modified; nothing is saved into
// a preset unless the user asks (`saveCurrentToActivePreset`). The working
// state itself is always persisted.

import Foundation
import RoomEQCore

extension AudioEngineController {
    // MARK: Presets — state

    /// All presets, in display order (at least one).
    var presets: [EQPreset] { settings.presets }
    /// The preset the working state comes from (nil after deleting it).
    var activePresetID: UUID? { settings.activePresetID }
    var activePreset: EQPreset? { settings.activePreset }
    /// The working bands/preamp differ from the active preset (band IDs
    /// ignored). False when no preset is active.
    var isActivePresetModified: Bool { settings.isActivePresetModified }

    // MARK: Presets — actions (errors: `PresetError`, Italian messages)

    /// Loads a preset (replaces unsaved edits: ask the user first if
    /// `isActivePresetModified`). Click-free. EQ on/off is not touched.
    func applyPreset(id: UUID) throws {
        try settings.applyPreset(id: id)
        lastAutomaticPresetSwitch = nil
        bandsChanged()
    }

    /// Saves the working state as a new preset (validated name) and makes
    /// it active.
    @discardableResult
    func saveCurrentAsNewPreset(name: String) throws -> EQPreset {
        let preset = try settings.saveCurrentAsNewPreset(name: name)
        saveSettings()
        return preset
    }

    /// Overwrites the active preset with the working state.
    func saveCurrentToActivePreset() throws {
        try settings.saveCurrentToActivePreset()
        saveSettings()
    }

    /// Renames (trimmed, non-empty, at most 40 characters, unique ignoring
    /// case and accents).
    func renamePreset(id: UUID, name: String) throws {
        try settings.renamePreset(id: id, name: name)
        saveSettings()
    }

    /// Deletes a preset (never the last). Deleting the active one leaves
    /// the sound unchanged with no active preset; its output assignments
    /// are removed.
    func deletePreset(id: UUID) throws {
        try settings.deletePreset(id: id)
        saveSettings()
    }

    /// Copy named "<name> copia" placed after the original; not activated.
    @discardableResult
    func duplicatePreset(id: UUID) throws -> EQPreset {
        let copy = try settings.duplicatePreset(id: id)
        saveSettings()
        return copy
    }

    /// Italian error for a proposed name (live validation in a text field),
    /// nil if valid. `excluding`: the preset being renamed.
    func presetNameError(_ name: String, excluding id: UUID? = nil) -> String? {
        do {
            _ = try settings.validatedPresetName(name, excluding: id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Per-output presets

    /// Option (default off): when the macOS output changes to a device with
    /// an assigned preset, apply it automatically (see `outputDidChange` in
    /// RoomEQCore: unsaved edits are remembered per output and restored when
    /// coming back). Takes effect at the next output change.
    var isPresetPerOutputEnabled: Bool { settings.isPresetPerOutputEnabled }
    /// Device UID -> preset ID.
    var presetAssignments: [String: UUID] { settings.presetAssignments }

    func setPresetPerOutputEnabled(_ enabled: Bool) {
        guard enabled != settings.isPresetPerOutputEnabled else { return }
        settings.isPresetPerOutputEnabled = enabled
        // Start tracking from the current output.
        settings.lastOutputDeviceUID = systemOutputDevice?.uid ?? settings.lastOutputDeviceUID
        saveSettings()
    }

    func assignPreset(id: UUID, toDeviceUID uid: String) throws {
        try settings.assignPreset(id: id, toDeviceUID: uid)
        saveSettings()
    }

    func clearAssignment(deviceUID uid: String) {
        guard settings.presetAssignments[uid] != nil else { return }
        settings.clearAssignment(deviceUID: uid)
        saveSettings()
    }

    /// Outputs to show in the assignment list: every connected output, plus
    /// remembered ones (with an assignment or remembered edits) that are not
    /// connected. Connected first, then by name.
    var knownOutputs: [KnownOutput] {
        let connected = Set(outputDevices.map(\.uid))
        var uids = outputDevices.map(\.uid)
        for uid in Set(settings.presetAssignments.keys).union(settings.editsByDevice.keys) where !connected.contains(uid) {
            uids.append(uid)
        }
        let existing = Set(settings.presets.map(\.id))
        return uids.map { uid in
            KnownOutput(
                uid: uid,
                name: outputDevices.first { $0.uid == uid }?.name ?? settings.deviceNames[uid] ?? uid,
                isConnected: connected.contains(uid),
                assignedPresetID: settings.presetAssignments[uid].flatMap { existing.contains($0) ? $0 : nil },
                hasRememberedEdits: settings.editsByDevice[uid] != nil)
        }
        .sorted { ($0.isConnected ? 0 : 1, $0.name.lowercased()) < ($1.isConnected ? 0 : 1, $1.name.lowercased()) }
    }

    /// Controller-internal: called with every device-list refresh.
    func rememberDeviceNames(_ devices: [OutputDeviceInfo]) {
        var changed = false
        for device in devices where settings.deviceNames[device.uid] != device.name {
            settings.deviceNames[device.uid] = device.name
            changed = true
        }
        if changed { saveSettings() }
    }

    /// Controller-internal: the macOS default output may have changed
    /// (also at launch). Applies the per-output rules before the engine
    /// follows the new output.
    func applyPresetForOutput(_ output: OutputDeviceInfo?) {
        guard let output, output.uid != settings.lastOutputDeviceUID else { return }
        let outcome = settings.outputDidChange(to: output.uid)
        switch outcome {
        case .unchanged:
            saveSettings()  // lastOutputDeviceUID
        case .appliedPreset(let id):
            let name = settings.presets.first { $0.id == id }?.name ?? "?"
            lastAutomaticPresetSwitch = "Uscita «\(output.name)»: applicato il preset «\(name)»"
            Log.app.info("Per-output preset applied for \(output.uid, privacy: .public)")
            bandsChanged()
        case .restoredEdits(let presetID):
            let name = presetID.flatMap { id in settings.presets.first { $0.id == id }?.name }
            lastAutomaticPresetSwitch = name.map { "Uscita «\(output.name)»: ripristinate le modifiche non salvate a «\($0)»" }
                ?? "Uscita «\(output.name)»: ripristinate le modifiche non salvate"
            Log.app.info("Per-output edits restored for \(output.uid, privacy: .public)")
            bandsChanged()
        }
    }

    // MARK: Output device

    /// Output devices for the output menu (aggregates excluded; virtual
    /// devices included with transport "Virtuale"), with the default marked.
    var outputDeviceOptions: [OutputDeviceOption] {
        outputDevices.map {
            OutputDeviceOption(
                uid: $0.uid, name: $0.name, transportName: $0.transportName, outputChannelCount: $0.outputChannelCount,
                nominalSampleRate: $0.nominalSampleRate, isDefault: $0.uid == systemOutputDevice?.uid)
        }
    }

    /// Makes `uid` the macOS default output (an explicit user choice: it
    /// changes the output for every app). The alert/sound-effects output is
    /// moved too only if it was the same device as the default output
    /// before. RoomEQ then follows the new output (engine restart if
    /// running). Errors in `lastSettingsError`.
    func setSystemOutputDevice(uid: String) {
        guard let device = outputDevices.first(where: { $0.uid == uid }) else {
            lastSettingsError = "Dispositivo di uscita non trovato"
            return
        }
        guard uid != systemOutputDevice?.uid, !isChangingOutputDevice else { return }
        isChangingOutputDevice = true
        lastSettingsError = nil
        deviceQueue.async { [weak self] in
            var message: String?
            do {
                try AudioDevices.setDefaultOutputDevice(device.objectID)
            } catch {
                message = "Impossibile usare «\(device.name)» come uscita di macOS: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isChangingOutputDevice = false
                    if let message { self.lastSettingsError = message }
                    self.refreshDevices()  // the default-output listener refreshes too
                }
            }
        }
    }

    // MARK: Sample rate

    /// The output device's current rate: the running session's, else the
    /// macOS default output's nominal rate.
    var currentSampleRate: Double? { isRunning ? sampleRate : systemOutputDevice?.nominalSampleRate }

    /// Sets the nominal sample rate of the macOS default output (explicit
    /// user action only; RoomEQ never changes it by itself). WARNING for the
    /// UI: this changes the rate for EVERY app using that device, Ableton
    /// included. RoomEQ never converts rates: the running engine rebuilds
    /// at the new rate (tap, device and capture all follow), the filters are
    /// recomputed. Errors (device refuses / doesn't switch) in
    /// `lastSettingsError`.
    func setDeviceSampleRate(_ rate: Double) {
        guard let device = systemOutputDevice else {
            lastSettingsError = "Nessun dispositivo di uscita di macOS disponibile"
            return
        }
        guard availableSampleRates.contains(rate) else {
            lastSettingsError = "«\(device.name)» non offre \(AudioFormatText.kilohertz(rate))"
            return
        }
        guard rate != currentSampleRate, !isChangingSampleRate else { return }
        isChangingSampleRate = true
        lastSettingsError = nil
        userSampleRateChangeDate = Date()
        deviceQueue.async { [weak self] in
            var message: String?
            do {
                try AudioDevices.setNominalSampleRate(rate, of: device.objectID)
                // The change is asynchronous in the HAL: wait (max 2 s).
                var reached = false
                for _ in 0..<40 {
                    if (try? AudioDevices.nominalSampleRate(of: device.objectID)) == rate {
                        reached = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if !reached { message = "«\(device.name)» non è passato a \(AudioFormatText.kilohertz(rate))" }
            } catch {
                message = "«\(device.name)» non accetta \(AudioFormatText.kilohertz(rate)): \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isChangingSampleRate = false
                    if let message { self.lastSettingsError = message }
                    self.userSampleRateChangeDate = Date()
                    self.refreshDevices { [weak self] in
                        // Normally the session's own listener has already
                        // asked for the rebuild; make sure it happens.
                        guard let self, self.state == .running, self.sampleRate != rate, message == nil else { return }
                        self.restartIfActive(reason: "frequenza \(AudioFormatText.kilohertz(rate))")
                    }
                }
            }
        }
    }
}
