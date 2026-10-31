// Conversion between decibels and linear amplitude.

import Foundation

public enum Decibels {
    /// Values at or below this are treated as silence ("-inf").
    public static let floor: Double = -120

    /// Linear gain for a value in dB (0 dB -> 1.0, -6.02 dB -> 0.5).
    public static func linear(fromDecibels decibels: Double) -> Double {
        decibels <= floor ? 0 : pow(10, decibels / 20)
    }

    /// dBFS of a linear amplitude (1.0 -> 0 dB). Returns `floor` for silence.
    public static func decibels(fromLinear linear: Double) -> Double {
        guard linear > 0 else { return floor }
        return Swift.max(floor, 20 * log10(linear))
    }
}
