// Signal processing applied between the tap input and the device output.
//
// STAGE 2: passthrough. `process` is a no-op.
//
// STAGE 3 plan (where the biquad EQ goes):
//   - add per-channel biquad state (z1, z2 per section) as stored properties;
//   - publish new coefficient sets from the main thread through a
//     preallocated double buffer + an `Atomic<Int>` "active set" index
//     (no locks, no allocation on the real-time thread);
//   - smooth coefficient changes over a few ms, like `currentGain` does in
//     `RenderState`, to avoid clicks;
//   - recompute coefficients on sample-rate changes (the controller exposes
//     `onSampleRateChange` for that).
// Everything here runs on the Core Audio real-time thread: no allocation,
// no locks, no logging, no Swift arrays, no class references.

/// The DSP chain. Lives inside `RenderState` (preallocated memory) and is
/// only ever touched by the real-time thread.
public struct DSPProcessor {
    /// Sample rate the processor was configured for.
    public let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Processes `frameCount` samples of each channel in place.
    @inline(__always)
    public mutating func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        // Stage 2: passthrough — nothing to do.
    }
}
