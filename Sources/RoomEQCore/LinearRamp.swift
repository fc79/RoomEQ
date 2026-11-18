// A fixed-duration linear ramp, for click-free parameter changes.
//
// Used on the real-time thread for the kernel's dry/wet (bypass) crossfade
// (the preamp uses `GainRamp`, below). (EQ filter changes are smoothed per band inside
// DSPProcessor.swift instead: parameter ramps, not this type.) The duration
// is a number of samples computed from the sample rate, so a change always
// takes the same TIME regardless of the IO buffer size; the ramp state is
// carried from one IO cycle to the next.

import Foundation

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

/// The preamp gain ramp of the render kernel.
///
/// Between two audible gains (both at least `geometricFloor`) it moves
/// linearly in dB over `levelFrames`: the same duration and shape as an EQ
/// band's gain ramp (DSPProcessor), so when a preset change moves bands
/// and preamp together, a band's boost and the preamp's cut cancel all the
/// way through instead of overshooting both presets. To or from silence
/// (the fade-out at stop) it is linear in amplitude over `fadeFrames`, as
/// `LinearRamp`.
public struct GainRamp: Sendable, Equatable {
    /// Below this the ramp is a fade (linear in amplitude): −40 dB, well
    /// under the lowest preamp (−24 dB).
    /// (A computed literal: read on the audio thread, no lazy global.)
    @inline(__always) public static var geometricFloor: Float { 0.01 }

    public private(set) var value: Float
    public private(set) var target: Float
    /// Length of a fade to or from silence, in samples (>= 1).
    public let fadeFrames: Int
    /// Length of a change between audible gains, in samples (>= 1).
    public let levelFrames: Int

    private var step: Float = 0
    private var factor: Float = 1
    private var isGeometric = false
    private var remaining = 0

    public init(value: Float, fadeFrames: Int, levelFrames: Int) {
        self.value = value
        self.target = value
        self.fadeFrames = max(1, fadeFrames)
        self.levelFrames = max(1, levelFrames)
    }

    public var isRamping: Bool { remaining > 0 }

    /// Starts a new ramp from the current value if `newTarget` differs from
    /// the current target (a change during a ramp continues from where the
    /// value is, never a jump). Real-time safe (one `pow` per new target).
    @inline(__always)
    public mutating func setTarget(_ newTarget: Float) {
        guard newTarget != target else { return }
        target = newTarget
        if value >= Self.geometricFloor && newTarget >= Self.geometricFloor {
            isGeometric = true
            remaining = levelFrames
            factor = Float(pow(Double(newTarget) / Double(value), 1 / Double(levelFrames)))
        } else {
            isGeometric = false
            remaining = fadeFrames
            step = (newTarget - value) / Float(fadeFrames)
        }
    }

    /// Advances one sample and returns the new value. The last step lands
    /// exactly on the target.
    @inline(__always)
    public mutating func next() -> Float {
        if remaining > 0 {
            remaining -= 1
            value = remaining == 0 ? target : (isGeometric ? value * factor : value + step)
        }
        return value
    }
}
