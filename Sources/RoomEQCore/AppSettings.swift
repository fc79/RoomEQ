// Everything RoomEQ persists (stage 4), in one versioned JSON document.
//
// Contents: the working EQ state (bands, preamp, EQ on/off), the presets,
// per-output preset assignments and "no correction" outputs (+ remembered
// device names and unsaved edits per device), excluded apps, auto-start, buffer size, output channel
// pair per device. The login item's state is NOT here (macOS, SMAppService,
// is its source of truth); only whether the user ever asked for it.
//
// Limitation: outputs are identified by their Core Audio UID. A device
// whose UID changes (some USB devices when moved to another port) is seen
// as a new output: its assignment and remembered edits stay under the old
// UID until the user assigns again. Remembered names are kept only for
// outputs with an assignment, "no correction" or remembered edits (no
// unbounded growth).
//
// Version 3 adds `noCorrectionOutputs` (version 2 documents read as before,
// with none); an older build reading a version-3 document keeps a backup.
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
    public static let currentVersion = 3
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
    /// Output device UIDs set to "no correction": with per-output presets
    /// on, RoomEQ pauses on them (see `EngineMode`). Never also in
    /// `presetAssignments`.
    public var noCorrectionOutputs: Set<String>
    /// Output device UID -> last known name (for devices not connected).
    public var deviceNames: [String: String]
    /// Output device UID -> unsaved edits made on it, stashed when an
    /// automatic preset switch replaced them.
    public var editsByDevice: [String: DeviceEdits]
    /// The output the working state belongs to (to detect changes, also
    /// across launches): the macOS default output last seen, passing over
    /// outputs with "no correction" while the option is on. It can still be
    /// one with "no correction" (rule set while in use, or option off then).
    public var lastOutputDeviceUID: String?

    // Exclusions (RoomEQ itself is always excluded in addition, never listed).
    public var excludedApps: [ExcludedAppRecord]

    // Launch.
    public var autoStartEngineOnLaunch: Bool
    /// The user has asked for "open at login" at least once (to tell
    /// "never registered" from "registered but not found").
    public var loginItemRequested: Bool

    // Engine.
    /// IO buffer size in frames (default 64).
    public var bufferFrames: Int
    /// Output device UID -> left channel index of the output pair (0 = 1–2).
    public var outputPairs: [String: Int]

    public static let defaultBufferFrames = 64

    public init(
        bands: [EQBand], preampDecibels: Double, isEQEnabled: Bool, presets: [EQPreset], activePresetID: UUID?,
        isPresetPerOutputEnabled: Bool = false, presetAssignments: [String: UUID] = [:],
        noCorrectionOutputs: Set<String> = [], deviceNames: [String: String] = [:], editsByDevice: [String: DeviceEdits] = [:],
        lastOutputDeviceUID: String? = nil, excludedApps: [ExcludedAppRecord] = ExclusionRules.defaultApps,
        autoStartEngineOnLaunch: Bool = false, loginItemRequested: Bool = false,
        bufferFrames: Int = AppSettings.defaultBufferFrames, outputPairs: [String: Int] = [:]
    ) {
        version = Self.currentVersion
        self.bands = bands
        self.preampDecibels = preampDecibels
        self.isEQEnabled = isEQEnabled
        self.presets = presets
        self.activePresetID = activePresetID
        self.isPresetPerOutputEnabled = isPresetPerOutputEnabled
        self.presetAssignments = presetAssignments
        self.noCorrectionOutputs = noCorrectionOutputs
        self.deviceNames = deviceNames
        self.editsByDevice = editsByDevice
        self.lastOutputDeviceUID = lastOutputDeviceUID
        self.excludedApps = excludedApps
        self.autoStartEngineOnLaunch = autoStartEngineOnLaunch
        self.loginItemRequested = loginItemRequested
        self.bufferFrames = bufferFrames
        self.outputPairs = outputPairs
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

    /// Written by hand only so that `noCorrectionOutputs` is a SORTED array
    /// (byte-stable document). Keep in sync with the properties (the
    /// round-trip tests catch a missing one).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(bands, forKey: .bands)
        try c.encode(preampDecibels, forKey: .preampDecibels)
        try c.encode(isEQEnabled, forKey: .isEQEnabled)
        try c.encode(presets, forKey: .presets)
        try c.encodeIfPresent(activePresetID, forKey: .activePresetID)
        try c.encode(isPresetPerOutputEnabled, forKey: .isPresetPerOutputEnabled)
        try c.encode(presetAssignments, forKey: .presetAssignments)
        try c.encode(noCorrectionOutputs.sorted(), forKey: .noCorrectionOutputs)
        try c.encode(deviceNames, forKey: .deviceNames)
        try c.encode(editsByDevice, forKey: .editsByDevice)
        try c.encodeIfPresent(lastOutputDeviceUID, forKey: .lastOutputDeviceUID)
        try c.encode(excludedApps, forKey: .excludedApps)
        try c.encode(autoStartEngineOnLaunch, forKey: .autoStartEngineOnLaunch)
        try c.encode(loginItemRequested, forKey: .loginItemRequested)
        try c.encode(bufferFrames, forKey: .bufferFrames)
        try c.encode(outputPairs, forKey: .outputPairs)
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
        result.noCorrectionOutputs = noCorrectionOutputs.filter { !$0.isEmpty }
        // One rule per output: "no correction" wins over a preset.
        result.presetAssignments = presetAssignments.filter {
            !$0.key.isEmpty && existing.contains($0.value) && !result.noCorrectionOutputs.contains($0.key)
        }
        result.editsByDevice = [:]
        for (uid, var edits) in editsByDevice where !uid.isEmpty {
            // Never drop remembered work: only forget a base that is gone.
            if let preset = edits.presetID, !existing.contains(preset) { edits.presetID = nil }
            (edits.bands, edits.preampDecibels) = clean(edits.bands, edits.preampDecibels)
            result.editsByDevice[uid] = edits
        }
        result.deviceNames = deviceNames.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        result.pruneDeviceNames()
        if !(16...4096).contains(result.bufferFrames) { result.bufferFrames = Self.defaultBufferFrames }
        result.outputPairs = outputPairs.filter { !$0.key.isEmpty && (0...1022).contains($0.value) && $0.value % 2 == 0 }
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
        if let value = stored.noCorrectionOutputs { settings.noCorrectionOutputs = Set(value) }
        if let value = stored.deviceNames { settings.deviceNames = value }
        if let value = stored.editsByDevice { settings.editsByDevice = value }
        settings.lastOutputDeviceUID = stored.lastOutputDeviceUID
        if let value = stored.excludedApps { settings.excludedApps = value }
        if let value = stored.autoStartEngineOnLaunch { settings.autoStartEngineOnLaunch = value }
        if let value = stored.loginItemRequested { settings.loginItemRequested = value }
        if let value = stored.bufferFrames { settings.bufferFrames = value }
        if let value = stored.outputPairs { settings.outputPairs = value }
        return (settings, problems)
    }

    /// Outputs that are listed (and keep their name) even when unplugged:
    /// a preset assignment, "no correction", or remembered edits.
    public var outputsWithRules: Set<String> {
        Set(presetAssignments.keys).union(noCorrectionOutputs).union(editsByDevice.keys)
    }

    /// Keeps remembered device names only for outputs that still need one
    /// (`outputsWithRules`).
    public mutating func pruneDeviceNames() {
        let needed = outputsWithRules
        deviceNames = deviceNames.filter { needed.contains($0.key) }
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
    var noCorrectionOutputs: [String]?
    var deviceNames: [String: String]?
    var editsByDevice: [String: DeviceEdits]?
    var lastOutputDeviceUID: String?
    var excludedApps: [ExcludedAppRecord]?
    var autoStartEngineOnLaunch: Bool?
    var loginItemRequested: Bool?
    var bufferFrames: Int?
    var outputPairs: [String: Int]?
    var problems: [String] = []

    enum CodingKeys: String, CodingKey {
        case version, bands, preampDecibels, isEQEnabled, presets, activePresetID, isPresetPerOutputEnabled
        case presetAssignments, noCorrectionOutputs, deviceNames, editsByDevice, lastOutputDeviceUID, excludedApps
        case autoStartEngineOnLaunch, loginItemRequested, bufferFrames, outputPairs
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
            problems += list.compactMap(\.problem).map { "Filtro: \($0)" }
        }
        preampDecibels = field(Double.self, .preampDecibels, "Preamp")
        isEQEnabled = field(Bool.self, .isEQEnabled, "Stato EQ")
        if let list = field([LenientPreset].self, .presets, "Elenco dei preset") {
            presets = list.compactMap(\.preset)
            if presets!.count < list.count { problems.append("\(list.count - presets!.count) preset illeggibili ignorati") }
            problems += list.flatMap(\.problems)
            if presets!.isEmpty { presets = nil }
        }
        if let text = field(String.self, .activePresetID, "Preset attivo") {
            activePresetID = UUID(uuidString: text)
            if activePresetID == nil { problems.append("Preset attivo illeggibile") }
        }
        isPresetPerOutputEnabled = field(Bool.self, .isPresetPerOutputEnabled, "Opzione preset per uscita")
        if let raw = field([String: String].self, .presetAssignments, "Associazioni preset-uscita") {
            presetAssignments = raw.compactMapValues(UUID.init(uuidString:))
            if presetAssignments!.count < raw.count { problems.append("Associazioni preset-uscita illeggibili ignorate") }
        }
        if let list = field([LenientString].self, .noCorrectionOutputs, "Uscite senza correzione") {
            noCorrectionOutputs = list.compactMap(\.value)
            if noCorrectionOutputs!.count < list.count {
                problems.append("\(list.count - noCorrectionOutputs!.count) uscite senza correzione illeggibili ignorate")
            }
        }
        deviceNames = field([String: String].self, .deviceNames, "Nomi delle uscite")
        if let raw = field([String: LenientEdits].self, .editsByDevice, "Modifiche per uscita") {
            editsByDevice = raw.compactMapValues(\.edits)
            if editsByDevice!.count < raw.count { problems.append("Modifiche per uscita illeggibili ignorate") }
            problems += raw.values.flatMap(\.problems)
        }
        lastOutputDeviceUID = field(String.self, .lastOutputDeviceUID, "Ultima uscita")
        if let list = field([LenientExcludedApp].self, .excludedApps, "App escluse") {
            excludedApps = list.compactMap(\.app)
            if excludedApps!.count < list.count { problems.append("App escluse illeggibili ignorate") }
            problems += list.compactMap(\.problem)
        }
        autoStartEngineOnLaunch = field(Bool.self, .autoStartEngineOnLaunch, "Avvio automatico")
        loginItemRequested = field(Bool.self, .loginItemRequested, "Apertura al login")
        bufferFrames = field(Int.self, .bufferFrames, "Dimensione del buffer")
        outputPairs = field([String: Int].self, .outputPairs, "Canali di uscita")
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
        let storedID = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil
        let storedName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        let storedPreamp = (try? c.decodeIfPresent(Double.self, forKey: .preampDecibels)) ?? nil
        let id = storedID ?? UUID()
        let name = storedName ?? "Preset"
        let preamp = storedPreamp ?? 0
        if storedID == nil { problems.append("Preset «\(name)»: identificativo illeggibile, rigenerato") }
        if storedName == nil { problems.append("Preset senza nome leggibile, chiamato «Preset»") }
        if storedPreamp == nil { problems.append("Preset «\(name)»: preamp illeggibile, 0 dB") }
        let readable = bands.compactMap(\.band)
        if readable.count < bands.count {
            problems.append("Preset «\(name)»: \(bands.count - readable.count) filtri illeggibili ignorati")
        }
        problems += bands.compactMap(\.problem).map { "Preset «\(name)»: \($0)" }
        preset = EQPreset(id: id, name: name, bands: readable, preampDecibels: preamp)
    }
}

private struct LenientEdits: Decodable {
    let edits: DeviceEdits?
    var problems: [String] = []

    enum CodingKeys: String, CodingKey { case presetID, bands, preampDecibels }

    init(from decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
            let bands = try? c.decode([LenientBand].self, forKey: .bands)
        else {
            edits = nil
            return
        }
        // presetID is legitimately absent (nil); present but unreadable is a problem.
        var preset: UUID?
        if c.contains(.presetID), (try? c.decodeNil(forKey: .presetID)) != true {
            preset = try? c.decode(UUID.self, forKey: .presetID)
            if preset == nil { problems.append("Modifiche per uscita: preset di base illeggibile") }
        }
        let storedPreamp = (try? c.decodeIfPresent(Double.self, forKey: .preampDecibels)) ?? nil
        if storedPreamp == nil { problems.append("Modifiche per uscita: preamp illeggibile, 0 dB") }
        let readable = bands.compactMap(\.band)
        if readable.count < bands.count { problems.append("Modifiche per uscita: filtri illeggibili ignorati") }
        problems += bands.compactMap(\.problem).map { "Modifiche per uscita: \($0)" }
        edits = DeviceEdits(presetID: preset, bands: readable, preampDecibels: storedPreamp ?? 0)
    }
}

/// One string of a list; never throws (nil if not a string).
private struct LenientString: Decodable {
    let value: String?

    init(from decoder: Decoder) {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

private struct LenientExcludedApp: Decodable {
    let app: ExcludedAppRecord?
    var problem: String?

    enum CodingKeys: String, CodingKey { case bundleID, name }

    init(from decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
            let bundleID = try? c.decode(String.self, forKey: .bundleID)
        else {
            app = nil
            return
        }
        let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        if name == nil { problem = "App esclusa \(bundleID): nome illeggibile" }
        app = ExcludedAppRecord(bundleID: bundleID, name: name ?? bundleID)
    }
}
