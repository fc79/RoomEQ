// Biquad coefficients (RBJ Audio EQ Cookbook) and their frequency response.
//
// All math is Double. Computed OFF the real-time thread (main thread or
// session start); the real-time code only receives finished `FilterSection`
// values.
//
// Transfer function (normalised by a0):
//
//            b0 + b1 z^-1 + b2 z^-2
//   H(z) = --------------------------
//            1 + a1 z^-1 + a2 z^-2

import Foundation

public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// H(z) = 1.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Peaking EQ ("peakingEQ") from the RBJ Audio EQ Cookbook:
    ///
    ///   A = 10^(gain/40), w0 = 2 pi Fc / Fs, alpha = sin(w0) / (2 Q)
    ///   b0 = 1 + alpha A, b1 = -2 cos w0, b2 = 1 - alpha A
    ///   a0 = 1 + alpha / A, a1 = -2 cos w0, a2 = 1 - alpha / A
    ///
    /// normalised by a0. The gain at Fc is exactly `gainDecibels`.
    /// Returns nil for parameters that cannot give a stable filter
    /// (non-finite, Fc <= 0 or >= Fs/2, Q <= 0).
    public static func peaking(frequency: Double, gainDecibels: Double, q: Double, sampleRate: Double)
        -> BiquadCoefficients?
    {
        guard frequency.isFinite, gainDecibels.isFinite, q.isFinite, sampleRate.isFinite,
            sampleRate > 0, frequency > 0, frequency < sampleRate / 2, q > 0
        else { return nil }
        let a = pow(10, gainDecibels / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha / a
        let coefficients = BiquadCoefficients(
            b0: (1 + alpha * a) / a0,
            b1: (-2 * cosW0) / a0,
            b2: (1 - alpha * a) / a0,
            a1: (-2 * cosW0) / a0,
            a2: (1 - alpha / a) / a0)
        return coefficients.isStable ? coefficients : nil
    }

    /// All coefficients finite and both poles strictly inside the unit circle.
    public var isStable: Bool {
        guard b0.isFinite, b1.isFinite, b2.isFinite, a1.isFinite, a2.isFinite else { return false }
        // Schur–Cohn (stability triangle) for z^2 + a1 z + a2.
        return abs(a2) < 1 && abs(a1) < 1 + a2
    }

    /// Largest pole radius (|z| of the slowest-decaying pole).
    public var poleRadius: Double {
        let discriminant = a1 * a1 - 4 * a2
        if discriminant < 0 { return sqrt(max(0, a2)) }  // complex pair: |z|^2 = a2
        let root = sqrt(discriminant)
        return max(abs((-a1 + root) / 2), abs((-a1 - root) / 2))
    }

    /// |H|^2 at normalised frequency `w` (radians/sample), written in terms
    /// of phi = sin^2(w/2) (RBJ cookbook). This form avoids the cancellation
    /// of `1 - cos w` at very low frequencies.
    @inline(__always)
    func magnitudeSquared(phi: Double) -> Double {
        let numeratorSum = b0 + b1 + b2
        let denominatorSum = 1 + a1 + a2
        let numerator = numeratorSum * numeratorSum - 4 * (b0 * b1 + 4 * b0 * b2 + b1 * b2) * phi
            + 16 * b0 * b2 * phi * phi
        let denominator = denominatorSum * denominatorSum - 4 * (a1 + 4 * a2 + a1 * a2) * phi
            + 16 * a2 * phi * phi
        return max(0, numerator) / denominator
    }

    /// Magnitude response in dB at `frequency` (Hz).
    public func magnitudeDecibels(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let squared = magnitudeSquared(phi: Self.phi(frequency: frequency, sampleRate: sampleRate))
        return squared > 0 ? 10 * log10(squared) : -.infinity
    }

    /// phi = sin^2(pi f / Fs), with f limited to [0, Fs/2].
    static func phi(frequency: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0, frequency.isFinite else { return 0 }
        let f = min(max(frequency, 0), sampleRate / 2)
        let s = sin(Double.pi * f / sampleRate)
        return s * s
    }
}

/// One filter section as handed to the real-time code: coefficients plus
/// what the click-free bank switch needs. Plain old data (no references),
/// so it can live in preallocated memory and be copied on the RT thread.
public struct FilterSection: Sendable, Equatable {
    public var coefficients: BiquadCoefficients
    /// The band's UUID as two integers (comparable on the RT thread without
    /// calling into Foundation). Used to carry a band's filter state over
    /// when the filter set changes.
    public var bandIDHigh: UInt64
    public var bandIDLow: UInt64
    /// Samples the section needs before an error in its state has decayed
    /// by `EQDesign.warmupDecayDecibels` (from its slowest pole), capped.
    public var settleFrames: Int

    public init(coefficients: BiquadCoefficients, bandIDHigh: UInt64, bandIDLow: UInt64, settleFrames: Int) {
        self.coefficients = coefficients
        self.bandIDHigh = bandIDHigh
        self.bandIDLow = bandIDLow
        self.settleFrames = settleFrames
    }

    /// Splits a UUID into the two integers used by `FilterSection`.
    public static func idParts(_ id: UUID) -> (high: UInt64, low: UInt64) {
        withUnsafeBytes(of: id.uuid) { bytes in
            (bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
             bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
    }
}
