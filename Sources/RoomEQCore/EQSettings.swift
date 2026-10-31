// The persisted EQ state (stage 3: one current setting; presets come in
// stage 4). Stored as JSON (Codable) by the controller in UserDefaults.

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

    /// The settings made safe to use: preamp inside its range, at most 16
    /// bands, no band with non-finite values, no duplicate IDs.
    public func sanitized() -> EQSettings {
        var seen = Set<UUID>()
        var cleanBands: [EQBand] = []
        for band in bands where band.isFinite && cleanBands.count < EQBand.maximumCount {
            var band = band
            if seen.contains(band.id) { band.id = UUID() }
            seen.insert(band.id)
            cleanBands.append(band)
        }
        return EQSettings(bands: cleanBands, preampDecibels: Preamp.clamp(preampDecibels), isEQEnabled: isEQEnabled)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decoded and sanitised settings, or nil if `data` isn't a valid
    /// (current-version) settings document.
    public static func decode(_ data: Data) -> EQSettings? {
        guard let settings = try? JSONDecoder().decode(EQSettings.self, from: data),
            settings.version == currentVersion
        else { return nil }
        return settings.sanitized()
    }
}
