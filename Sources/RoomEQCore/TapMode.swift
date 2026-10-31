// How the system audio is captured, and small helpers around the tap format.

/// Which kind of Core Audio tap RoomEQ creates.
public enum TapMode: String, CaseIterable, Identifiable, Sendable {
    /// Tap bound to the system output device (default): captures what apps
    /// send to that device, in that device's own format (no sample-rate
    /// conversion when it is also the output device).
    case device
    /// Stereo mixdown of ALL apps (format chosen by the system, e.g. 48 kHz;
    /// resampled into the output device). Kept for diagnostics.
    case global

    public static let defaultMode = TapMode.device
    /// UserDefaults key where the mode is stored ("device" / "global").
    public static let defaultsKey = "TapMode"

    public var id: String { rawValue }

    /// Italian label for the UI.
    public var displayName: String {
        switch self {
        case .device: "Dispositivo"
        case .global: "Globale"
        }
    }
}

/// Which tap channels feed the left/right input of the render kernel.
public enum TapChannelSelection {
    /// 0-based (left, right) tap channels.
    /// - 1 channel: mono, used for both sides;
    /// - 2 channels: 0 and 1;
    /// - more (a device tap that kept the device's full layout): the device's
    ///   preferred stereo channels (`kAudioDevicePropertyPreferredChannelsForStereo`,
    ///   1-based), if valid, else 0 and 1.
    public static func stereoPair(tapChannels: Int, preferredStereo: (Int, Int)?) -> (left: Int, right: Int) {
        switch tapChannels {
        case ...1:
            return (0, 0)
        case 2:
            return (0, 1)
        default:
            if let (left, right) = preferredStereo,
                (1...tapChannels).contains(left), (1...tapChannels).contains(right), left != right
            {
                return (left - 1, right - 1)
            }
            return (0, 1)
        }
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
