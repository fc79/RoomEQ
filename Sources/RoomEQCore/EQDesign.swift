// From the band list to what the audio path runs (off the real-time thread).
//
// `EQDesign` validates every band for a given sample rate, computes the
// biquad coefficients of the usable ones and collects a localized message for
// every band that cannot be processed (it is then simply left out: never
// NaN, never an unstable filter). It also evaluates the combined curve for
// drawing and for the "suggested preamp".

import Foundation

public struct EQDesign: Sendable, Equatable {
    /// Sample rate the coefficients were computed for.
    public let sampleRate: Double
    /// Sections for the audio path: the enabled, valid bands in list order.
    public let sections: [FilterSection]
    /// Why a band is not processed although enabled, keyed by band ID
    /// (e.g. Fc too high for the sample rate). Disabled bands are not listed.
    public let issues: [UUID: String]
    /// The same messages in band order, for a simple list in the UI.
    public let warnings: [String]
    /// Coefficients and Fc (Hz) of the processed sections (stored once, so
    /// curve evaluations don't rebuild them).
    public let coefficients: [BiquadCoefficients]
    public let centerFrequencies: [Double]

    public init(bands: [EQBand], sampleRate: Double) {
        self.sampleRate = sampleRate
        var sections: [FilterSection] = []
        var issues: [UUID: String] = [:]
        var warnings: [String] = []
        var centers: [Double] = []
        for (index, band) in bands.enumerated() where band.isEnabled {
            let number = index + 1
            if sections.count >= EQBand.maximumCount {
                let message = String(localized: "Filtro \(number): oltre il limite di \(EQBand.maximumCount) filtri, ignorato")
                issues[band.id] = message
                warnings.append(message)
                continue
            }
            switch Self.validate(band, sampleRate: sampleRate) {
            case .failure(let reason):
                let message = String(localized: "Filtro \(number): \(reason.message), non applicato")
                issues[band.id] = message
                warnings.append(message)
            case .success(let coefficients):
                sections.append(FilterSection(band: band, coefficients: coefficients))
                centers.append(band.frequency)
            }
        }
        self.sections = sections
        self.issues = issues
        self.warnings = warnings
        self.coefficients = sections.map(\.coefficients)
        self.centerFrequencies = centers
    }

    // MARK: Validation

    public enum InvalidReason: Error, Equatable, Sendable {
        case notANumber
        case frequencyTooLow(minimum: Double)
        /// Above 0.45 x the sample rate.
        case frequencyTooHigh(maximum: Double, sampleRate: Double)
        /// Above the absolute limit (20 kHz), whatever the sample rate.
        case frequencyAboveLimit(maximum: Double)
        case gainOutOfRange
        case qOutOfRange
        case unstable

        public var message: String {
            switch self {
            case .notANumber:
                return String(localized: "parametri non validi")
            case .frequencyTooLow(let minimum):
                return String(localized: "frequenza sotto \(NumberText.compact(minimum)) Hz")
            case .frequencyTooHigh(let maximum, let sampleRate):
                let rate = NumberText.compact(sampleRate / 1000, maxDecimals: 1)
                let limit = NumberText.compact(maximum.rounded(.down), maxDecimals: 0)
                return String(localized: "frequenza troppo alta per \(rate) kHz (massimo \(limit) Hz)")
            case .frequencyAboveLimit(let maximum):
                return String(localized: "frequenza sopra \(NumberText.compact(maximum, maxDecimals: 0)) Hz")
            case .gainOutOfRange:
                let range = "\(NumberText.compact(EQBand.gainRange.lowerBound))…+\(NumberText.compact(EQBand.gainRange.upperBound)) dB"
                return String(localized: "guadagno fuori dall'intervallo \(range)")
            case .qOutOfRange:
                let range = "\(NumberText.compact(EQBand.qRange.lowerBound))…\(NumberText.compact(EQBand.qRange.upperBound))"
                return String(localized: "Q fuori dall'intervallo \(range)")
            case .unstable:
                return String(localized: "filtro instabile")
            }
        }
    }

    /// Coefficients for `band` at `sampleRate`, or why it can't be used.
    public static func validate(_ band: EQBand, sampleRate: Double) -> Result<BiquadCoefficients, InvalidReason> {
        func fail(_ reason: InvalidReason) -> Result<BiquadCoefficients, InvalidReason> { .failure(reason) }
        guard band.isFinite, sampleRate.isFinite, sampleRate > 0 else { return fail(.notANumber) }
        let maximumFrequency = EQBand.maximumFrequencyRatio * sampleRate
        if band.frequency < EQBand.frequencyRange.lowerBound {
            return fail(.frequencyTooLow(minimum: EQBand.frequencyRange.lowerBound))
        }
        // Fc may go up to the lower of the two limits, inclusive (the
        // "massimo" in the message is allowed). Name the limit that applies.
        let absolute = EQBand.frequencyRange.upperBound
        if band.frequency > min(absolute, maximumFrequency) {
            return fail(absolute <= maximumFrequency
                ? .frequencyAboveLimit(maximum: absolute)
                : .frequencyTooHigh(maximum: maximumFrequency, sampleRate: sampleRate))
        }
        if !EQBand.gainRange.contains(band.gain) { return fail(.gainOutOfRange) }
        if !EQBand.qRange.contains(band.q) { return fail(.qOutOfRange) }
        guard let coefficients = BiquadCoefficients.peaking(
            frequency: band.frequency, gainDecibels: band.gain, q: band.q, sampleRate: sampleRate)
        else { return fail(.unstable) }
        return .success(coefficients)
    }

}

// MARK: - Combined curve

public enum EQCurve {
    /// Combined response in dB of `coefficients` (cascaded) at each frequency.
    public static func responseDecibels(
        coefficients: [BiquadCoefficients], sampleRate: Double, frequencies: [Double]
    ) -> [Double] {
        frequencies.map { response(coefficients, sampleRate: sampleRate, at: $0) }
    }

    /// Combined response in dB at one frequency (no allocation).
    @inline(__always)
    static func response(_ coefficients: [BiquadCoefficients], sampleRate: Double, at frequency: Double) -> Double {
        let phi = BiquadCoefficients.phi(frequency: frequency, sampleRate: sampleRate)
        var squared = 1.0
        for section in coefficients { squared *= section.magnitudeSquared(phi: phi) }
        return squared > 0 ? 10 * log10(squared) : Decibels.floor
    }

    /// Grid for the maximum-boost search: from the lowest allowed Fc
    /// (10 Hz) to 20 kHz, 2000 log-spaced points. Computed once.
    public static let boostSearchFrequencies = logFrequencies(
        from: EQBand.frequencyRange.lowerBound, to: 20_000, count: 2000)

    /// `count` frequencies spaced logarithmically from `low` to `high` (inclusive).
    public static func logFrequencies(from low: Double = 20, to high: Double = 20_000, count: Int = 1000) -> [Double] {
        guard count > 1, low > 0, high > low else { return count == 1 ? [low] : [] }
        let ratio = log(high / low)
        return (0..<count).map { index in low * exp(ratio * Double(index) / Double(count - 1)) }
    }

    /// Largest boost of the combined curve from 10 Hz (the lowest allowed
    /// Fc) to 20 kHz: the log grid plus every processed band's own Fc, where
    /// narrow peaks sit. 0 when the curve never goes above 0 dB.
    public static func maximumBoostDecibels(design: EQDesign) -> Double {
        guard !design.coefficients.isEmpty else { return 0 }
        var best = 0.0
        for frequency in boostSearchFrequencies {
            best = max(best, response(design.coefficients, sampleRate: design.sampleRate, at: frequency))
        }
        for frequency in design.centerFrequencies {
            best = max(best, response(design.coefficients, sampleRate: design.sampleRate, at: frequency))
        }
        return best
    }

    /// Preamp that keeps the combined curve at or below 0 dB:
    /// -max(0, boost), rounded up (towards more attenuation) to 0.1 dB and
    /// limited to the preamp range.
    public static func suggestedPreampDecibels(forMaximumBoost boost: Double) -> Double {
        guard boost.isFinite, boost > 0 else { return 0 }
        // The small tolerance keeps e.g. 3.2000000001 at 3.2 (not 3.3).
        let tenths = (boost * 10 - 1e-6).rounded(.up)
        return Preamp.clamp(-tenths / 10) ?? 0
    }
}
