// One band of the parametric room-correction EQ (a peaking filter).
//
// Value type shared by the UI, the persistence and the REW import. The
// filter math lives in Biquad.swift / EQDesign.swift; this file only holds
// the parameters, their limits and the default filter set.

import Foundation

public struct EQBand: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    /// Centre frequency Fc in Hz.
    public var frequency: Double
    /// Gain at Fc in dB (negative = cut).
    public var gain: Double
    /// Quality factor (RBJ cookbook definition, see Biquad.swift).
    public var q: Double
    /// A disabled band is kept in the list but not processed.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), frequency: Double, gain: Double, q: Double, isEnabled: Bool = true) {
        self.id = id
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.isEnabled = isEnabled
    }

    // MARK: Limits

    /// At most this many bands (and filter sections in the audio path).
    public static let maximumCount = 16

    /// Accepted parameter ranges. Values outside them (e.g. from an
    /// imported file) are kept in the list, but the band is not processed
    /// and gets a warning (see `EQDesign`). `clamped()` brings a band
    /// inside them (used for edits from the UI).
    public static let frequencyRange: ClosedRange<Double> = 10...20_000
    public static let gainRange: ClosedRange<Double> = -30...30
    public static let qRange: ClosedRange<Double> = 0.1...100

    /// Additionally, Fc must not exceed this fraction of the sample rate
    /// (the cookbook filter gets badly cramped near Nyquist). Inclusive.
    public static let maximumFrequencyRatio = 0.45

    /// The result of editing this band into `edited` (e.g. from the UI):
    /// only the fields that CHANGED are taken from `edited`, clamped to the
    /// accepted ranges; a non-finite new value is ignored (the field keeps
    /// its old value). Unchanged fields stay exactly as they are, even if out
    /// of range (an imported band stays excluded with its warning instead
    /// of being silently re-enabled with clamped, extreme values).
    public func applyingEdit(_ edited: EQBand) -> EQBand {
        func update(_ old: Double, _ new: Double, _ range: ClosedRange<Double>) -> Double {
            guard new != old else { return old }
            guard new.isFinite else { return old }
            return min(max(new, range.lowerBound), range.upperBound)
        }
        var band = self
        band.frequency = update(frequency, edited.frequency, Self.frequencyRange)
        band.gain = update(gain, edited.gain, Self.gainRange)
        band.q = update(q, edited.q, Self.qRange)
        band.isEnabled = edited.isEnabled
        return band
    }

    /// True when all parameters are finite numbers.
    public var isFinite: Bool { frequency.isFinite && gain.isFinite && q.isFinite }

    /// The band with every parameter brought inside the accepted ranges.
    /// Non-finite values are replaced by neutral ones (1 kHz, 0 dB, Q 1).
    public func clamped() -> EQBand {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        var band = self
        band.frequency = clamp(frequency, Self.frequencyRange, fallback: 1000)
        band.gain = clamp(gain, Self.gainRange, fallback: 0)
        band.q = clamp(q, Self.qRange, fallback: 1)
        return band
    }

    // MARK: Defaults

    /// A neutral band for "add band": 1 kHz, 0 dB, Q 1.
    public static func neutral() -> EQBand {
        EQBand(frequency: 1000, gain: 0, q: 1)
    }

    /// The user's REW measurement (Generic equaliser, PK filters), used when
    /// nothing is saved and by "reset to default filters". New IDs each call.
    public static func defaultBands() -> [EQBand] {
        [
            EQBand(frequency: 58.80, gain: -9.90, q: 10.664),
            EQBand(frequency: 76.60, gain: -6.80, q: 14.316),
            EQBand(frequency: 140.0, gain: -15.90, q: 4.267),
            EQBand(frequency: 192.0, gain: -5.40, q: 3.628),
        ]
    }
}

/// Output preamp: attenuation only, never a boost.
public enum Preamp {
    /// dB range of the preamp. 0 dB = unity, never above.
    public static let range: ClosedRange<Double> = -24...0

    /// `decibels` limited to `range`: -inf -> -24 dB, +inf -> 0 dB.
    /// NaN -> nil: the value is rejected (callers keep the previous one).
    public static func clamp(_ decibels: Double) -> Double? {
        guard !decibels.isNaN else { return nil }
        let value = min(max(decibels, range.lowerBound), range.upperBound)
        return value == 0 ? 0 : value  // no "-0"
    }

    /// Linear gain (<= 1) for `decibels`, after clamping; nil for NaN.
    public static func linearGain(decibels: Double) -> Float? {
        clamp(decibels).map { Float(Decibels.linear(fromDecibels: $0)) }
    }
}

/// Small Italian number formatting for messages produced in RoomEQCore
/// (decimal comma). The UI has its own, locale-based formatter.
enum ItalianNumber {
    static func format(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return value.isNaN ? "non valido" : (value > 0 ? "∞" : "-∞") }
        return String(format: "%.\(max(0, decimals))f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// "58,8" / "1000" style: up to `maxDecimals`, trailing zeros removed.
    static func compact(_ value: Double, maxDecimals: Int = 2) -> String {
        var text = format(value, decimals: maxDecimals)
        guard text.contains(",") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(",") { text.removeLast() }
        return text
    }
}
