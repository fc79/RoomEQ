// EXPERIMENT "option 1" (split architecture): capture and output on two
// separate Core Audio objects, never resampling.
//
//   capture: device tap (no mixdown, device's own format) inside a private
//            aggregate that contains ONLY the tap (no sub-devices, drift off);
//   output:  an IOProc directly on the physical device.
//
// The tapped device is never a sub-device of an aggregate, so the
// "IOContext is already registered" failure (device tap + same device as
// sub-device) cannot happen. During the experiment the output IOProc writes
// SILENCE only and the tap is .unmuted: the user keeps hearing normal audio.
// Both IOProcs only record timing into preallocated traces (CallbackTracer).
//
// Per physical output device: 20 s at buffer 128, then (if that worked)
// 10 s at 64. Results: log (Default level), panel summary, and
// ~/Library/Logs/RoomEQ/split-experiment.txt.
//
// Runs on the engine queue (blocking, ~30 s per device), only when no engine
// session exists.

import CoreAudio
import Darwin
import Foundation
import RoomEQCore

// MARK: - Real-time callbacks (record only)

private func splitCaptureProc(
    _ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>?, _ input: UnsafePointer<AudioBufferList>?,
    _ inputTime: UnsafePointer<AudioTimeStamp>?, _ output: UnsafeMutablePointer<AudioBufferList>?,
    _ outputTime: UnsafePointer<AudioTimeStamp>?, _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    CallbackTracer.recordCapture(
        clientData.assumingMemoryBound(to: CallbackTrace.self), now: now, stamp: inputTime, input: input,
        output: output)
    return noErr
}

private func splitOutputProc(
    _ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>?, _ input: UnsafePointer<AudioBufferList>?,
    _ inputTime: UnsafePointer<AudioTimeStamp>?, _ output: UnsafeMutablePointer<AudioBufferList>?,
    _ outputTime: UnsafePointer<AudioTimeStamp>?, _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    CallbackTracer.recordOutput(
        clientData.assumingMemoryBound(to: CallbackTrace.self), now: now, stamp: outputTime, output: output)
    return noErr
}

// MARK: - Results

/// One timed run (one buffer size) on one device.
struct SplitRunReport {
    var bufferRequested = 0
    var seconds = 0
    var captureBuffer = 0, outputBuffer = 0
    var captureNominal = 0.0, captureActual = 0.0
    var deviceNominal = 0.0, deviceActual = 0.0
    var captureSafety = 0, captureLatency = 0, tapStreamLatency = 0
    var outputSafety = 0, outputLatency = 0, outputStreamLatency = 0
    var capture: CallbackTraceSnapshot?
    var output: CallbackTraceSnapshot?
    var captureClock: ClockEstimate?
    var outputClock: ClockEstimate?
    var driftPPM: Double?
    var sampleOffsetFrames: Double?
    var ring: RingEstimate?
    var projectedMilliseconds: Double?
    var error: String?

    var passed: Bool {
        error == nil && (capture?.callbacks ?? 0) > 10 && (output?.callbacks ?? 0) > 10
    }

    var peakDecibels: Double {
        Decibels.decibels(fromLinear: Double(capture?.peak ?? 0))
    }

    var detail: String {
        if let error { return "buffer \(bufferRequested), \(seconds) s: ERROR \(error)" }
        func clock(_ c: ClockEstimate?) -> String {
            c.map { String(format: "%.4f Hz (first/last %.4f, %d pts, %.1f s)", $0.rate, $0.firstLastRate, $0.points, $0.durationSeconds) } ?? "n/a"
        }
        func frames(_ t: CallbackTraceSnapshot?) -> String {
            guard let t, let s = SplitAnalysis.frameStats(t) else { return "n/a" }
            return "\(t.callbacks) callbacks, frames \(s.min)-\(s.max) (mean \(String(format: "%.1f", s.mean))), invalid stamps \(t.invalidStamps), missing buffers \(t.missingBuffers)"
        }
        let ringText = ring.map {
            String(format: "alignment %d, delay mean %.1f / max %.1f frames over %d reads", $0.alignmentFrames, $0.meanDelayFrames, $0.maxDelayFrames, $0.outputEvents)
        } ?? "n/a"
        return "buffer \(bufferRequested) (capture \(captureBuffer), output \(outputBuffer)), \(seconds) s\n"
            + "    rates: capture aggregate nominal \(captureNominal) actual \(captureActual); device nominal \(deviceNominal) actual \(deviceActual)\n"
            + "    capture: safety \(captureSafety), device latency \(captureLatency), tap stream latency \(tapStreamLatency); \(frames(capture)); clock \(clock(captureClock))\n"
            + "    output: safety \(outputSafety), device latency \(outputLatency), stream latency \(outputStreamLatency); \(frames(output)); clock \(clock(outputClock))\n"
            + "    drift \(driftPPM.map { String(format: "%.3f", $0) } ?? "n/a") ppm; sample-time offset capture-output at mid-run \(sampleOffsetFrames.map { String(format: "%.1f", $0) } ?? "n/a") frames\n"
            + "    ring: \(ringText)\n"
            + "    projected end-to-end latency \(projectedMilliseconds.map { String(format: "%.2f", $0) } ?? "n/a") ms; tap peak \(String(format: "%.1f", peakDecibels)) dBFS"
    }
}

/// Everything about one device.
struct SplitDeviceReport {
    let deviceName: String
    var setup: [String] = []
    var tapFormat: AudioStreamBasicDescription?
    var captureVariant: String?
    var captureAttempts: [String] = []
    var outputStart = "—"
    var runs: [SplitRunReport] = []
    var error: String?

    /// e.g. "Quantum LT 16: avvio OK (variante a), deriva 0,1 ppm, latenza prevista 6,8 ms, livello −20 dB".
    var summary: String {
        if let error { return "\(deviceName): \(error)" }
        guard let variant = captureVariant else {
            return "\(deviceName): cattura non avviata (\(captureAttempts.joined(separator: "; ")))"
        }
        guard let run = runs.first else { return "\(deviceName): nessuna misura" }
        if let error = run.error { return "\(deviceName): variante \(variant), errore \(error)" }
        var text = "\(deviceName): avvio OK (variante \(variant))"
        if let drift = run.driftPPM { text += ", deriva \(Self.italian(drift, digits: 1)) ppm" }
        if let ms = run.projectedMilliseconds { text += ", latenza prevista \(Self.italian(ms, digits: 1)) ms" }
        if let second = runs.dropFirst().first, second.passed, let ms = second.projectedMilliseconds {
            text += " (\(Self.italian(ms, digits: 1)) ms a 64)"
        }
        text += ", livello \(Self.italian(run.peakDecibels, digits: 0)) dB"
        if let format = tapFormat {
            text += ", tap \(AudioFormatText.summary(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame)))"
        }
        return text
    }

    var detail: String {
        var lines = ["== \(deviceName)"] + setup.map { "  " + $0 }
        lines.append("  tap format: \(tapFormat?.logDescription ?? "n/a")")
        lines.append("  capture attempts: \(captureAttempts.joined(separator: "; "))")
        lines.append("  output IOProc start: \(outputStart)")
        if let error { lines.append("  ERROR: \(error)") }
        for run in runs { lines.append("  run " + run.detail) }
        return lines.joined(separator: "\n")
    }

    static func italian(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
            .replacingOccurrences(of: "-", with: "−")
    }
}

// MARK: - Experiment

enum SplitExperiment {
    static let reportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RoomEQ/split-experiment.txt")

    /// Host ticks per second (mach timebase).
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000_000 * Double(info.denom) / Double(info.numer)
    }()

    /// Runs on every physical output device. `progress` is called (engine
    /// queue) with a short Italian status. Blocking.
    static func run(excludedBundleIDs: [String], progress: (String) -> Void) -> String {
        let devices = AudioDevices.physicalOutputDevices()
        Log.engine.notice("Split experiment on \(devices.map(\.name), privacy: .public)")
        var reports: [SplitDeviceReport] = []
        for (index, device) in devices.enumerated() {
            progress("Esperimento \(index + 1)/\(devices.count): \(device.name)… (riproduci musica)")
            let report = runDevice(device, excludedBundleIDs: excludedBundleIDs, progress: progress)
            Log.engine.notice("Split experiment result: \(report.summary, privacy: .public)")
            Log.engine.notice("Split experiment detail:\n\(report.detail, privacy: .public)")
            reports.append(report)
        }
        if devices.isEmpty { return "Nessun dispositivo di uscita fisico trovato" }
        writeReport(reports)
        return reports.map(\.summary).joined(separator: "\n")
    }

    private static func runDevice(
        _ device: OutputDeviceInfo, excludedBundleIDs: [String], progress: (String) -> Void
    ) -> SplitDeviceReport {
        var report = SplitDeviceReport(deviceName: device.name)
        var tap: ProcessTap?
        var aggregate: AggregateDevice?
        var captureProc: AudioDeviceIOProcID?
        var outputProc: AudioDeviceIOProcID?
        let captureTrace = CallbackTraceHandle(capacity: 32_768)
        let outputTrace = CallbackTraceHandle(capacity: 32_768)
        defer {
            if let aggregate, let captureProc {
                AudioDeviceStop(aggregate.objectID, captureProc)
                AudioDeviceDestroyIOProcID(aggregate.objectID, captureProc)
            }
            if let outputProc {
                AudioDeviceStop(device.objectID, outputProc)
                AudioDeviceDestroyIOProcID(device.objectID, outputProc)
            }
            aggregate?.destroy()
            tap?.destroy()
            // The traces are released after both IOProcs are destroyed.
            withExtendedLifetime((captureTrace, outputTrace)) {}
        }

        // 1. Which output stream holds the preferred stereo channels?
        let preferred = AudioDevices.preferredStereoChannels(of: device.objectID)
        let streams = (try? DeviceStreams.streams(of: device.objectID, scope: kAudioObjectPropertyScopeOutput)) ?? []
        let leftChannel = preferred?.0 ?? 1
        var streamIndex = 0, firstChannel = 1
        for (index, stream) in streams.enumerated() {
            let count = Int(stream.format.mChannelsPerFrame)
            if leftChannel >= firstChannel && leftChannel < firstChannel + count { streamIndex = index; break }
            firstChannel += count
        }
        report.setup.append("UID \(device.uid), nominal \((try? AudioDevices.nominalSampleRate(of: device.objectID)) ?? 0) Hz")
        report.setup.append("preferred stereo (output scope): \(preferred.map { "\($0.0)/\($0.1)" } ?? "not reported, using 1/2")")
        report.setup.append(
            "output streams: " + streams.enumerated().map { "#\($0.offset) \($0.element.format.mChannelsPerFrame) ch \($0.element.format.mSampleRate) Hz" }.joined(separator: ", ")
                + " -> tapping stream \(streamIndex)")

        do {
            // Tap: device stream, no mixdown, unmuted, own process excluded.
            let newTap = try ProcessTap.create(
                excludedBundleIDs: excludedBundleIDs,
                target: .device(uid: device.uid, stream: UInt(streamIndex), mixdown: false), muteBehavior: .unmuted)
            tap = newTap
            report.tapFormat = try newTap.format()

            // 2. Capture side: try the variants until one starts.
            for variant in AggregateDevice.TapOnlyVariant.allCases {
                let attempt = startCapture(
                    tap: newTap, device: device, variant: variant, trace: captureTrace, buffer: 128)
                report.captureAttempts.append("\(variant.rawValue): \(attempt.result)")
                if let started = attempt.started {
                    aggregate = started.aggregate
                    captureProc = started.proc
                    report.captureVariant = variant.rawValue
                    break
                }
            }
            guard let aggregate, let captureProc else { return report }

            // 3. Output side: IOProc on the physical device, silence only.
            var procID: AudioDeviceIOProcID?
            let proc = unsafeBitCast(splitOutputProc as NullableIOProc, to: AudioDeviceIOProc.self)
            try AudioObject.check(
                AudioDeviceCreateIOProcID(device.objectID, proc, outputTrace.rawPointer, &procID),
                "Creazione IOProc di uscita")
            guard let procID else { throw EngineError("IOProc di uscita: ID mancante") }
            outputProc = procID
            // Never read the device's hardware inputs (avoids a microphone request).
            let inputStreams = (try? DeviceStreams.streams(of: device.objectID, scope: kAudioObjectPropertyScopeInput)) ?? []
            if !inputStreams.isEmpty {
                try? DeviceStreams.setInputStreamUsage(
                    device: device.objectID, ioProc: procID, enabled: Array(repeating: false, count: inputStreams.count))
            }

            // 4. Timed runs.
            for (buffer, seconds) in [(128, 20), (64, 10)] {
                if buffer == 64 && !(report.runs.last?.passed ?? false) { break }
                progress("\(device.name): buffer \(buffer), \(seconds) s… (riproduci musica)")
                var run = SplitRunReport()
                run.bufferRequested = buffer
                run.seconds = seconds
                captureTrace.reset()
                outputTrace.reset()
                try? aggregate.setBufferFrameSize(buffer)
                try? AudioObject.write(
                    device.objectID, AudioObject.address(kAudioDevicePropertyBufferFrameSize), value: UInt32(buffer),
                    "Buffer uscita")
                let captureStatus = AudioDeviceStart(aggregate.objectID, captureProc)
                let outputStatus = AudioDeviceStart(device.objectID, procID)
                report.outputStart = outputStatus == noErr ? "OK" : describeOSStatus(outputStatus)
                if captureStatus != noErr || outputStatus != noErr {
                    run.error = "avvio cattura \(describeOSStatus(captureStatus)), uscita \(describeOSStatus(outputStatus))"
                    AudioDeviceStop(aggregate.objectID, captureProc)
                    AudioDeviceStop(device.objectID, procID)
                    report.runs.append(run)
                    break
                }
                Thread.sleep(forTimeInterval: 1)
                readProperties(into: &run, aggregate: aggregate, device: device, streamIndex: streamIndex)
                Thread.sleep(forTimeInterval: Double(seconds - 1))
                AudioDeviceStop(aggregate.objectID, captureProc)
                AudioDeviceStop(device.objectID, procID)
                analyze(&run, capture: captureTrace.snapshot(), output: outputTrace.snapshot())
                report.runs.append(run)
            }
        } catch {
            report.error = error.localizedDescription
        }
        return report
    }

    /// Creates a capture-only aggregate in `variant`, an IOProc, and starts
    /// it briefly to see whether it runs. Returns the started objects (IO
    /// stopped again) or nil with the reason.
    private static func startCapture(
        tap: ProcessTap, device: OutputDeviceInfo, variant: AggregateDevice.TapOnlyVariant,
        trace: CallbackTraceHandle, buffer: Int
    ) -> (started: (aggregate: AggregateDevice, proc: AudioDeviceIOProcID)?, result: String) {
        let aggregate: AggregateDevice
        do {
            aggregate = try AggregateDevice.createTapOnly(tapUID: tap.uid, deviceUID: device.uid, variant: variant)
        } catch let error as CoreAudioError {
            return (nil, "creazione fallita \(describeOSStatus(error.status))")
        } catch {
            return (nil, "creazione fallita")
        }
        // Must never contain the tapped device as a sub-device.
        let subDevices = aggregate.activeSubDeviceIDs()
        guard subDevices.isEmpty else {
            aggregate.destroy()
            return (nil, "saltata: il dispositivo è diventato sub-device (\(subDevices))")
        }
        // Wait (monotonic clock, max 2 s) for the tap's input stream.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        var inputStreams: [StreamInfo] = []
        while clock.now < deadline {
            inputStreams = (try? DeviceStreams.streams(of: aggregate.objectID, scope: kAudioObjectPropertyScopeInput)) ?? []
            if !inputStreams.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !inputStreams.isEmpty else {
            aggregate.destroy()
            return (nil, "nessuno stream di ingresso")
        }
        var procID: AudioDeviceIOProcID?
        let proc = unsafeBitCast(splitCaptureProc as NullableIOProc, to: AudioDeviceIOProc.self)
        let createStatus = AudioDeviceCreateIOProcID(aggregate.objectID, proc, trace.rawPointer, &procID)
        guard createStatus == noErr, let procID else {
            aggregate.destroy()
            return (nil, "IOProc \(describeOSStatus(createStatus))")
        }
        try? aggregate.setBufferFrameSize(buffer)
        let startStatus = AudioDeviceStart(aggregate.objectID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregate.objectID, procID)
            aggregate.destroy()
            return (nil, "avvio fallito \(describeOSStatus(startStatus))")
        }
        AudioDeviceStop(aggregate.objectID, procID)
        let format = inputStreams[0].format
        return ((aggregate, procID), "avvio OK, stream \(format.mChannelsPerFrame) ch \(format.mSampleRate) Hz")
    }

    private static func readProperties(
        into run: inout SplitRunReport, aggregate: AggregateDevice, device: OutputDeviceInfo, streamIndex: Int
    ) {
        let input = kAudioObjectPropertyScopeInput, output = kAudioObjectPropertyScopeOutput
        run.captureBuffer = (try? aggregate.bufferFrameSize()) ?? 0
        run.captureNominal = (try? aggregate.nominalSampleRate()) ?? 0
        run.captureActual = AudioDevices.actualSampleRate(of: aggregate.objectID)
        run.captureSafety = aggregate.safetyOffset(scope: input)
        run.captureLatency = aggregate.deviceLatency(scope: input)
        if let tapStream = (try? DeviceStreams.streams(of: aggregate.objectID, scope: input))?.first {
            run.tapStreamLatency = DeviceStreams.latency(ofStream: tapStream.objectID)
        }
        run.outputBuffer = Int(
            (try? AudioObject.read(
                device.objectID, AudioObject.address(kAudioDevicePropertyBufferFrameSize), initial: UInt32(0),
                "Buffer uscita")) ?? 0)
        run.deviceNominal = (try? AudioDevices.nominalSampleRate(of: device.objectID)) ?? 0
        run.deviceActual = AudioDevices.actualSampleRate(of: device.objectID)
        run.outputSafety = readFrames(device.objectID, kAudioDevicePropertySafetyOffset, output)
        run.outputLatency = readFrames(device.objectID, kAudioDevicePropertyLatency, output)
        let streams = (try? DeviceStreams.streams(of: device.objectID, scope: output)) ?? []
        if streams.indices.contains(streamIndex) {
            run.outputStreamLatency = DeviceStreams.latency(ofStream: streams[streamIndex].objectID)
        }
    }

    private static func readFrames(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope
    ) -> Int {
        Int((try? AudioObject.read(object, AudioObject.address(selector, scope), initial: UInt32(0), "frames")) ?? 0)
    }

    private static func analyze(_ run: inout SplitRunReport, capture: CallbackTraceSnapshot, output: CallbackTraceSnapshot) {
        run.capture = capture
        run.output = output
        let skip = 20  // ignore start-up callbacks in the clock fit
        run.captureClock = SplitAnalysis.clock(capture, ticksPerSecond: ticksPerSecond, skip: min(skip, max(0, capture.stampHost.count - 2)))
        run.outputClock = SplitAnalysis.clock(output, ticksPerSecond: ticksPerSecond, skip: min(skip, max(0, output.stampHost.count - 2)))
        if let c = run.captureClock, let o = run.outputClock {
            run.driftPPM = SplitAnalysis.driftPPM(capture: c.rate, output: o.rate)
            if let first = capture.stampHost.first, let last = capture.stampHost.last {
                let middle = first / 2 + last / 2
                run.sampleOffsetFrames = c.sampleTime(atHost: middle) - o.sampleTime(atHost: middle)
            }
        }
        let rate = run.deviceNominal > 0 ? run.deviceNominal : 44100
        run.ring = SplitAnalysis.ring(
            capture: capture, output: output, warmupTicks: UInt64(0.5 * ticksPerSecond),
            ticksPerSecond: ticksPerSecond, sampleRate: rate)
        if let ring = run.ring {
            run.projectedMilliseconds = SplitAnalysis.projectedLatencyMilliseconds(
                sampleRate: rate, tapStreamLatency: run.tapStreamLatency, captureSafetyOffset: run.captureSafety,
                captureBuffer: run.captureBuffer, ringFrames: Int(ring.meanDelayFrames.rounded(.up)),
                outputBuffer: run.outputBuffer, outputSafetyOffset: run.outputSafety,
                outputDeviceLatency: run.outputLatency, outputStreamLatency: run.outputStreamLatency)
        }
        if !run.passed && run.error == nil {
            run.error = "callback insufficienti (cattura \(capture.callbacks), uscita \(output.callbacks))"
        }
    }

    private static func writeReport(_ reports: [SplitDeviceReport]) {
        let header = [
            "RoomEQ split experiment (option 1) — \(Date().formatted(.iso8601))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), host ticks/s \(ticksPerSecond)",
            "Capture: device tap (no mixdown, unmuted) in a tap-only private aggregate (drift off).",
            "Output: IOProc on the physical device writing silence. No audio routed.",
            "",
        ]
        let text = (header + reports.map(\.summary) + [""] + reports.map(\.detail)).joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: reportURL, atomically: true, encoding: .utf8)
            Log.engine.notice("Split experiment written to \(reportURL.path, privacy: .public)")
        } catch {
            Log.engine.error("Split experiment file not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
