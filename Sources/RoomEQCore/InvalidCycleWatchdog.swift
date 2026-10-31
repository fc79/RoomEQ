// Detects an engine that runs but cannot render (layout mismatch).
//
// If the device's buffer layout changes under us, the render kernel outputs
// silence and counts "invalid" cycles. Because the tap mutes the tapped apps
// while we read it, that would mean silence forever. The controller polls
// the meters ~25 times per second and feeds them here; when most cycles have
// been invalid for `tripSeconds`, it rebuilds the engine.

public struct InvalidCycleWatchdog: Sendable {
    public let tripSeconds: Double
    private var lastRendered: UInt64 = 0
    private var lastInvalid: UInt64 = 0
    private var invalidDuration: Double = 0

    public init(tripSeconds: Double = 0.5) {
        self.tripSeconds = tripSeconds
    }

    /// Feeds the cumulative counters. `elapsed` = seconds since the previous
    /// call. Returns true once at least half the cycles have been invalid for
    /// `tripSeconds` in a row (then starts counting again from zero).
    public mutating func update(renderedCycles: UInt64, invalidCycles: UInt64, elapsed: Double) -> Bool {
        // Counters went backwards: they belong to a new render state.
        if renderedCycles < lastRendered || invalidCycles < lastInvalid {
            reset()
        }
        let rendered = renderedCycles &- lastRendered
        let invalid = invalidCycles &- lastInvalid
        lastRendered = renderedCycles
        lastInvalid = invalidCycles
        guard rendered > 0 else { return false }  // IO not running: nothing to judge.

        if invalid * 2 >= rendered {
            invalidDuration += elapsed
        } else {
            invalidDuration = 0
        }
        guard invalidDuration >= tripSeconds else { return false }
        invalidDuration = 0
        return true
    }

    /// Forget history (call when a new session starts).
    public mutating func reset() {
        self = InvalidCycleWatchdog(tripSeconds: tripSeconds)
    }
}
