// Tap format helpers: which tap channels to use, format text, and the
// "no sample-rate conversion" guard.

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
    /// Refuses (Italian message) if L and R are in different streams, out of
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
            return .failure(TapSourceError(message: "I canali stereo del dispositivo (\(left)/\(right)) non sono validi: RoomEQ non si avvia."))
        }
        guard l.stream == r.stream else {
            return .failure(TapSourceError(
                message: "I canali stereo del dispositivo (\(left)/\(right)) sono in stream diversi: "
                    + "RoomEQ non supporta ancora questo dispositivo."))
        }
        guard streamChannelCounts[l.stream] >= 2 else {
            return .failure(TapSourceError(message: "Lo stream di uscita ha un solo canale: RoomEQ non si avvia."))
        }
        return .success(TapSource(stream: l.stream, left: l.offset, right: r.offset))
    }

    public struct TapSourceError: Error, Equatable, Sendable {
        public let message: String
    }
}

/// Short format text for the UI, Italian style: "44,1 kHz · 2 ch".
public enum AudioFormatText {
    public static func summary(sampleRate: Double, channels: Int) -> String {
        "\(kilohertz(sampleRate)) · \(channels) ch"
    }

    /// "44,1 kHz", "48 kHz", "88,2 kHz".
    public static func kilohertz(_ hertz: Double) -> String {
        let tenths = Int((hertz / 100).rounded())
        let whole = tenths / 10, fraction = tenths % 10
        return fraction == 0 ? "\(whole) kHz" : "\(whole),\(fraction) kHz"
    }

    /// "44,1 → 48 kHz" (or just "48 kHz" without a known old rate).
    public static func change(from old: Double?, to new: Double) -> String {
        guard let old, old > 0 else { return kilohertz(new) }
        return kilohertz(old).replacingOccurrences(of: " kHz", with: "") + " → " + kilohertz(new)
    }
}

/// RoomEQ never converts sample rates: the tap, the output device and the
/// capture aggregate must all run at exactly the same rate.
public enum SampleRateGuard {
    /// nil if everything matches, otherwise the Italian error to show.
    public static func violation(tapRate: Double, deviceRate: Double, captureRate: Double) -> String? {
        guard tapRate > 0, deviceRate > 0, captureRate > 0 else {
            return "Frequenza di campionamento sconosciuta (tap \(AudioFormatText.kilohertz(tapRate)), "
                + "dispositivo \(AudioFormatText.kilohertz(deviceRate))): RoomEQ non si avvia."
        }
        if !SampleRates.same(tapRate, deviceRate) {
            return "La frequenza del tap (\(AudioFormatText.kilohertz(tapRate))) non coincide con quella del "
                + "dispositivo (\(AudioFormatText.kilohertz(deviceRate))): RoomEQ non converte la frequenza, "
                + "quindi non si avvia."
        }
        if !SampleRates.same(captureRate, deviceRate) {
            return "La frequenza di cattura (\(AudioFormatText.kilohertz(captureRate))) non coincide con quella del "
                + "dispositivo (\(AudioFormatText.kilohertz(deviceRate))): RoomEQ non converte la frequenza, "
                + "quindi non si avvia."
        }
        return nil
    }
}
