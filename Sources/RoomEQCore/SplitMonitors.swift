// Engine-side decisions for the split engine (pure, unit-tested). The
// engine evaluates them on its own queue (~every 100 ms), never on the
// real-time threads.
//
// Safety principle: whenever RoomEQ cannot deliver audio, it must release
// the tap promptly (stop -> the tapped apps are unmuted) with a clear
// (localized) error, instead of keeping apps muted while outputting silence
// for more than about a second.

import Foundation

// MARK: - Health

/// Detects stalls and persistent unplayable output.
public struct SplitHealthMonitor: Sendable {
    public enum Problem: Equatable, Sendable {
        /// Capture keeps running but the output IOProc stopped being called.
        case outputStalled
        /// The output runs but the capture IOProc stopped (no new audio).
        case captureStalled
        /// Neither side is being called.
        case ioStalled
        /// Most output cycles could not play (invalid, overwritten, gap).
        case badCycles

        /// Message for the UI (localized).
        public var message: String {
            switch self {
            case .outputStalled:
                String(localized: "L'uscita audio si è bloccata: RoomEQ si ferma per non lasciare le app mute.")
            case .captureStalled:
                String(localized: "La cattura dell'audio si è bloccata: RoomEQ si ferma per non lasciare le app mute.")
            case .ioStalled:
                String(localized: "L'audio non viene più elaborato: RoomEQ si ferma per non lasciare le app mute.")
            case .badCycles:
                String(localized: "L'audio non può essere riprodotto correttamente: RoomEQ si ferma per non lasciare le app mute.")
            }
        }
    }

    public let stallSeconds: Double
    public let idleSeconds: Double
    public let badSeconds: Double
    private var last: (capture: UInt64, output: UInt64, bad: UInt64)?
    private var outputStill = 0.0, captureStill = 0.0, bothStill = 0.0, badTime = 0.0

    public init(stallSeconds: Double = 0.5, idleSeconds: Double = 1.0, badSeconds: Double = 0.5) {
        self.stallSeconds = stallSeconds
        self.idleSeconds = idleSeconds
        self.badSeconds = badSeconds
    }

    /// Feed cumulative counters; `elapsed` = seconds since the previous call.
    public mutating func update(
        captureCycles: UInt64, outputCycles: UInt64, badOutputCycles: UInt64, elapsed: Double
    ) -> Problem? {
        defer { last = (captureCycles, outputCycles, badOutputCycles) }
        guard let last else { return nil }
        let capture = captureCycles &- last.capture
        let output = outputCycles &- last.output
        let bad = badOutputCycles &- last.bad

        if capture == 0 && output == 0 {
            bothStill += elapsed
            outputStill = 0; captureStill = 0
        } else {
            bothStill = 0
            outputStill = output == 0 ? outputStill + elapsed : 0
            captureStill = capture == 0 ? captureStill + elapsed : 0
        }
        badTime = output > 0 && bad * 2 >= output ? badTime + elapsed : (output > 0 ? 0 : badTime)

        if bothStill >= idleSeconds { return .ioStalled }
        if outputStill >= stallSeconds { return .outputStalled }
        if captureStill >= stallSeconds { return .captureStalled }
        if badTime >= badSeconds { return .badCycles }
        return nil
    }
}

// MARK: - Drift

/// Watches the mean `need` (how far ahead of the captured data the output
/// reads, independent of the chosen delay). With both sides on one clock it
/// stays constant; a trend means the clocks differ, which RoomEQ does not
/// compensate (no resampling).
public struct DriftMonitor: Sendable {
    public static let message = String(
        localized: "Gli orologi di cattura e uscita non coincidono: RoomEQ non converte la frequenza, quindi si ferma.")

    public let sampleRate: Double
    public let bufferFrames: Int
    public let ppmLimit: Double
    public let minimumWindow: Double
    public let maximumWindow: Double
    private var samples: [(time: Double, need: Double)] = []
    private var baseline: Double?

    public init(
        sampleRate: Double, bufferFrames: Int, ppmLimit: Double = 5, minimumWindow: Double = 30,
        maximumWindow: Double = 120
    ) {
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.ppmLimit = ppmLimit
        self.minimumWindow = minimumWindow
        self.maximumWindow = maximumWindow
    }

    /// Trend of `need` in ppm of the sample rate (nil until the window is
    /// long enough).
    public var trendPPM: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= minimumWindow,
            sampleRate > 0
        else { return nil }
        let n = Double(samples.count)
        let meanT = samples.reduce(0) { $0 + $1.time } / n
        let meanN = samples.reduce(0) { $0 + $1.need } / n
        var sxy = 0.0, sxx = 0.0
        for sample in samples {
            sxy += (sample.time - meanT) * (sample.need - meanN)
            sxx += (sample.time - meanT) * (sample.time - meanT)
        }
        guard sxx > 0 else { return nil }
        return sxy / sxx / sampleRate * 1_000_000
    }

    /// Change of the recent mean `need` against the first seconds (frames).
    public var lagChange: Double? {
        guard let baseline, samples.count >= 2 else { return nil }
        let recent = samples.suffix(2)
        return recent.reduce(0) { $0 + $1.need } / Double(recent.count) - baseline
    }

    /// Adds the mean `need` of the last interval at time `time` (seconds
    /// since start). Returns true when the clocks must be considered
    /// different: a sustained trend above `ppmLimit`, or the mean moved by
    /// more than one buffer.
    public mutating func add(meanNeed: Double, at time: Double) -> Bool {
        samples.append((time, meanNeed))
        while let first = samples.first, time - first.time > maximumWindow { samples.removeFirst() }
        if baseline == nil && samples.count >= 2 {
            baseline = samples.prefix(2).reduce(0) { $0 + $1.need } / 2
        }
        if let change = lagChange, abs(change) > Double(bufferFrames) { return true }
        if let trend = trendPPM, abs(trend) > ppmLimit { return true }
        return false
    }
}

// MARK: - Warm-up and delay

public enum WarmupAnalysis {
    /// (min, median, max) of the measured `need` values.
    public static func statistics(_ needs: [Int64]) -> (min: Int64, median: Int64, max: Int64)? {
        guard !needs.isEmpty else { return nil }
        let sorted = needs.sorted()
        return (sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1])
    }

    /// True if both sides ran normally during the window: each advanced by at
    /// least 70% of the expected cycles, and no discontinuity, overload or
    /// invalid cycle happened. Otherwise the measurement is repeated.
    public static func windowIsClean(before: SplitLinkStatus, after: SplitLinkStatus, expectedCycles: Double) -> Bool {
        let minimum = UInt64(max(1, (expectedCycles * 0.7).rounded(.down)))
        return after.captureCycles &- before.captureCycles >= minimum
            && after.outputCycles &- before.outputCycles >= minimum
            && after.discontinuities == before.discontinuities
            && after.captureOverloads == before.captureOverloads
            && after.captureInvalidCycles == before.captureInvalidCycles
            && after.outputInvalidCycles == before.outputInvalidCycles
    }
}

public enum DelayPolicy {
    /// Initial delay: worst measured need + one full block (covers the two
    /// IOProcs being called in the other order). Fails (localized message)
    /// instead of clamping when it exceeds `maximum`.
    public static func initialDelay(maxNeed: Int64, block: Int, maximum: Int) -> Result<Int64, DelayError> {
        let delay = max(1, maxNeed + Int64(block))
        guard delay <= Int64(maximum) else { return .failure(DelayError(needed: delay, maximum: maximum)) }
        return .success(delay)
    }

    public struct DelayError: Error, Equatable, Sendable {
        public let needed: Int64
        public let maximum: Int
        public var message: String {
            String(
                localized: "Il ritardo necessario (\(needed) frame) supera il massimo consentito (\(maximum) frame): RoomEQ non si avvia.")
        }
    }
}

/// Grows the delay by one block when underruns happen, a limited number of
/// times; beyond that the engine must stop.
public struct DelayAdaptation: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case increase(to: Int64)
        /// Cap reached (or no room left) and underruns continue.
        case fail
    }

    public static let failureMessage = String(
        localized: "RoomEQ non riesce a mantenere l'audio continuo (interruzioni ripetute): si ferma per non lasciare le app mute.")

    public let maximumIncreases: Int
    public private(set) var increases = 0

    public init(maximumIncreases: Int) {
        self.maximumIncreases = maximumIncreases
    }

    public mutating func evaluate(newUnderruns: UInt64, currentDelay: Int64, block: Int, maximum: Int) -> Action {
        guard newUnderruns > 0 else { return .none }
        let next = currentDelay + Int64(block)
        guard increases < maximumIncreases, next <= Int64(maximum) else { return .fail }
        increases += 1
        return .increase(to: next)
    }
}
