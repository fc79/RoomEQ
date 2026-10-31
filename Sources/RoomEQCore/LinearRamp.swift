// A fixed-duration linear ramp, for click-free parameter changes.
//
// Used on the real-time thread for the preamp gain and the bypass (EQ
// on/off) crossfade. (EQ filter changes use the bank crossfade in
// DSPProcessor.swift instead.) The duration is a
// number of samples computed from the sample rate, so a change always takes
// the same TIME regardless of the IO buffer size; the ramp state is carried
// from one IO cycle to the next.

public struct LinearRamp: Sendable, Equatable {
    /// Current value.
    public private(set) var value: Float
    /// Value being ramped towards.
    public private(set) var target: Float
    /// Length of a full ramp in samples (>= 1).
    public let rampFrames: Int

    private var step: Float = 0
    private var remaining = 0

    public init(value: Float, rampFrames: Int) {
        self.value = value
        self.target = value
        self.rampFrames = max(1, rampFrames)
    }

    /// Ramp length in samples for `seconds` at `sampleRate` (at least 1).
    public static func frames(seconds: Double, sampleRate: Double) -> Int {
        max(1, Int((seconds * sampleRate).rounded()))
    }

    public var isRamping: Bool { remaining > 0 }

    /// Starts a new ramp from the current value if `newTarget` differs from
    /// the current target. A change during a ramp restarts it from where the
    /// value is now, so there is never a jump.
    @inline(__always)
    public mutating func setTarget(_ newTarget: Float) {
        guard newTarget != target else { return }
        target = newTarget
        remaining = rampFrames
        step = (newTarget - value) / Float(rampFrames)
    }

    /// Advances one sample and returns the new value. The last step lands
    /// exactly on the target (no rounding drift).
    @inline(__always)
    public mutating func next() -> Float {
        if remaining > 0 {
            remaining -= 1
            value = remaining == 0 ? target : value + step
        }
        return value
    }
}
