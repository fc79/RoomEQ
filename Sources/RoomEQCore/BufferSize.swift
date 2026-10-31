// Allowed IO buffer sizes.

public enum BufferSize {
    /// The buffer sizes (in frames) the app offers.
    public static let preferredSizes = [64, 128, 256]

    /// Default buffer size in frames.
    public static let defaultSize = 64

    /// The preferred sizes that the device accepts, given its
    /// `kAudioDevicePropertyBufferFrameSizeRange` (inclusive).
    /// If none fit, returns the single clamped default so the UI always has
    /// at least one option.
    public static func options(minimum: Int, maximum: Int) -> [Int] {
        let fitting = preferredSizes.filter { $0 >= minimum && $0 <= maximum }
        return fitting.isEmpty ? [clamp(defaultSize, minimum: minimum, maximum: maximum)] : fitting
    }

    /// Clamps `requested` into the device's range.
    public static func clamp(_ requested: Int, minimum: Int, maximum: Int) -> Int {
        guard minimum <= maximum else { return requested }
        return Swift.min(Swift.max(requested, minimum), maximum)
    }
}
