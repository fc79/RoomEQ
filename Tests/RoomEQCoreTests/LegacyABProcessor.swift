// TEST-ONLY copy of the stage-3 A/B processor (two banks, silent warm-up,
// 20 ms crossfade), kept to measure it against parameter smoothing
// (EQSmoothingMeasurementTests). Not used by the app.

import Foundation
@testable import RoomEQCore

/// Section for the legacy processor (coefficients + warm-up length).
struct LegacySection: Equatable {
    var coefficients: BiquadCoefficients
    var bandIDHigh: UInt64
    var bandIDLow: UInt64
    var settleFrames: Int

    /// As stage 3 computed it: 40 dB decay of the slowest pole, capped at 250 ms.
    static func make(_ sections: [FilterSection], sampleRate: Double) -> [LegacySection] {
        sections.map { section in
            let cap = Int((0.25 * sampleRate).rounded())
            let radius = section.coefficients.poleRadius
            var frames = 0
            if radius > 0 && radius < 1 { frames = min(cap, Int((40.0 / 20 * log(10) / -log(radius)).rounded(.up))) }
            return LegacySection(coefficients: section.coefficients, bandIDHigh: section.bandIDHigh,
                                 bandIDLow: section.bandIDLow, settleFrames: frames)
        }
    }
}

/// Filter state of one section, both channels (TDF-II: two values each).
struct LegacySectionState {
    var left1: Double = 0
    var left2: Double = 0
    var right1: Double = 0
    var right2: Double = 0
}

/// The DSP chain. Lives inside `RenderState` (preallocated memory) and is
/// only ever touched by the real-time thread (tests drive it directly).
struct LegacyABProcessor: ~Copyable {
    static var maximumSections: Int { 16 }

    /// Sample rate the processor was configured for.
    let sampleRate: Double
    /// Largest block `process` handles in one pass (longer blocks are split).
    let maximumFrames: Int
    /// Length of the bank crossfade in samples.
    let crossfadeFrames: Int
    private let inverseCrossfadeFrames: Double

    // Two banks (index 0/1), each `maximumSections` long.
    private let bankSections: UnsafeMutablePointer<LegacySection>
    private let bankCounts: UnsafeMutablePointer<Int>
    private let bankStates: UnsafeMutablePointer<LegacySectionState>
    // Scratch, `maximumFrames` each: input, active bank, incoming bank.
    private let inputLeft: UnsafeMutablePointer<Double>
    private let inputRight: UnsafeMutablePointer<Double>
    private let activeLeft: UnsafeMutablePointer<Double>
    private let activeRight: UnsafeMutablePointer<Double>
    private let incomingLeft: UnsafeMutablePointer<Double>
    private let incomingRight: UnsafeMutablePointer<Double>

    /// Bank producing the output (0 or 1).
    private(set) var activeBank = 0
    /// True from `beginTransition` until the crossfade has completed.
    private(set) var isTransitioning = false
    /// Silent warm-up samples left before the crossfade starts.
    private(set) var warmupRemaining = 0
    /// Crossfade samples done so far.
    private(set) var crossfadePosition = 0
    /// Diagnostics (RT-written, read by tests).
    private(set) var completedTransitions = 0
    /// Times a bank state was found non-finite and reset (should stay 0).
    private(set) var stateResets = 0

    init(sampleRate: Double, maximumFrames: Int, crossfadeSeconds: Double = 0.020, sections: [LegacySection] = []) {
        self.sampleRate = sampleRate
        self.maximumFrames = max(16, maximumFrames)
        crossfadeFrames = LinearRamp.frames(seconds: crossfadeSeconds, sampleRate: sampleRate)
        inverseCrossfadeFrames = 1 / Double(crossfadeFrames)

        let capacity = 2 * Self.maximumSections
        bankSections = .allocate(capacity: capacity)
        bankSections.initialize(
            repeating: LegacySection(coefficients: .identity, bandIDHigh: 0, bandIDLow: 0, settleFrames: 0),
            count: capacity)
        bankCounts = .allocate(capacity: 2)
        bankCounts.initialize(repeating: 0, count: 2)
        bankStates = .allocate(capacity: capacity)
        bankStates.initialize(repeating: LegacySectionState(), count: capacity)

        let frames = self.maximumFrames
        func scratch() -> UnsafeMutablePointer<Double> {
            let buffer = UnsafeMutablePointer<Double>.allocate(capacity: frames)
            buffer.initialize(repeating: 0, count: frames)
            return buffer
        }
        inputLeft = scratch()
        inputRight = scratch()
        activeLeft = scratch()
        activeRight = scratch()
        incomingLeft = scratch()
        incomingRight = scratch()

        // The initial set goes straight into bank 0 (starts from silence).
        let count = min(sections.count, Self.maximumSections)
        for index in 0..<count { bankSections[index] = sections[index] }
        bankCounts[0] = count
    }

    deinit {
        bankSections.deallocate()
        bankCounts.deallocate()
        bankStates.deallocate()
        inputLeft.deallocate()
        inputRight.deallocate()
        activeLeft.deallocate()
        activeRight.deallocate()
        incomingLeft.deallocate()
        incomingRight.deallocate()
    }

    /// Number of sections in the active bank.
    var activeSectionCount: Int { bankCounts[activeBank] }

    /// The active bank's sections (copy; NOT for the RT thread).
    var activeSections: [LegacySection] {
        (0..<bankCounts[activeBank]).map { bankSections[activeBank * Self.maximumSections + $0] }
    }

    /// Non-RT convenience for tests: same as the pointer version.
    mutating func beginTransition(to sections: [LegacySection]) {
        sections.withUnsafeBufferPointer { buffer in
            beginTransition(to: buffer.baseAddress ?? UnsafePointer(bankSections), count: buffer.count)
        }
    }

    /// Loads `count` sections into the inactive bank and starts the switch
    /// (warm-up, then crossfade). Real-time safe. Must not be called while
    /// `isTransitioning` (the kernel waits; the set stays in the mailbox).
    @inline(__always)
    mutating func beginTransition(to sections: UnsafePointer<LegacySection>, count: Int) {
        let incoming = 1 - activeBank
        let incomingBase = incoming * Self.maximumSections
        let activeBase = activeBank * Self.maximumSections
        let activeCount = bankCounts[activeBank]
        let newCount = min(max(0, count), Self.maximumSections)

        var warmup = 0
        var differs = false
        for index in 0..<newCount {
            let section = sections[index]
            bankSections[incomingBase + index] = section
            // Carry over the state of the same band, if it exists.
            var state = LegacySectionState()
            for other in 0..<activeCount {
                let candidate = bankSections[activeBase + other]
                if candidate.bandIDHigh == section.bandIDHigh && candidate.bandIDLow == section.bandIDLow {
                    state = bankStates[activeBase + other]
                    break
                }
            }
            bankStates[incomingBase + index] = state
            // From the first difference on, the carried state doesn't fit.
            if !differs && (index >= activeCount || bankSections[activeBase + index] != section) {
                differs = true
            }
            if differs && section.settleFrames > warmup { warmup = section.settleFrames }
        }
        bankCounts[incoming] = newCount
        warmupRemaining = warmup
        crossfadePosition = 0
        isTransitioning = true
    }

    /// Processes `frameCount` samples per channel from `input` into `output`
    /// (they may be the same buffers).
    @inline(__always)
    mutating func process(
        inputLeft sourceLeft: UnsafePointer<Float>, inputRight sourceRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var done = 0
        while done < frameCount {
            let count = min(maximumFrames, frameCount - done)
            processBlock(
                sourceLeft + done, sourceRight + done, outputLeft + done, outputRight + done, count)
            done += count
        }
    }

    @inline(__always)
    private mutating func processBlock(
        _ sourceLeft: UnsafePointer<Float>, _ sourceRight: UnsafePointer<Float>,
        _ outputLeft: UnsafeMutablePointer<Float>, _ outputRight: UnsafeMutablePointer<Float>,
        _ count: Int
    ) {
        // Float -> Double; a NaN/Inf input sample must never enter the IIR
        // state (it would stay there forever): it becomes 0 for the filters.
        // (The dry path keeps it and the kernel's NaN guard silences it.)
        for frame in 0..<count {
            let left = Double(sourceLeft[frame]), right = Double(sourceRight[frame])
            inputLeft[frame] = left.isFinite ? left : 0
            inputRight[frame] = right.isFinite ? right : 0
        }

        runBank(activeBank, count, activeLeft, activeRight)
        guard isTransitioning else {
            for frame in 0..<count {
                outputLeft[frame] = Float(activeLeft[frame])
                outputRight[frame] = Float(activeRight[frame])
            }
            return
        }

        let incoming = 1 - activeBank
        runBank(incoming, count, incomingLeft, incomingRight)
        for frame in 0..<count {
            var left = activeLeft[frame], right = activeRight[frame]
            if warmupRemaining > 0 {
                warmupRemaining -= 1  // incoming bank still silent
            } else if isTransitioning {
                crossfadePosition += 1
                let t = Double(crossfadePosition) * inverseCrossfadeFrames
                let weight = crossfadePosition >= crossfadeFrames ? 1 : t * t * (3 - 2 * t)
                left += weight * (incomingLeft[frame] - left)
                right += weight * (incomingRight[frame] - right)
                if crossfadePosition >= crossfadeFrames {
                    isTransitioning = false
                    activeBank = incoming
                    completedTransitions &+= 1
                }
            } else {
                left = incomingLeft[frame]  // switch completed inside this block
                right = incomingRight[frame]
            }
            outputLeft[frame] = Float(left)
            outputRight[frame] = Float(right)
        }
    }

    /// Runs bank `bank` over the converted input into `left`/`right`.
    @inline(__always)
    private mutating func runBank(
        _ bank: Int, _ count: Int, _ left: UnsafeMutablePointer<Double>, _ right: UnsafeMutablePointer<Double>
    ) {
        for frame in 0..<count {
            left[frame] = inputLeft[frame]
            right[frame] = inputRight[frame]
        }
        let base = bank * Self.maximumSections
        var healthy = true
        for index in 0..<bankCounts[bank] {
            let c = bankSections[base + index].coefficients
            var s = bankStates[base + index]
            for frame in 0..<count {
                let xl = left[frame], xr = right[frame]
                let yl = c.b0 * xl + s.left1
                let yr = c.b0 * xr + s.right1
                s.left1 = c.b1 * xl - c.a1 * yl + s.left2
                s.right1 = c.b1 * xr - c.a1 * yr + s.right2
                s.left2 = c.b2 * xl - c.a2 * yl
                s.right2 = c.b2 * xr - c.a2 * yr
                left[frame] = yl
                right[frame] = yr
            }
            // Flush values that are decaying towards denormals (silence).
            s.left1 = Self.flush(s.left1)
            s.left2 = Self.flush(s.left2)
            s.right1 = Self.flush(s.right1)
            s.right2 = Self.flush(s.right2)
            if !(s.left1.isFinite && s.left2.isFinite && s.right1.isFinite && s.right2.isFinite) { healthy = false }
            bankStates[base + index] = s
        }
        if !healthy {
            // Cannot happen with valid coefficients and finite input; if it
            // ever does, recover instead of staying silent forever.
            for index in 0..<Self.maximumSections { bankStates[base + index] = LegacySectionState() }
            for frame in 0..<count {
                left[frame] = 0
                right[frame] = 0
            }
            stateResets &+= 1
        }
    }

    @inline(__always)
    private static func flush(_ value: Double) -> Double {
        value.magnitude < 1e-30 ? 0 : value
    }
}
