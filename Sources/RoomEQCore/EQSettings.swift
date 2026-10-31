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
        var seen = Set<UUID>()
        var cleanBands: [EQBand] = []
        for band in bands where band.isFinite && cleanBands.count < EQBand.maximumCount {
            var band = band
            if seen.contains(band.id) { band.id = UUID() }
            seen.insert(band.id)
            cleanBands.append(band)
        }
        return EQSettings(
            bands: cleanBands, preampDecibels: Preamp.clamp(preampDecibels) ?? 0, isEQEnabled: isEQEnabled)
    }

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
            for (index, band) in stored.enumerated() {
                if let band = band.band {
                    bands.append(band)
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
        if stored.isEQEnabled == nil { warnings.append("Stato EQ salvato assente o illeggibile: EQ attivo") }
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
    var bands: [StoredBand]?
    var preampDecibels: Double?
    var isEQEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case version, bands, preampDecibels, isEQEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)  // must be an object
        version = try? container.decodeIfPresent(Int.self, forKey: .version)
        bands = try? container.decodeIfPresent([StoredBand].self, forKey: .bands)
        preampDecibels = try? container.decodeIfPresent(Double.self, forKey: .preampDecibels)
        isEQEnabled = try? container.decodeIfPresent(Bool.self, forKey: .isEQEnabled)
    }
}

/// One band; decoding never throws (so the array keeps going), `band` is nil
/// if the element is unusable. Missing ID -> new ID; missing isEnabled -> on.
private struct StoredBand: Decodable {
    let band: EQBand?

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
        band = EQBand(id: id ?? UUID(), frequency: frequency, gain: gain, q: q, isEnabled: isEnabled ?? true)
    }
}
