// Preset operations and the per-output preset logic, as pure mutations of
// `AppSettings` (the controller applies the resulting working state to the
// audio engine, where every band ramps click-free).

import Foundation

/// Preset errors, with Italian messages for the UI.
public enum PresetError: LocalizedError, Equatable, Sendable {
    case emptyName
    case nameTooLong(maximum: Int)
    case duplicateName(String)
    case notFound
    case lastPreset
    case noActivePreset

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Il nome del preset non può essere vuoto."
        case .nameTooLong(let maximum): return "Il nome del preset può avere al massimo \(maximum) caratteri."
        case .duplicateName(let name): return "Esiste già un preset chiamato «\(name)»."
        case .notFound: return "Preset non trovato."
        case .lastPreset: return "Non puoi eliminare l'unico preset rimasto."
        case .noActivePreset: return "Nessun preset attivo in cui salvare: salva come nuovo preset."
        }
    }
}

/// Preset name rules.
public enum PresetNames {
    public static let maximumLength = 40

    /// Whitespace and newlines removed at both ends, inner runs of
    /// whitespace collapsed to one space.
    public static func trimmed(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Same name for the user: case and accents ignored ("Studio" == "studio").
    public static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT")) == .orderedSame
    }

    /// `name`, or "name 2", "name 3"… if already taken; the result never
    /// exceeds `maximumLength` (the base is shortened to make room).
    public static func unique(_ name: String, among names: [String]) -> String {
        let name = String(name.prefix(maximumLength))
        guard names.contains(where: { same($0, name) }) else { return name }
        var number = 2
        func candidate(_ number: Int) -> String {
            let suffix = " \(number)"
            let base = String(name.prefix(maximumLength - suffix.count)).trimmingCharacters(in: .whitespaces)
            return base + suffix
        }
        while names.contains(where: { same($0, candidate(number)) }) { number += 1 }
        return candidate(number)
    }

    /// Default name for saving without asking ("Senza nome", "Senza nome 2"…).
    public static let untitled = "Senza nome"
}

extension AppSettings {
    // MARK: Queries

    public var activePreset: EQPreset? { presets.first { $0.id == activePresetID } }

    /// True when the working bands/preamp differ from the active preset
    /// (band IDs are ignored: only what you hear counts). False when no
    /// preset is active.
    public var isActivePresetModified: Bool {
        guard let preset = activePreset else { return false }
        return !Self.sameSound(preset.bands, preset.preampDecibels, bands, preampDecibels)
    }

    static func sameSound(_ a: [EQBand], _ preampA: Double, _ b: [EQBand], _ preampB: Double) -> Bool {
        guard preampA == preampB, a.count == b.count else { return false }
        return zip(a, b).allSatisfy {
            $0.frequency == $1.frequency && $0.gain == $1.gain && $0.q == $1.q && $0.isEnabled == $1.isEnabled
        }
    }

    /// True when replacing the working state would lose sound that exists
    /// nowhere else: it differs from the active preset, or there is no
    /// active preset and it matches none of the presets (e.g. after
    /// deleting the active one). The UI must ask before replacing it.
    public var hasUnsavedChanges: Bool {
        if activePreset != nil { return isActivePresetModified }
        return !presets.contains { Self.sameSound($0.bands, $0.preampDecibels, bands, preampDecibels) }
    }

    /// A free name for saving the working state without asking for one.
    public var suggestedNewPresetName: String {
        PresetNames.unique(PresetNames.untitled, among: presets.map(\.name))
    }

    /// The validated, trimmed name, unique among the presets except `excluding`.
    public func validatedPresetName(_ name: String, excluding id: UUID? = nil) throws -> String {
        let clean = PresetNames.trimmed(name)
        guard !clean.isEmpty else { throw PresetError.emptyName }
        guard clean.count <= PresetNames.maximumLength else {
            throw PresetError.nameTooLong(maximum: PresetNames.maximumLength)
        }
        if let other = presets.first(where: { $0.id != id && PresetNames.same($0.name, clean) }) {
            throw PresetError.duplicateName(other.name)
        }
        return clean
    }

    // MARK: Operations

    /// Working state = the preset (replaces unsaved edits); it becomes active.
    public mutating func applyPreset(id: UUID) throws {
        guard let preset = presets.first(where: { $0.id == id }) else { throw PresetError.notFound }
        bands = preset.bands
        preampDecibels = preset.preampDecibels
        activePresetID = id
    }

    /// Saves the working state as a new preset, which becomes active.
    @discardableResult
    public mutating func saveCurrentAsNewPreset(name: String) throws -> EQPreset {
        let preset = EQPreset(name: try validatedPresetName(name), bands: bands, preampDecibels: preampDecibels)
        presets.append(preset)
        activePresetID = preset.id
        return preset
    }

    /// Overwrites the active preset with the working state.
    public mutating func saveCurrentToActivePreset() throws {
        guard let index = presets.firstIndex(where: { $0.id == activePresetID }) else {
            throw PresetError.noActivePreset
        }
        presets[index].bands = bands
        presets[index].preampDecibels = preampDecibels
    }

    public mutating func renamePreset(id: UUID, name: String) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
        presets[index].name = try validatedPresetName(name, excluding: id)
    }

    /// Deletes a preset (never the last one) and its output assignments.
    /// Remembered edits based on it are KEPT (their base is cleared).
    /// Deleting the ACTIVE preset leaves the working state (what is playing)
    /// unchanged, with no active preset: `hasUnsavedChanges` is then true.
    public mutating func deletePreset(id: UUID) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
        guard presets.count > 1 else { throw PresetError.lastPreset }
        presets.remove(at: index)
        if activePresetID == id { activePresetID = nil }
        presetAssignments = presetAssignments.filter { $0.value != id }
        for (uid, edits) in editsByDevice where edits.presetID == id { editsByDevice[uid]?.presetID = nil }
        pruneDeviceNames()
    }

    /// A copy named "<name> copia" (then "copia 2"…), right after the
    /// original. Not activated. Same band IDs: switching between the two
    /// morphs each band instead of fading bands out and in.
    @discardableResult
    public mutating func duplicatePreset(id: UUID) throws -> EQPreset {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
        var copy = presets[index]
        copy.id = UUID()
        copy.name = PresetNames.unique("\(copy.name) copia", among: presets.map(\.name))
        presets.insert(copy, at: index + 1)
        return copy
    }

    // MARK: Per-output presets

    public mutating func assignPreset(id: UUID, toDeviceUID uid: String) throws {
        guard presets.contains(where: { $0.id == id }) else { throw PresetError.notFound }
        guard !uid.isEmpty else { return }
        presetAssignments[uid] = id
    }

    public mutating func clearAssignment(deviceUID uid: String) {
        presetAssignments[uid] = nil
        pruneDeviceNames()
    }

    /// What `outputDidChange` did to the working state.
    public enum OutputSwitch: Equatable, Sendable {
        /// Working state untouched.
        case unchanged
        /// The new output's assigned preset was applied.
        case appliedPreset(UUID)
        /// Edits previously made on the new output were restored.
        /// `presetID`: their base (now active); `assignedPresetID`: the
        /// output's assignment when it differs from that base (the user may
        /// want to apply it), else nil.
        case restoredEdits(presetID: UUID?, assignedPresetID: UUID?)
    }

    /// Call whenever the macOS default output may have changed (also at
    /// launch). Records the new output; with per-output presets enabled:
    ///   * the working state is replaced ONLY when the new output has edits
    ///     remembered (they are restored) or an assignment (its preset is
    ///     applied);
    ///   * remembered edits always win over the assignment (user work is
    ///     never discarded automatically), even if they were based on
    ///     another preset than the one assigned now;
    ///   * whenever the working state is replaced and has unsaved changes,
    ///     they are remembered for the output being left and restored when
    ///     that output comes back: an automatic switch never loses work.
    public mutating func outputDidChange(to uid: String?) -> OutputSwitch {
        let previous = lastOutputDeviceUID
        guard let uid, uid != previous else { return .unchanged }
        lastOutputDeviceUID = uid
        guard isPresetPerOutputEnabled else { return .unchanged }

        let assigned = presetAssignments[uid].flatMap { id in presets.contains { $0.id == id } ? id : nil }
        let restore = editsByDevice[uid]
        guard assigned != nil || restore != nil else { return .unchanged }

        // About to replace the working state: keep its unsaved changes.
        if let previous {
            if hasUnsavedChanges {
                editsByDevice[previous] = DeviceEdits(presetID: activePresetID, bands: bands, preampDecibels: preampDecibels)
            } else {
                editsByDevice[previous] = nil
            }
        }
        editsByDevice[uid] = nil
        pruneDeviceNames()
        if let restore {
            bands = restore.bands
            preampDecibels = restore.preampDecibels
            activePresetID = restore.presetID.flatMap { id in presets.contains { $0.id == id } ? id : nil }
            return .restoredEdits(presetID: activePresetID, assignedPresetID: assigned == activePresetID ? nil : assigned)
        }
        guard let assigned, (try? applyPreset(id: assigned)) != nil else { return .unchanged }
        return .appliedPreset(assigned)
    }
}
