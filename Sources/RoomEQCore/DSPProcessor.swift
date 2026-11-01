// The EQ in the audio path: up to 16 cascaded peaking biquads, stereo,
// with click-free changes by PARAMETER SMOOTHING.
//
// REAL-TIME RULES: `process` and `apply` run on the Core Audio IO thread:
// no allocation, no locks, no logging, no Swift arrays, no class references,
// no static stored properties (constants are literals). All memory is
// allocated in `init`. The only library calls are libm exp/sin/cos (to
// recompute coefficients while a band is ramping).
//
// Filter structure: Transposed Direct Form II, coefficients AND state in
// Double. Per sample, per channel:
//     y  = b0 x + s1
//     s1 = b1 x - a1 y + s2
//     s2 = b2 x - a2 y
// TDF-II needs 2 state values per channel and is the usual floating-point
// choice. The difficult case is low Fc / high Q at high sample rates (at
// 192 kHz, ~60 Hz the poles sit ~2e-6 from z = 1): Double keeps ~10 more
// significant digits than Float there. No algorithmic delay (pure IIR).
//
// Click-free changes: every band has a slot whose parameters (ln Fc, gain
// in dB, ln Q) move linearly from where they are to the published target in
// `rampSeconds` (30 ms). Every `updateInterval` (16) samples the RBJ
// coefficients of the next point are computed, and within those 16 samples
// the coefficients are interpolated linearly per sample. The filter state
// is never reset or copied: the band just "moves", like an analogue EQ
// knob. Stability along the way: every point is an RBJ peaking filter with
// Q > 0 and 0 < w0 < pi, which is always stable, and the stable (a1, a2)
// region is convex, so the per-sample interpolation between two stable
// points is stable too.
//   * a new band starts at 0 dB (identity, zero state is exact) at its
//     target Fc/Q and ramps its gain in;
//   * a removed or disabled band ramps to 0 dB, keeps running until its
//     state has drained (< 1e-7, -140 dB), then its slot is freed;
//   * a replaced set (import/reset, new IDs) = all old bands ramp out and
//     all new ones ramp in at the same time (48 slots: three full sets fit,
//     so even quick repeated imports don't have to cut a band short);
//   * a new target can arrive at any time (slider drag): the ramp restarts
//     from the current position, so changes are coalesced and the last one
//     is always reached.
// Measured against the stage-3 A/B bank crossfade in
// EQSmoothingMeasurementTests (see the report in that file).
//
// Denormals: a constant offset of 1e-20 (-400 dB) is added to the filter
// input and removed at the output. Peaking filters have exactly unity DC
// gain, so the states settle on a tiny non-zero equilibrium instead of
// decaying into the denormal range. Bands at exactly 0 dB (identity) are
// skipped once their state has drained, so they can't decay into denormals
// either. (Apple Silicon handles denormals at full speed anyway; this keeps
// the code safe on any CPU.)
//
// The kernel calls `process` on every cycle, also when the EQ is bypassed
// (bypass is a dry/wet crossfade in RenderKernel), so the filter state
// stays warm and switching the EQ back on is click-free.

import Darwin

/// Filter state of one section, both channels (TDF-II: two values each).
struct SectionState {
    var left1: Double = 0
    var left2: Double = 0
    var right1: Double = 0
    var right2: Double = 0

    @inline(__always) var magnitude: Double {
        max(max(left1.magnitude, left2.magnitude), max(right1.magnitude, right2.magnitude))
    }
}

/// One band in the audio path (RT-private).
struct BandSlot {
    var isActive = false
    /// Ramping to 0 dB / draining; freed afterwards.
    var isRemoving = false
    var bandIDHigh: UInt64 = 0
    var bandIDLow: UInt64 = 0
    /// Position in the latest published set (for `activeTargets`).
    var order = 0
    /// Generation of the last published set that contained this band.
    var generation = 0
    /// Parameters at the END of the current coefficient segment.
    var logFrequency = 0.0
    var gainDecibels = 0.0
    var logQ = 0.0
    /// Where the ramp goes, and how far each segment moves.
    var targetLogFrequency = 0.0
    var targetGainDecibels = 0.0
    var targetLogQ = 0.0
    var stepLogFrequency = 0.0
    var stepGainDecibels = 0.0
    var stepLogQ = 0.0
    /// Segments left in the ramp.
    var stepsRemaining = 0
    /// Exact coefficients at the target (the ramp ends on them).
    var targetCoefficients = BiquadCoefficients.identity
    /// Coefficients in use, their per-sample change in this segment, and
    /// their exact value at the segment's end.
    var coefficients = BiquadCoefficients.identity
    var increment = BiquadCoefficients(b0: 0, b1: 0, b2: 0, a1: 0, a2: 0)
    var segmentEnd = BiquadCoefficients.identity
    var segmentRemaining = 0
    var state = SectionState()

    @inline(__always) var isMoving: Bool { stepsRemaining > 0 || segmentRemaining > 0 }
}

/// The DSP chain. Lives inside `RenderState` (preallocated memory) and is
/// only ever touched by the real-time thread (tests drive it directly).
public struct DSPProcessor: ~Copyable {
    /// Bands per published set (computed property: no lazy global on the RT thread).
    @inline(__always) public static var maximumSections: Int { 16 }
    /// Slots: three times the bands, so full sets can ramp out (and drain)
    /// while a full new set ramps in, even for quick repeated imports.
    @inline(__always) static var slotCount: Int { 48 }
    /// State size below which a band at 0 dB counts as drained (-140 dB).
    @inline(__always) static var drainedLevel: Double { 1e-7 }

    public let sampleRate: Double
    /// Largest block `process` handles in one pass (longer blocks are split).
    public let maximumFrames: Int
    /// Samples between two coefficient computations during a ramp.
    public let updateInterval: Int
    /// Segments (of `updateInterval` samples) in a full ramp.
    public let rampSteps: Int
    private let inverseUpdateInterval: Double
    private let radiansPerHertz: Double

    private let slots: UnsafeMutablePointer<BandSlot>
    private let workLeft: UnsafeMutablePointer<Double>
    private let workRight: UnsafeMutablePointer<Double>
    private var setGeneration = 0

    /// Diagnostics (RT-written, read by tests).
    public private(set) var appliedSets = 0
    /// Times a slot had to be taken while still draining (should stay 0).
    public private(set) var forcedSlotReuses = 0
    /// Times the state was found non-finite and reset (should stay 0).
    public private(set) var stateResets = 0

    /// `sections` is active immediately (no ramp; the stream starts from silence).
    public init(
        sampleRate: Double, maximumFrames: Int, rampSeconds: Double = 0.030, updateInterval: Int = 16,
        sections: [FilterSection] = []
    ) {
        self.sampleRate = sampleRate
        self.maximumFrames = max(16, maximumFrames)
        self.updateInterval = max(1, updateInterval)
        rampSteps = max(1, Int((rampSeconds * sampleRate / Double(max(1, updateInterval))).rounded()))
        inverseUpdateInterval = 1 / Double(self.updateInterval)
        radiansPerHertz = 2 * Double.pi / sampleRate

        slots = .allocate(capacity: Self.slotCount)
        slots.initialize(repeating: BandSlot(), count: Self.slotCount)
        workLeft = .allocate(capacity: self.maximumFrames)
        workLeft.initialize(repeating: 0, count: self.maximumFrames)
        workRight = .allocate(capacity: self.maximumFrames)
        workRight.initialize(repeating: 0, count: self.maximumFrames)

        for (index, section) in sections.prefix(Self.maximumSections).enumerated() {
            var slot = BandSlot()
            slot.isActive = true
            slot.bandIDHigh = section.bandIDHigh
            slot.bandIDLow = section.bandIDLow
            slot.order = index
            Self.place(&slot, at: section)
            slots[index] = slot
        }
    }

    deinit {
        slots.deallocate()
        workLeft.deallocate()
        workRight.deallocate()
    }

    // MARK: Inspection (not for the RT thread)

    /// True while any band is still moving or draining.
    public var isRamping: Bool {
        (0..<Self.slotCount).contains { slots[$0].isActive && (slots[$0].isMoving || slots[$0].isRemoving) }
    }

    /// Bands currently in the path (not being removed), with their target,
    /// in the order of the latest published set.
    public var activeTargets: [FilterSection] {
        (0..<Self.slotCount).map { slots[$0] }.filter { $0.isActive && !$0.isRemoving }
            .sorted { $0.order < $1.order }
            .map {
                FilterSection(
                    coefficients: $0.targetCoefficients, bandIDHigh: $0.bandIDHigh, bandIDLow: $0.bandIDLow,
                    logFrequency: $0.targetLogFrequency, gainDecibels: $0.targetGainDecibels, logQ: $0.targetLogQ)
            }
    }

    /// Slots in use (including bands ramping out).
    public var activeSlotCount: Int { (0..<Self.slotCount).filter { slots[$0].isActive }.count }

    /// Every state value of every active slot (denormal checks in tests).
    public var stateValues: [Double] {
        (0..<Self.slotCount).filter { slots[$0].isActive }.flatMap {
            let s = slots[$0].state
            return [s.left1, s.left2, s.right1, s.right2]
        }
    }

    /// Current (interpolated) coefficients of every active slot.
    public var currentCoefficients: [BiquadCoefficients] {
        (0..<Self.slotCount).filter { slots[$0].isActive }.map { slots[$0].coefficients }
    }

    /// Non-RT convenience for tests: same as the pointer version.
    public mutating func apply(_ sections: [FilterSection]) {
        sections.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                var nothing = FilterSection(
                    coefficients: .identity, bandIDHigh: 0, bandIDLow: 0, logFrequency: 0, gainDecibels: 0, logQ: 0)
                withUnsafePointer(to: &nothing) { apply($0, count: 0) }
                return
            }
            apply(base, count: buffer.count)
        }
    }

    // MARK: Real-time

    /// Makes `sections` the new targets. Real-time safe; may be called at
    /// any time (also while ramping): every band ramps from where it is.
    @inline(__always)
    public mutating func apply(_ sections: UnsafePointer<FilterSection>, count: Int) {
        setGeneration &+= 1
        appliedSets &+= 1
        let generation = setGeneration
        let total = Self.slotCount
        for index in 0..<min(max(0, count), Self.maximumSections) {
            let section = sections[index]
            // Same band already present (also if ramping out)?
            var found = -1
            for candidate in 0..<total {
                let slot = slots[candidate]
                if slot.isActive && slot.bandIDHigh == section.bandIDHigh && slot.bandIDLow == section.bandIDLow {
                    found = candidate
                    break
                }
            }
            if found < 0 { found = startBand(section) }
            slots[found].generation = generation
            slots[found].order = index
            slots[found].isRemoving = false
            retarget(
                &slots[found], logFrequency: section.logFrequency, gainDecibels: section.gainDecibels,
                logQ: section.logQ, coefficients: section.coefficients)
        }
        // Bands no longer in the set ramp out to 0 dB, where they are.
        for index in 0..<total where slots[index].isActive && slots[index].generation != generation {
            if slots[index].isRemoving { continue }
            slots[index].isRemoving = true
            let logFrequency = slots[index].logFrequency, logQ = slots[index].logQ
            retarget(
                &slots[index], logFrequency: logFrequency, gainDecibels: 0, logQ: logQ,
                coefficients: BiquadCoefficients.peakingRT(
                    logFrequency: logFrequency, gainDecibels: 0, logQ: logQ, radiansPerHertz: radiansPerHertz))
        }
    }

    /// Processes `frameCount` samples per channel from `input` into `output`
    /// (they may be the same buffers).
    @inline(__always)
    public mutating func process(
        inputLeft sourceLeft: UnsafePointer<Float>, inputRight sourceRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var done = 0
        while done < frameCount {
            let count = min(maximumFrames, frameCount - done)
            processBlock(sourceLeft + done, sourceRight + done, outputLeft + done, outputRight + done, count)
            done += count
        }
    }

    @inline(__always)
    private mutating func processBlock(
        _ sourceLeft: UnsafePointer<Float>, _ sourceRight: UnsafePointer<Float>,
        _ outputLeft: UnsafeMutablePointer<Float>, _ outputRight: UnsafeMutablePointer<Float>,
        _ count: Int
    ) {
        let offset = 1e-20  // anti-denormal DC offset (see header)
        // Float -> Double; a NaN/Inf input sample must never enter the IIR
        // state (it would stay there forever): it becomes 0 for the filters.
        // (The dry path keeps it and the kernel's NaN guard silences it.)
        for frame in 0..<count {
            let left = Double(sourceLeft[frame]), right = Double(sourceRight[frame])
            workLeft[frame] = (left.isFinite ? left : 0) + offset
            workRight[frame] = (right.isFinite ? right : 0) + offset
        }
        var healthy = true
        for index in 0..<Self.slotCount where slots[index].isActive {
            if !runSlot(index, count) { healthy = false }
        }
        if !healthy {
            // Cannot happen with valid coefficients and finite input; if it
            // ever does, recover instead of staying silent forever.
            for index in 0..<Self.slotCount { slots[index].state = SectionState() }
            for frame in 0..<count {
                workLeft[frame] = offset
                workRight[frame] = offset
            }
            stateResets &+= 1
        }
        for frame in 0..<count {
            outputLeft[frame] = Float(workLeft[frame] - offset)
            outputRight[frame] = Float(workRight[frame] - offset)
        }
    }

    /// Runs slot `index` in place over the work buffers. False if its state
    /// became non-finite.
    @inline(__always)
    private mutating func runSlot(_ index: Int, _ count: Int) -> Bool {
        var slot = slots[index]
        // A band at exactly 0 dB whose state has drained is the identity:
        // skip it (and free it if it was being removed).
        if !slot.isMoving && slot.targetGainDecibels == 0 && slot.state.magnitude < Self.drainedLevel {
            slot.state = SectionState()
            if slot.isRemoving { slot.isActive = false }
            slots[index] = slot
            return true
        }
        let left = workLeft, right = workRight
        var c = slot.coefficients
        var s = slot.state
        var frame = 0
        while frame < count {
            if slot.segmentRemaining == 0 && slot.stepsRemaining > 0 {
                beginSegment(&slot, from: c)
            }
            if slot.segmentRemaining > 0 {
                // Ramping: coefficients interpolated per sample.
                let n = min(slot.segmentRemaining, count - frame)
                let d = slot.increment
                for k in frame..<(frame + n) {
                    c.b0 += d.b0
                    c.b1 += d.b1
                    c.b2 += d.b2
                    c.a1 += d.a1
                    c.a2 += d.a2
                    let xl = left[k], xr = right[k]
                    let yl = c.b0 * xl + s.left1
                    let yr = c.b0 * xr + s.right1
                    s.left1 = c.b1 * xl - c.a1 * yl + s.left2
                    s.right1 = c.b1 * xr - c.a1 * yr + s.right2
                    s.left2 = c.b2 * xl - c.a2 * yl
                    s.right2 = c.b2 * xr - c.a2 * yr
                    left[k] = yl
                    right[k] = yr
                }
                slot.segmentRemaining -= n
                if slot.segmentRemaining == 0 { c = slot.segmentEnd }  // exact, no drift
                frame += n
            } else {
                // Steady: constant coefficients for the rest of the block.
                for k in frame..<count {
                    let xl = left[k], xr = right[k]
                    let yl = c.b0 * xl + s.left1
                    let yr = c.b0 * xr + s.right1
                    s.left1 = c.b1 * xl - c.a1 * yl + s.left2
                    s.right1 = c.b1 * xr - c.a1 * yr + s.right2
                    s.left2 = c.b2 * xl - c.a2 * yl
                    s.right2 = c.b2 * xr - c.a2 * yr
                    left[k] = yl
                    right[k] = yr
                }
                frame = count
            }
        }
        slot.coefficients = c
        slot.state = s
        slots[index] = slot
        return s.left1.isFinite && s.left2.isFinite && s.right1.isFinite && s.right2.isFinite
    }

    /// Next segment of a ramp: advance the parameters one step (the last
    /// step lands exactly on the target) and set up the interpolation.
    @inline(__always)
    private func beginSegment(_ slot: inout BandSlot, from current: BiquadCoefficients) {
        slot.stepsRemaining -= 1
        let next: BiquadCoefficients
        if slot.stepsRemaining == 0 {
            slot.logFrequency = slot.targetLogFrequency
            slot.gainDecibels = slot.targetGainDecibels
            slot.logQ = slot.targetLogQ
            next = slot.targetCoefficients
        } else {
            slot.logFrequency += slot.stepLogFrequency
            slot.gainDecibels += slot.stepGainDecibels
            slot.logQ += slot.stepLogQ
            next = BiquadCoefficients.peakingRT(
                logFrequency: slot.logFrequency, gainDecibels: slot.gainDecibels, logQ: slot.logQ,
                radiansPerHertz: radiansPerHertz)
        }
        let scale = inverseUpdateInterval
        slot.increment = BiquadCoefficients(
            b0: (next.b0 - current.b0) * scale, b1: (next.b1 - current.b1) * scale,
            b2: (next.b2 - current.b2) * scale, a1: (next.a1 - current.a1) * scale,
            a2: (next.a2 - current.a2) * scale)
        slot.segmentEnd = next
        slot.segmentRemaining = updateInterval
    }

    /// Sends a slot towards new parameters from where it is now (the end of
    /// its current segment), over a full ramp. No-op if nothing changes.
    @inline(__always)
    private func retarget(
        _ slot: inout BandSlot, logFrequency: Double, gainDecibels: Double, logQ: Double,
        coefficients: BiquadCoefficients
    ) {
        if logFrequency == slot.targetLogFrequency && gainDecibels == slot.targetGainDecibels
            && logQ == slot.targetLogQ
        {
            return  // already heading there (or there)
        }
        slot.targetLogFrequency = logFrequency
        slot.targetGainDecibels = gainDecibels
        slot.targetLogQ = logQ
        slot.targetCoefficients = coefficients
        let steps = Double(rampSteps)
        slot.stepLogFrequency = (logFrequency - slot.logFrequency) / steps
        slot.stepGainDecibels = (gainDecibels - slot.gainDecibels) / steps
        slot.stepLogQ = (logQ - slot.logQ) / steps
        slot.stepsRemaining = rampSteps
    }

    /// Takes a free slot for a new band: 0 dB (identity, zero state) at the
    /// band's target Fc and Q; `apply` then ramps its gain in.
    @inline(__always)
    private mutating func startBand(_ section: FilterSection) -> Int {
        var chosen = -1
        for index in 0..<Self.slotCount where !slots[index].isActive {
            chosen = index
            break
        }
        if chosen < 0 {
            // All slots busy (only with several full-set changes in quick
            // succession): take a draining band, preferring one that has
            // already reached 0 dB, with the smallest state.
            var smallest = Double.infinity
            for index in 0..<Self.slotCount where slots[index].isRemoving {
                let size = slots[index].state.magnitude + (slots[index].isMoving ? 1e6 : 0)
                if size < smallest {
                    smallest = size
                    chosen = index
                }
            }
            if chosen < 0 { chosen = 0 }
            forcedSlotReuses &+= 1
        }
        var slot = BandSlot()
        slot.isActive = true
        slot.bandIDHigh = section.bandIDHigh
        slot.bandIDLow = section.bandIDLow
        let identity = BiquadCoefficients.peakingRT(
            logFrequency: section.logFrequency, gainDecibels: 0, logQ: section.logQ,
            radiansPerHertz: radiansPerHertz)
        slot.logFrequency = section.logFrequency
        slot.logQ = section.logQ
        slot.gainDecibels = 0
        slot.targetLogFrequency = section.logFrequency
        slot.targetLogQ = section.logQ
        slot.targetGainDecibels = 0
        slot.targetCoefficients = identity
        slot.coefficients = identity
        slot.segmentEnd = identity
        slots[chosen] = slot
        return chosen
    }

    /// A slot sitting exactly at `section` (no ramp).
    private static func place(_ slot: inout BandSlot, at section: FilterSection) {
        slot.logFrequency = section.logFrequency
        slot.gainDecibels = section.gainDecibels
        slot.logQ = section.logQ
        slot.targetLogFrequency = section.logFrequency
        slot.targetGainDecibels = section.gainDecibels
        slot.targetLogQ = section.logQ
        slot.targetCoefficients = section.coefficients
        slot.coefficients = section.coefficients
        slot.segmentEnd = section.coefficients
    }
}
