// From the band list to what the audio path runs (off the real-time thread).
//
// `EQDesign` validates every band for a given sample rate, computes the
// biquad coefficients of the usable ones and collects an Italian message for
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

    /// When the filter set changes, the incoming filter bank first runs
    /// silently until a wrong starting state has decayed by this much,
    /// then it is crossfaded in (see DSPProcessor.swift).
    public static let warmupDecayDecibels = 40.0
    /// Upper limit of that silent warm-up.
    public static let maximumWarmupSeconds = 0.25

    public init(bands: [EQBand], sampleRate: Double) {
        self.sampleRate = sampleRate
        var sections: [FilterSection] = []
        var issues: [UUID: String] = [:]
        var warnings: [String] = []
        for (index, band) in bands.enumerated() where band.isEnabled {
            let name = "Filtro \(index + 1)"
            if sections.count >= EQBand.maximumCount {
                let message = "\(name): oltre il limite di \(EQBand.maximumCount) filtri, ignorato"
                issues[band.id] = message
                warnings.append(message)
                continue
            }
            switch Self.validate(band, sampleRate: sampleRate) {
            case .failure(let reason):
                let message = "\(name): \(reason.message), disattivato"
                issues[band.id] = message
                warnings.append(message)
            case .success(let coefficients):
                let id = FilterSection.idParts(band.id)
                sections.append(
                    FilterSection(
                        coefficients: coefficients, bandIDHigh: id.high, bandIDLow: id.low,
                        settleFrames: Self.settleFrames(coefficients, sampleRate: sampleRate)))
            }
        }
        self.sections = sections
        self.issues = issues
        self.warnings = warnings
    }

    /// Coefficients of the processed sections.
    public var coefficients: [BiquadCoefficients] { sections.map(\.coefficients) }

    // MARK: Validation

    public enum InvalidReason: Error, Equatable, Sendable {
        case notANumber
        case frequencyTooLow(minimum: Double)
        case frequencyTooHigh(maximum: Double, sampleRate: Double)
        case gainOutOfRange
        case qOutOfRange
        case unstable

        public var message: String {
            switch self {
            case .notANumber:
                return "parametri non validi"
            case .frequencyTooLow(let minimum):
                return "frequenza sotto \(ItalianNumber.compact(minimum)) Hz"
            case .frequencyTooHigh(let maximum, let sampleRate):
                return "frequenza troppo alta per \(ItalianNumber.compact(sampleRate / 1000, maxDecimals: 1)) kHz"
                    + " (massimo \(ItalianNumber.compact(maximum, maxDecimals: 0)) Hz)"
            case .gainOutOfRange:
                return "guadagno fuori dall'intervallo "
                    + "\(ItalianNumber.compact(EQBand.gainRange.lowerBound))…+\(ItalianNumber.compact(EQBand.gainRange.upperBound)) dB"
            case .qOutOfRange:
                return "Q fuori dall'intervallo "
                    + "\(ItalianNumber.compact(EQBand.qRange.lowerBound))…\(ItalianNumber.compact(EQBand.qRange.upperBound))"
            case .unstable:
                return "filtro instabile"
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
        if band.frequency >= maximumFrequency || band.frequency > EQBand.frequencyRange.upperBound {
            return fail(.frequencyTooHigh(
                maximum: min(maximumFrequency, EQBand.frequencyRange.upperBound), sampleRate: sampleRate))
        }
        if !EQBand.gainRange.contains(band.gain) { return fail(.gainOutOfRange) }
        if !EQBand.qRange.contains(band.q) { return fail(.qOutOfRange) }
        guard let coefficients = BiquadCoefficients.peaking(
            frequency: band.frequency, gainDecibels: band.gain, q: band.q, sampleRate: sampleRate)
        else { return fail(.unstable) }
        return .success(coefficients)
    }

    /// Samples until an error in the state of this section has decayed by
    /// `warmupDecayDecibels`: the slowest pole has radius r, so an error
    /// shrinks by r per sample. Capped at `maximumWarmupSeconds`.
    static func settleFrames(_ coefficients: BiquadCoefficients, sampleRate: Double) -> Int {
        let cap = max(0, Int((maximumWarmupSeconds * sampleRate).rounded()))
        let radius = coefficients.poleRadius
        guard radius.isFinite, radius > 0 else { return 0 }  // FIR-like: settles in 2 samples
        guard radius < 1 else { return cap }
        let decay = warmupDecayDecibels / 20 * log(10)  // ln of the amplitude ratio
        let frames = decay / -log(radius)
        guard frames.isFinite else { return cap }
        return min(cap, Int(frames.rounded(.up)))
    }
}

// MARK: - Combined curve

public enum EQCurve {
    /// Combined response in dB of `coefficients` (cascaded) at each frequency.
    public static func responseDecibels(
        coefficients: [BiquadCoefficients], sampleRate: Double, frequencies: [Double]
    ) -> [Double] {
        frequencies.map { frequency in
            let phi = BiquadCoefficients.phi(frequency: frequency, sampleRate: sampleRate)
            var squared = 1.0
            for section in coefficients { squared *= section.magnitudeSquared(phi: phi) }
            return squared > 0 ? 10 * log10(squared) : Decibels.floor
        }
    }

    /// `count` frequencies spaced logarithmically from `low` to `high` (inclusive).
    public static func logFrequencies(from low: Double = 20, to high: Double = 20_000, count: Int = 1000) -> [Double] {
        guard count > 1, low > 0, high > low else { return count == 1 ? [low] : [] }
        let ratio = log(high / low)
        return (0..<count).map { index in low * exp(ratio * Double(index) / Double(count - 1)) }
    }

    /// Largest boost of the combined curve between 20 Hz and 20 kHz
    /// (log grid plus every section's own Fc, where narrow peaks sit).
    /// 0 when the curve never goes above 0 dB.
    public static func maximumBoostDecibels(design: EQDesign, bands: [EQBand]) -> Double {
        var frequencies = logFrequencies(count: 2000)
        for band in bands where band.isEnabled && band.frequency > 20 && band.frequency < 20_000 {
            frequencies.append(band.frequency)
        }
        let response = responseDecibels(
            coefficients: design.coefficients, sampleRate: design.sampleRate, frequencies: frequencies)
        return max(0, response.max() ?? 0)
    }

    /// Preamp that keeps the combined curve at or below 0 dB:
    /// -max(0, boost), rounded up (towards more attenuation) to 0.1 dB and
    /// limited to the preamp range.
    public static func suggestedPreampDecibels(forMaximumBoost boost: Double) -> Double {
        guard boost.isFinite, boost > 0 else { return 0 }
        // The small tolerance keeps e.g. 3.2000000001 at 3.2 (not 3.3).
        let tenths = (boost * 10 - 1e-6).rounded(.up)
        return Preamp.clamp(-tenths / 10)
    }
}
