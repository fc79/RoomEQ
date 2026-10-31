// Tap format helpers: which tap channels to use, format text, and the
// "no sample-rate conversion" guard.

/// Which tap channels feed the left/right input of the render kernel.
public enum TapChannelSelection {
    /// 0-based (left, right) tap channels.
    /// - 1 channel: mono, used for both sides;
    /// - 2 channels: 0 and 1, unless `preferredStereo` says otherwise;
    /// - more: the device's preferred stereo channels, if valid, else 0 and 1.
    /// `preferredStereo` is 1-based and relative to the tapped stream.
    public static func stereoPair(tapChannels: Int, preferredStereo: (Int, Int)?) -> (left: Int, right: Int) {
        guard tapChannels > 1 else { return (0, 0) }
        if let (left, right) = preferredStereo,
            (1...tapChannels).contains(left), (1...tapChannels).contains(right), left != right
        {
            return (left - 1, right - 1)
        }
        return (0, 1)
    }

    /// Converts the device's preferred stereo channels (1-based, numbered
    /// across all output streams) to channels within the stream that starts
    /// at device channel `streamFirstChannel` (1-based).
    public static func preferredWithinStream(_ preferred: (Int, Int)?, streamFirstChannel: Int) -> (Int, Int)? {
        guard let (left, right) = preferred else { return nil }
        return (left - streamFirstChannel + 1, right - streamFirstChannel + 1)
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
        if tapRate != deviceRate {
            return "La frequenza del tap (\(AudioFormatText.kilohertz(tapRate))) non coincide con quella del "
                + "dispositivo (\(AudioFormatText.kilohertz(deviceRate))): RoomEQ non converte la frequenza, "
                + "quindi non si avvia."
        }
        if captureRate != deviceRate {
            return "La frequenza di cattura (\(AudioFormatText.kilohertz(captureRate))) non coincide con quella del "
                + "dispositivo (\(AudioFormatText.kilohertz(deviceRate))): RoomEQ non converte la frequenza, "
                + "quindi non si avvia."
        }
        return nil
    }
}
