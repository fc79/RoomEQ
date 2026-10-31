// Everything RoomEQ persists (stage 4), in one versioned JSON document.
//
// Contents: the working EQ state (bands, preamp, EQ on/off), the presets,
// per-output preset assignments (+ remembered device names and unsaved
// edits per device), excluded apps, auto-start. The login item is NOT here:
// macOS (SMAppService) is its source of truth.
//
// Same philosophy as stage 3 (EQSettings.swift): loading is LOSSY and
// forward-compatible. Every field is read on its own; a field that is
// present but unreadable is replaced by its default with a warning; every
// band, preset, assignment… is read on its own and skipped if unusable;
// newer versions are read for the fields this version knows. Whenever
// something could not be read, the raw data is handed back for a backup
// (`AppSettingsLoad.backups`) BEFORE anything saves over it.
//
// Migration: without a stage-4 document, the stage-3 "EQSettings" document
// is read (lossy, as in stage 3) and becomes the working state AND the
// preset "Studio" (so nothing is marked modified). The stage-3 key is left
// untouched (a free backup).

import Foundation

/// A named EQ setting. EQ on/off is NOT part of a preset (it stays global).
public struct EQPreset: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var bands: [EQBand]
    public var preampDecibels: Double

    public init(id: UUID = UUID(), name: String, bands: [EQBand], preampDecibels: Double) {
        self.id = id
        self.name = name
        self.bands = bands
        self.preampDecibels = preampDecibels
    }
}

/// Unsaved edits remembered for one output device (see `outputDidChange`).
public struct DeviceEdits: Codable, Sendable, Equatable {
    /// Preset the edits were based on (nil = none).
    public var presetID: UUID?
    public var bands: [EQBand]
    public var preampDecibels: Double

    public init(presetID: UUID?, bands: [EQBand], preampDecibels: Double) {
        self.presetID = presetID
        self.bands = bands
        self.preampDecibels = preampDecibels
    }
}

/// An excluded app as stored: bundle ID + last known name (shown even when
/// the app is not installed).
public struct ExcludedAppRecord: Codable, Sendable, Equatable, Hashable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 2
    /// UserDefaults key of this document.
    public static let storageKey = "RoomEQSettings"
    /// Name of the preset created at first launch / migration.
    public static let firstPresetName = "Studio"

    public var version: Int

    // Working state (what is playing).
    public var bands: [EQBand]
    public var preampDecibels: Double
    public var isEQEnabled: Bool

    // Presets.
    public var presets: [EQPreset]
    /// Preset the working state comes from (nil after deleting it).
    public var activePresetID: UUID?

    // Per-output presets.
    public var isPresetPerOutputEnabled: Bool
    /// Output device UID -> preset ID.
    public var presetAssignments: [String: UUID]
    /// Output device UID -> last known name (for devices not connected).
    public var deviceNames: [String: String]
    /// Output device UID -> unsaved edits made on it, stashed when an
    /// automatic preset switch replaced them.
    public var editsByDevice: [String: DeviceEdits]
    /// The macOS default output last seen (to detect changes, also across launches).
    public var lastOutputDeviceUID: String?

    // Exclusions (RoomEQ itself is always excluded in addition, never listed).
    public var excludedApps: [ExcludedAppRecord]

    // Launch.
    public var autoStartEngineOnLaunch: Bool

    public init(
        bands: [EQBand], preampDecibels: Double, isEQEnabled: Bool, presets: [EQPreset], activePresetID: UUID?,
        isPresetPerOutputEnabled: Bool = false, presetAssignments: [String: UUID] = [:],
        deviceNames: [String: String] = [:], editsByDevice: [String: DeviceEdits] = [:],
        lastOutputDeviceUID: String? = nil, excludedApps: [ExcludedAppRecord] = ExclusionRules.defaultApps,
        autoStartEngineOnLaunch: Bool = false
    ) {
        version = Self.currentVersion
        self.bands = bands
        self.preampDecibels = preampDecibels
        self.isEQEnabled = isEQEnabled
        self.presets = presets
        self.activePresetID = activePresetID
        self.isPresetPerOutputEnabled = isPresetPerOutputEnabled
        self.presetAssignments = presetAssignments
        self.deviceNames = deviceNames
        self.editsByDevice = editsByDevice
        self.lastOutputDeviceUID = lastOutputDeviceUID
        self.excludedApps = excludedApps
        self.autoStartEngineOnLaunch = autoStartEngineOnLaunch
    }

    /// First launch: the user's REW filters, also saved as preset "Studio".
    public static func defaults() -> AppSettings {
        migrating(EQSettings.defaults())
    }

    /// Stage-3 settings -> stage 4: working state = the old settings, and
    /// the same bands/preamp as preset "Studio" (active, not modified).
    public static func migrating(_ old: EQSettings) -> AppSettings {
        let preset = EQPreset(name: firstPresetName, bands: old.bands, preampDecibels: old.preampDecibels)
        return AppSettings(
            bands: old.bands, preampDecibels: old.preampDecibels, isEQEnabled: old.isEQEnabled, presets: [preset],
            activePresetID: preset.id)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: Sanitising

    /// The settings made consistent and safe: bands limited/finite/unique
    /// (working state, presets, remembered edits), preamps in range, at
    /// least one preset, unique preset IDs and names, references only to
    /// existing presets, a clean exclusion list without RoomEQ itself.
    public func sanitized(ownBundleID: String) -> AppSettings {
        func clean(_ bands: [EQBand], _ preamp: Double) -> (bands: [EQBand], preamp: Double) {
            let settings = EQSettings(bands: bands, preampDecibels: preamp, isEQEnabled: true).sanitized()
            return (settings.bands, settings.preampDecibels)
        }
        var result = self
        result.version = Self.currentVersion
        (result.bands, result.preampDecibels) = clean(bands, preampDecibels)

        var ids = Set<UUID>()
        var names: [String] = []
        var cleanPresets: [EQPreset] = []
        for var preset in presets {
            if ids.contains(preset.id) { preset.id = UUID() }
            ids.insert(preset.id)
            (preset.bands, preset.preampDecibels) = clean(preset.bands, preset.preampDecibels)
            var name = PresetNames.trimmed(preset.name)
            if name.isEmpty { name = "Preset" }
            name = PresetNames.unique(String(name.prefix(PresetNames.maximumLength)), among: names)
            names.append(name)
            preset.name = name
            cleanPresets.append(preset)
        }
        if cleanPresets.isEmpty {
            let preset = EQPreset(name: Self.firstPresetName, bands: result.bands, preampDecibels: result.preampDecibels)
            cleanPresets = [preset]
            result.activePresetID = preset.id
        }
        result.presets = cleanPresets
        let existing = Set(cleanPresets.map(\.id))
        if let active = result.activePresetID, !existing.contains(active) { result.activePresetID = nil }
        result.presetAssignments = presetAssignments.filter { !$0.key.isEmpty && existing.contains($0.value) }
        result.editsByDevice = [:]
        for (uid, var edits) in editsByDevice where !uid.isEmpty {
            if let preset = edits.presetID, !existing.contains(preset) { continue }
            (edits.bands, edits.preampDecibels) = clean(edits.bands, edits.preampDecibels)
            result.editsByDevice[uid] = edits
        }
        result.deviceNames = deviceNames.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        if result.lastOutputDeviceUID?.isEmpty == true { result.lastOutputDeviceUID = nil }
        result.excludedApps = ExclusionRules.cleaned(excludedApps, ownBundleID: ownBundleID)
        return result
    }

    // MARK: Loading

    /// Reads the stored document (`current`, stage 4) or migrates the
    /// stage-3 one (`legacy`), as far as possible. Never fails.
    public static func load(current: Data?, legacy: Data?, ownBundleID: String) -> AppSettingsLoad {
        var backups: [AppSettingsLoad.Backup] = []
        var warnings: [String] = []
        let partialNotice =
            "Parte delle impostazioni salvate non era leggibile: ne ho conservato una copia e ho caricato il resto."

        if let current {
            if let (settings, problems) = decodeLeniently(current) {
                if !problems.isEmpty { backups.append(.init(sourceKey: storageKey, data: current)) }
                return AppSettingsLoad(
                    settings: settings.sanitized(ownBundleID: ownBundleID), warnings: problems, backups: backups,
                    notice: problems.isEmpty ? nil : partialNotice, migrated: false)
            }
            // Unreadable: keep it, then fall back to the stage-3 document.
            backups.append(.init(sourceKey: storageKey, data: current))
            warnings.append("Impostazioni salvate illeggibili")
        }

        if let legacy {
            let loaded = EQSettings.load(legacy)
            if loaded.needsBackup { backups.append(.init(sourceKey: EQSettings.storageKey, data: legacy)) }
            warnings += loaded.warnings
            var notice: String?
            if current != nil {
                notice = loaded.status == .unreadable
                    ? "Le impostazioni salvate non erano leggibili: ne ho conservato una copia e ho caricato i filtri iniziali."
                    : "Le impostazioni salvate non erano leggibili: ne ho conservato una copia e ho recuperato i filtri della versione precedente."
            } else if loaded.status == .unreadable {
                notice = "Le impostazioni salvate non erano leggibili: ne ho conservato una copia e ho caricato i filtri iniziali."
            } else if loaded.status == .partial {
                notice = partialNotice
            }
            return AppSettingsLoad(
                settings: migrating(loaded.settings).sanitized(ownBundleID: ownBundleID), warnings: warnings,
                backups: backups, notice: notice, migrated: true)
        }

        return AppSettingsLoad(
            settings: defaults().sanitized(ownBundleID: ownBundleID), warnings: warnings, backups: backups,
            notice: current == nil
                ? nil
                : "Le impostazioni salvate non erano leggibili: ne ho conservato una copia e ho caricato i filtri iniziali.",
            migrated: false)
    }

    /// Nil if `data` is not a settings object at all; otherwise the settings
    /// and what could not be read.
    static func decodeLeniently(_ data: Data) -> (AppSettings, [String])? {
        guard let stored = try? JSONDecoder().decode(StoredAppSettings.self, from: data) else { return nil }
        var settings = AppSettings.defaults()
        var problems = stored.problems
        if let version = stored.version, version > currentVersion {
            problems.insert("Impostazioni salvate in un formato più recente (versione \(version)): letti i campi noti", at: 0)
        }
        if let bands = stored.bands { settings.bands = bands }
        if let preamp = stored.preampDecibels { settings.preampDecibels = preamp }
        if let enabled = stored.isEQEnabled { settings.isEQEnabled = enabled }
        if let presets = stored.presets {
            settings.presets = presets
            settings.activePresetID = stored.activePresetID
        } else {
            // No readable presets: the working state becomes "Studio" again.
            settings.presets = [EQPreset(name: firstPresetName, bands: settings.bands, preampDecibels: settings.preampDecibels)]
            settings.activePresetID = settings.presets[0].id
        }
        if let value = stored.isPresetPerOutputEnabled { settings.isPresetPerOutputEnabled = value }
        if let value = stored.presetAssignments { settings.presetAssignments = value }
        if let value = stored.deviceNames { settings.deviceNames = value }
        if let value = stored.editsByDevice { settings.editsByDevice = value }
        settings.lastOutputDeviceUID = stored.lastOutputDeviceUID
        if let value = stored.excludedApps { settings.excludedApps = value }
        if let value = stored.autoStartEngineOnLaunch { settings.autoStartEngineOnLaunch = value }
        return (settings, problems)
    }
}

/// Outcome of `AppSettings.load`.
public struct AppSettingsLoad: Sendable {
    public struct Backup: Sendable, Equatable {
        /// Key the data was read from ("RoomEQSettings" or "EQSettings").
        public var sourceKey: String
        public var data: Data
    }

    public var settings: AppSettings
    /// What could not be read (Italian, for the log).
    public var warnings: [String]
    /// Raw data to keep before anything saves over it.
    public var backups: [Backup]
    /// Italian notice for the UI (nil when everything was read).
    public var notice: String?
    /// True when the stage-3 document was converted.
    public var migrated: Bool
}

// MARK: - Lenient decoding

/// Every field optional and read on its own. `problems` lists fields that
/// were PRESENT but unreadable, and elements that were skipped (absent
/// fields are not a problem: there is nothing to lose).
private struct StoredAppSettings: Decodable {
    var version: Int?
    var bands: [EQBand]?
    var preampDecibels: Double?
    var isEQEnabled: Bool?
    var presets: [EQPreset]?
    var activePresetID: UUID?
    var isPresetPerOutputEnabled: Bool?
    var presetAssignments: [String: UUID]?
    var deviceNames: [String: String]?
    var editsByDevice: [String: DeviceEdits]?
    var lastOutputDeviceUID: String?
    var excludedApps: [ExcludedAppRecord]?
    var autoStartEngineOnLaunch: Bool?
    var problems: [String] = []

    enum CodingKeys: String, CodingKey {
        case version, bands, preampDecibels, isEQEnabled, presets, activePresetID, isPresetPerOutputEnabled
        case presetAssignments, deviceNames, editsByDevice, lastOutputDeviceUID, excludedApps
        case autoStartEngineOnLaunch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)  // must be an object
        var problems: [String] = []
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ label: String) -> T? {
            guard c.contains(key) else { return nil }
            if (try? c.decodeNil(forKey: key)) == true { return nil }
            guard let value = try? c.decode(T.self, forKey: key) else {
                problems.append("\(label) illeggibile")
                return nil
            }
            return value
        }
        version = field(Int.self, .version, "Versione")
        if let list = field([LenientBand].self, .bands, "Elenco dei filtri") {
            bands = list.compactMap(\.band)
            if bands!.count < list.count { problems.append("\(list.count - bands!.count) filtri illeggibili ignorati") }
        }
        preampDecibels = field(Double.self, .preampDecibels, "Preamp")
        isEQEnabled = field(Bool.self, .isEQEnabled, "Stato EQ")
        if let list = field([LenientPreset].self, .presets, "Elenco dei preset") {
            presets = list.compactMap(\.preset)
            if presets!.count < list.count { problems.append("\(list.count - presets!.count) preset illeggibili ignorati") }
            problems += list.flatMap(\.problems)
            if presets!.isEmpty { presets = nil }
        }
        if let text = field(String.self, .activePresetID, "Preset attivo") { activePresetID = UUID(uuidString: text) }
        isPresetPerOutputEnabled = field(Bool.self, .isPresetPerOutputEnabled, "Opzione preset per uscita")
        if let raw = field([String: String].self, .presetAssignments, "Associazioni preset-uscita") {
            presetAssignments = raw.compactMapValues(UUID.init(uuidString:))
            if presetAssignments!.count < raw.count { problems.append("Associazioni preset-uscita illeggibili ignorate") }
        }
        deviceNames = field([String: String].self, .deviceNames, "Nomi delle uscite")
        if let raw = field([String: LenientEdits].self, .editsByDevice, "Modifiche per uscita") {
            editsByDevice = raw.compactMapValues(\.edits)
            if editsByDevice!.count < raw.count { problems.append("Modifiche per uscita illeggibili ignorate") }
        }
        lastOutputDeviceUID = field(String.self, .lastOutputDeviceUID, "Ultima uscita")
        if let list = field([LenientExcludedApp].self, .excludedApps, "App escluse") {
            excludedApps = list.compactMap(\.app)
            if excludedApps!.count < list.count { problems.append("App escluse illeggibili ignorate") }
        }
        autoStartEngineOnLaunch = field(Bool.self, .autoStartEngineOnLaunch, "Avvio automatico")
        self.problems = problems
    }
}

/// One preset; never throws. Unreadable bands are skipped (reported).
private struct LenientPreset: Decodable {
    let preset: EQPreset?
    var problems: [String] = []

    enum CodingKeys: String, CodingKey { case id, name, bands, preampDecibels }

    init(from decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
            let bands = try? c.decode([LenientBand].self, forKey: .bands)
        else {
            preset = nil
            return
        }
        let id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        let name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "Preset"
        let preamp = ((try? c.decodeIfPresent(Double.self, forKey: .preampDecibels)) ?? nil) ?? 0
        let readable = bands.compactMap(\.band)
        if readable.count < bands.count {
            problems.append("Preset «\(name)»: \(bands.count - readable.count) filtri illeggibili ignorati")
        }
        preset = EQPreset(id: id, name: name, bands: readable, preampDecibels: preamp)
    }
}

private struct LenientEdits: Decodable {
    let edits: DeviceEdits?

    enum CodingKeys: String, CodingKey { case presetID, bands, preampDecibels }

    init(from decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
            let bands = try? c.decode([LenientBand].self, forKey: .bands)
        else {
            edits = nil
            return
        }
        let preset = (try? c.decodeIfPresent(UUID.self, forKey: .presetID)) ?? nil
        let preamp = ((try? c.decodeIfPresent(Double.self, forKey: .preampDecibels)) ?? nil) ?? 0
        edits = DeviceEdits(presetID: preset, bands: bands.compactMap(\.band), preampDecibels: preamp)
    }
}

private struct LenientExcludedApp: Decodable {
    let app: ExcludedAppRecord?

    enum CodingKeys: String, CodingKey { case bundleID, name }

    init(from decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
            let bundleID = try? c.decode(String.self, forKey: .bundleID)
        else {
            app = nil
            return
        }
        let name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? bundleID
        app = ExcludedAppRecord(bundleID: bundleID, name: name)
    }
}
