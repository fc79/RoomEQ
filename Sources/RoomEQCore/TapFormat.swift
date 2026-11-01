// Tap format helpers: which tap channels to use, format text, and the
// "no sample-rate conversion" guard.

import Foundation

/// Where the source L/R channels are: the output stream that holds the
/// device's preferred stereo channels, and their positions inside it.
public struct TapSource: Sendable, Equatable {
    /// Output stream index to tap.
    public let stream: Int
    /// 0-based channels within that stream.
    public let left: Int
    public let right: Int
}

public enum TapSourceSelection {
    /// Locates `preferred` (1-based device channel numbers across all output
    /// streams, from kAudioDevicePropertyPreferredChannelsForStereo; nil ->
    /// 1/2) in streams with `streamChannelCounts` channels.
    /// Refuses (localized message) if L and R are in different streams, out of
    /// range, or the stream has fewer than 2 channels: RoomEQ never silently
    /// duplicates one channel onto both outputs.
    public static func locate(preferred: (Int, Int)?, streamChannelCounts: [Int]) -> Result<TapSource, TapSourceError> {
        let (left, right) = preferred ?? (1, 2)
        var first = 1
        var streamOf: [Int: (stream: Int, offset: Int)] = [:]
        for (index, count) in streamChannelCounts.enumerated() {
            for offset in 0..<max(0, count) { streamOf[first + offset] = (index, offset) }
            first += max(0, count)
        }
        guard left != right, let l = streamOf[left], let r = streamOf[right] else {
            return .failure(TapSourceError(message: String(
                localized: "I canali stereo del dispositivo (\(left)/\(right)) non sono validi: RoomEQ non si avvia.")))
        }
        guard l.stream == r.stream else {
            return .failure(TapSourceError(
                message: String(
                    localized: "I canali stereo del dispositivo (\(left)/\(right)) sono in stream diversi: RoomEQ non supporta ancora questo dispositivo.")))
        }
        guard streamChannelCounts[l.stream] >= 2 else {
            return .failure(TapSourceError(message: String(localized: "Lo stream di uscita ha un solo canale: RoomEQ non si avvia.")))
        }
        return .success(TapSource(stream: l.stream, left: l.offset, right: r.offset))
    }

    public struct TapSourceError: Error, Equatable, Sendable {
        public let message: String
    }
}

/// Short format text for the UI: "44,1 kHz · 2 ch", with the numbers of
/// `TextLocale` (`NumberText`: Italian comma by default, "44.1 kHz" in the US).
public enum AudioFormatText {
    public static func summary(sampleRate: Double, channels: Int) -> String {
        "\(kilohertz(sampleRate)) · \(channels) ch"
    }

    /// "44,1 kHz", "48 kHz", "88,2 kHz"; "—" for an unknown rate (not
    /// finite, not positive, or absurdly large).
    public static func kilohertz(_ hertz: Double) -> String {
        kilohertz(hertz, locale: TextLocale.current)
    }

    static func kilohertz(_ hertz: Double, locale: Locale) -> String {
        guard isKnownRate(hertz) else { return "—" }
        return "\(NumberText.string(hertz / 1000, decimals: 0...1, locale: locale)) kHz"
    }

    /// "5,7" (always one decimal, `TextLocale`, half away from zero); "—"
    /// if not finite or absurdly large (a meaningless long number). No minus
    /// sign for values that round to zero.
    public static func oneDecimal(_ value: Double) -> String {
        oneDecimal(value, locale: TextLocale.current)
    }

    static func oneDecimal(_ value: Double, locale: Locale) -> String {
        guard abs(value) < 1e12 else { return "—" }  // also NaN
        return NumberText.string(value, decimals: 1...1, locale: locale)
    }

    /// "6,3 ms".
    public static func milliseconds(_ value: Double) -> String { "\(oneDecimal(value)) ms" }

    /// A usable sample rate: finite, positive, below 10 MHz.
    public static func isKnownRate(_ hertz: Double) -> Bool { hertz.isFinite && hertz > 0 && hertz < 10_000_000 }

    /// "44,1 kHz", or "sconosciuta" for an unknown rate (error messages).
    public static func kilohertzOrUnknown(_ hertz: Double) -> String {
        isKnownRate(hertz) ? kilohertz(hertz) : String(localized: "sconosciuta")
    }

    /// "44,1 → 48 kHz" (or just "48 kHz" without a known old rate).
    public static func change(from old: Double?, to new: Double) -> String {
        guard let old, isKnownRate(old), isKnownRate(new) else { return kilohertz(new) }
        return kilohertz(old).replacingOccurrences(of: " kHz", with: "") + " → " + kilohertz(new)
    }
}

/// RoomEQ never converts sample rates: the tap, the output device and the
/// capture aggregate must all run at exactly the same rate.
public enum SampleRateGuard {
    /// nil if everything matches, otherwise the (localized) error to show.
    public static func violation(tapRate: Double, deviceRate: Double, captureRate: Double) -> String? {
        let known = AudioFormatText.isKnownRate
        guard known(tapRate), known(deviceRate), known(captureRate) else {
            let text = AudioFormatText.kilohertzOrUnknown
            return String(
                localized: "Frequenza di campionamento sconosciuta (tap \(text(tapRate)), dispositivo \(text(deviceRate)), cattura \(text(captureRate))): RoomEQ non si avvia.")
        }
        if !SampleRates.same(tapRate, deviceRate) {
            let tap = AudioFormatText.kilohertz(tapRate), device = AudioFormatText.kilohertz(deviceRate)
            return String(
                localized: "La frequenza del tap (\(tap)) non coincide con quella del dispositivo (\(device)): RoomEQ non converte la frequenza, quindi non si avvia.")
        }
        if !SampleRates.same(captureRate, deviceRate) {
            let capture = AudioFormatText.kilohertz(captureRate), device = AudioFormatText.kilohertz(deviceRate)
            return String(
                localized: "La frequenza di cattura (\(capture)) non coincide con quella del dispositivo (\(device)): RoomEQ non converte la frequenza, quindi non si avvia.")
        }
        return nil
    }
}
