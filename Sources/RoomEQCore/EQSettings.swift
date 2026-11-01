// The persisted EQ state (one current setting; presets come in stage 4).
// Stored as JSON by the controller in UserDefaults.
//
// Loading is LOSSY and forward-compatible: every field is read on its own
// (missing or unreadable -> default), every band is read on its own
// (unreadable bands are skipped with a warning), and documents from a newer
// format version are accepted by reading the fields this version knows.
// The caller keeps a backup of the raw data whenever something could not
// be read (`EQSettingsLoad.needsBackup`) BEFORE saving over it.

import Foundation

public struct EQSettings: Codable, Sendable, Equatable {
    /// Format version, for future migrations.
    public var version: Int
    public var bands: [EQBand]
    public var preampDecibels: Double
    public var isEQEnabled: Bool

    public static let currentVersion = 1
    /// UserDefaults key of the stage-3 document (read for migration only).
    public static let storageKey = "EQSettings"

    public init(bands: [EQBand], preampDecibels: Double, isEQEnabled: Bool) {
        version = Self.currentVersion
        self.bands = bands
        self.preampDecibels = preampDecibels
        self.isEQEnabled = isEQEnabled
    }

    /// Used when nothing is saved: the user's REW filters, preamp 0 dB, EQ on.
    public static func defaults() -> EQSettings {
        EQSettings(bands: EQBand.defaultBands(), preampDecibels: 0, isEQEnabled: true)
    }

    /// The settings made safe to use: preamp inside its range (NaN -> 0 dB),
    /// at most 16 bands, no band with non-finite values, no duplicate IDs.
    public func sanitized() -> EQSettings {
        EQSettings(
            bands: Self.sanitizedBands(bands), preampDecibels: Self.sanitizedPreamp(preampDecibels),
            isEQEnabled: isEQEnabled)
    }

    /// At most 16 bands, none with non-finite values, no duplicate IDs.
    public static func sanitizedBands(_ bands: [EQBand]) -> [EQBand] {
        var seen = Set<UUID>()
        var cleanBands: [EQBand] = []
        for band in bands where band.isFinite && cleanBands.count < EQBand.maximumCount {
            var band = band
            if seen.contains(band.id) { band.id = UUID() }
            seen.insert(band.id)
            cleanBands.append(band)
        }
        return cleanBands
    }

    /// Preamp inside its range (NaN -> 0 dB).
    public static func sanitizedPreamp(_ decibels: Double) -> Double { Preamp.clamp(decibels) ?? 0 }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads saved settings as far as possible (see the file header).
    public static func load(_ data: Data) -> EQSettingsLoad {
        guard let stored = try? JSONDecoder().decode(StoredSettings.self, from: data) else {
            return EQSettingsLoad(settings: .defaults(), warnings: ["Impostazioni salvate illeggibili"], status: .unreadable)
        }
        var warnings: [String] = []
        if let version = stored.version, version > currentVersion {
            warnings.append("Impostazioni salvate in un formato più recente (versione \(version)): letti i campi noti")
        }
        var bands: [EQBand]
        if let stored = stored.bands {
            bands = []
            for (index, entry) in stored.enumerated() {
                if let band = entry.band {
                    bands.append(band)
                    if let problem = entry.problem { warnings.append("Filtro salvato \(index + 1): \(problem)") }
                } else {
                    warnings.append("Filtro salvato \(index + 1) illeggibile, ignorato")
                }
            }
        } else {
            bands = EQBand.defaultBands()
            warnings.append("Elenco dei filtri salvato assente o illeggibile: caricati i filtri iniziali")
        }
        if bands.count > EQBand.maximumCount {
            warnings.append("Più di \(EQBand.maximumCount) filtri salvati: tenuti i primi \(EQBand.maximumCount)")
        }
        if stored.preampDecibels == nil { warnings.append("Preamp salvato assente o illeggibile: 0 dB") }
        // EQ on/off is not reported: version 4 of the settings ignores it.
        let settings = EQSettings(
            bands: bands, preampDecibels: stored.preampDecibels ?? 0, isEQEnabled: stored.isEQEnabled ?? true
        ).sanitized()
        return EQSettingsLoad(settings: settings, warnings: warnings, status: warnings.isEmpty ? .complete : .partial)
    }
}

/// Outcome of `EQSettings.load`.
public struct EQSettingsLoad: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Everything read.
        case complete
        /// Read, but something was missing, unreadable or from a newer version.
        case partial
        /// Nothing usable (not a settings document): defaults returned.
        case unreadable
    }

    public var settings: EQSettings
    /// What could not be read (Italian, for the log).
    public var warnings: [String]
    public var status: Status

    /// The raw data should be kept (something would be lost by saving over it).
    public var needsBackup: Bool { status != .complete }
}

// MARK: - Lenient decoding

/// Top-level document: every field optional and read on its own, so one bad
/// field does not lose the others.
private struct StoredSettings: Decodable {
    var version: Int?
    var bands: [LenientBand]?
    var preampDecibels: Double?
    var isEQEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case version, bands, preampDecibels, isEQEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)  // must be an object
        version = try? container.decodeIfPresent(Int.self, forKey: .version)
        bands = try? container.decodeIfPresent([LenientBand].self, forKey: .bands)
        preampDecibels = try? container.decodeIfPresent(Double.self, forKey: .preampDecibels)
        isEQEnabled = try? container.decodeIfPresent(Bool.self, forKey: .isEQEnabled)
    }
}

/// One band; decoding never throws (so the array keeps going), `band` is nil
/// if the element is unusable. Missing/unreadable ID -> new ID, missing or
/// unreadable isEnabled -> on; each such fallback is reported in `problem`
/// (so the caller keeps a backup). Shared by every lenient settings decoder.
struct LenientBand: Decodable {
    let band: EQBand?
    /// Italian description of a fallback used, nil if none.
    var problem: String?

    enum CodingKeys: String, CodingKey {
        case id, frequency, gain, q, isEnabled
    }

    init(from decoder: Decoder) {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
            let frequency = try? container.decode(Double.self, forKey: .frequency),
            let gain = try? container.decode(Double.self, forKey: .gain),
            let q = try? container.decode(Double.self, forKey: .q),
            frequency.isFinite, gain.isFinite, q.isFinite
        else {
            band = nil
            return
        }
        let id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? nil
        let isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? nil
        var problems: [String] = []
        if id == nil { problems.append("identificativo illeggibile, rigenerato") }
        if isEnabled == nil { problems.append("stato attivo/disattivo illeggibile, attivato") }
        problem = problems.isEmpty ? nil : problems.joined(separator: "; ")
        band = EQBand(id: id ?? UUID(), frequency: frequency, gain: gain, q: q, isEnabled: isEnabled ?? true)
    }
}
