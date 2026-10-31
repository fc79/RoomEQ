// One-click diagnostic: which tap configuration gives which format/latency?
//
// For each configuration it creates a PRIVATE tap with muteBehavior .unmuted
// (nothing is ever silenced) and the usual exclusions (own process
// included), reads its format, puts it in a private aggregate with the
// output device (no IOProc, IO never started), reads formats, safety offsets
// and latencies, tries the format experiments, then destroys everything.
// Results go to the log (Default level), to the panel (compact) and to
// ~/Library/Logs/RoomEQ/tap-diagnostic.txt.
//
// Runs on the engine queue, only when no engine session exists.

import CoreAudio
import Foundation
import RoomEQCore

struct TapProbeConfiguration {
    let id: String
    let label: String
    let target: TapTarget
    let driftCompensation: Bool
}

struct TapProbeResult {
    let configuration: TapProbeConfiguration
    var tapFormat: AudioStreamBasicDescription?
    var formatSettable = false
    var formatSetReport = "—"
    var tapFormatInAggregate: AudioStreamBasicDescription?
    var tapStreamFormat: AudioStreamBasicDescription?
    var tapStreamAvailableRates: [String] = []
    var streamFormatReport = "—"
    var aggregateRate: Double = 0
    var safetyIn = 0, safetyOut = 0
    var latencyIn = 0, latencyOut = 0
    var tapStreamLatency = 0, outputStreamLatency = 0
    var identification = "—"
    var error: String?

    /// One line for the panel, e.g. "b) disp.+mix, drift: 48 kHz·2ch, saft 902/909".
    var summary: String {
        let head = "\(configuration.id)) \(configuration.label)"
        if let error { return "\(head): errore — \(error)" }
        let format = tapFormat.map { Self.short($0) } ?? "?"
        var text = "\(head): \(format), saft \(safetyIn)/\(safetyOut)"
        if formatSettable { text += ", formato tap: \(formatSetReport)" }
        if streamFormatReport != "—" { text += ", stream: \(streamFormatReport)" }
        return text
    }

    /// Full line for the log and the file.
    var detail: String {
        let head = "[\(configuration.id)] \(configuration.label) (\(configuration.target.description), drift \(configuration.driftCompensation))"
        if let error { return "\(head): ERROR \(error)" }
        return head
            + ": tap format \(tapFormat?.logDescription ?? "?")"
            + " | tap format settable \(formatSettable): \(formatSetReport)"
            + " | tap format after aggregate \(tapFormatInAggregate?.logDescription ?? "?")"
            + " | tap stream in aggregate \(tapStreamFormat?.logDescription ?? "?") (\(identification))"
            + " | tap stream available rates [\(tapStreamAvailableRates.joined(separator: ", "))]"
            + " | tap stream virtual format: \(streamFormatReport)"
            + " | aggregate \(aggregateRate) Hz, safety in \(safetyIn) out \(safetyOut)"
            + ", device latency in \(latencyIn) out \(latencyOut)"
            + ", stream latency tap \(tapStreamLatency) out \(outputStreamLatency)"
    }

    static func short(_ format: AudioStreamBasicDescription) -> String {
        AudioFormatText.summary(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame))
            .replacingOccurrences(of: " · ", with: "·")
    }
}

enum TapDiagnostics {
    static let reportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RoomEQ/tap-diagnostic.txt")

    static func configurations(deviceUID: String) -> [TapProbeConfiguration] {
        [
            .init(id: "a", label: "globale, drift", target: .global, driftCompensation: true),
            .init(id: "b", label: "disp.+mix, drift", target: .device(uid: deviceUID, stream: 0, mixdown: true),
                  driftCompensation: true),
            .init(id: "c", label: "disp. no mix, drift", target: .device(uid: deviceUID, stream: 0, mixdown: false),
                  driftCompensation: true),
            .init(id: "d", label: "disp. no mix, no drift",
                  target: .device(uid: deviceUID, stream: 0, mixdown: false), driftCompensation: false),
            .init(id: "e", label: "globale, no drift", target: .global, driftCompensation: false),
        ]
    }

    /// Runs the whole matrix. Blocks for a few seconds: engine queue only.
    static func run(outputDevice: OutputDeviceInfo, excludedBundleIDs: [String]) -> (summary: String, results: [TapProbeResult]) {
        let deviceRate = (try? AudioDevices.nominalSampleRate(of: outputDevice.objectID)) ?? 0
        let preferred = AudioDevices.preferredStereoChannels(of: outputDevice.objectID)
        var header: [String] = [
            "RoomEQ tap diagnostic — \(Date().formatted(.iso8601))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Output device: \(outputDevice.name) [\(outputDevice.uid)] at \(deviceRate) Hz, "
                + "\(outputDevice.outputChannelCount) out / \(outputDevice.inputChannelCount) in",
            "Preferred stereo channels (output scope): \(preferred.map { "\($0.0)/\($0.1)" } ?? "not reported")",
            "System default output: \(AudioDevices.defaultOutputDeviceUID() ?? "?")",
        ]
        Log.engine.notice("Tap diagnostic started on \(outputDevice.name, privacy: .public) at \(deviceRate) Hz, preferred stereo \(preferred.map { "\($0.0)/\($0.1)" } ?? "n/a", privacy: .public)")

        var results: [TapProbeResult] = []
        for configuration in configurations(deviceUID: outputDevice.uid) {
            let result = probe(configuration, outputDevice: outputDevice, deviceRate: deviceRate, excludedBundleIDs: excludedBundleIDs)
            Log.engine.notice("Tap diagnostic \(result.detail, privacy: .public)")
            results.append(result)
        }

        let matching = results.filter { $0.error == nil && $0.tapFormat?.mSampleRate == deviceRate }
        let verdict =
            matching.isEmpty
            ? "Nessuna configurazione dà un tap a \(AudioFormatText.kilohertz(deviceRate))."
            : "Tap alla frequenza del dispositivo con: \(matching.map(\.configuration.id).joined(separator: ", "))."
        header.append(verdict)
        writeReport(header: header, results: results)
        let summary = (results.map(\.summary) + [verdict]).joined(separator: "\n")
        return (summary, results)
    }

    private static func probe(
        _ configuration: TapProbeConfiguration, outputDevice: OutputDeviceInfo, deviceRate: Double,
        excludedBundleIDs: [String]
    ) -> TapProbeResult {
        var result = TapProbeResult(configuration: configuration)
        var tap: ProcessTap?
        var aggregate: AggregateDevice?
        defer {
            aggregate?.destroy()
            tap?.destroy()
        }
        do {
            let newTap = try ProcessTap.create(
                excludedBundleIDs: excludedBundleIDs, target: configuration.target, muteBehavior: .unmuted)
            tap = newTap
            let format = try newTap.format()
            result.tapFormat = format

            // f) Is the tap format settable? If so, try the device rate.
            result.formatSettable = newTap.isFormatSettable()
            if result.formatSettable {
                if format.mSampleRate == deviceRate {
                    result.formatSetReport = "già a \(AudioFormatText.kilohertz(deviceRate))"
                } else {
                    let attempt = newTap.trySetSampleRate(deviceRate)
                    result.formatSetReport = attempt.report
                    if attempt.succeeded { result.tapFormat = try? newTap.format() }
                }
            } else {
                result.formatSetReport = "non impostabile"
            }

            // Aggregate (no IOProc, IO never started).
            let newAggregate = try AggregateDevice.create(
                mainDeviceUID: outputDevice.uid, tapUID: newTap.uid,
                driftCompensation: configuration.driftCompensation)
            aggregate = newAggregate
            let currentTapFormat = (try? newTap.format()) ?? format
            let layout = try AggregateLayout.waitForLayout(
                aggregate: newAggregate, outputDevice: outputDevice.objectID, tap: newTap, tapFormat: currentTapFormat)
            result.identification = layout.identificationMethod
            result.tapFormatInAggregate = try? newTap.format()
            result.tapStreamFormat = layout.tapStream.format
            result.tapStreamAvailableRates = availableRates(of: layout.tapStream.objectID)

            // h) Try to set the tap stream's virtual format to the device rate.
            let streamID = layout.tapStream.objectID
            let virtualAddress = AudioObject.address(kAudioStreamPropertyVirtualFormat)
            if layout.tapStream.format.mSampleRate == deviceRate {
                result.streamFormatReport = "già a \(AudioFormatText.kilohertz(deviceRate))"
            } else if AudioObject.isSettable(streamID, virtualAddress) {
                var wanted = layout.tapStream.format
                wanted.mSampleRate = deviceRate
                do {
                    try AudioObject.write(streamID, virtualAddress, value: wanted, "Formato stream tap")
                    Thread.sleep(forTimeInterval: 0.2)
                    let reread = (try? AudioObject.read(
                        streamID, virtualAddress, initial: AudioStreamBasicDescription(), "Formato stream tap"))?
                        .mSampleRate ?? 0
                    result.streamFormatReport = "impostato, riletto \(reread) Hz"
                } catch let error as CoreAudioError {
                    result.streamFormatReport = "rifiutato \(describeOSStatus(error.status))"
                } catch {
                    result.streamFormatReport = "rifiutato"
                }
            } else {
                result.streamFormatReport = "non impostabile"
            }

            // Latency figures (after any format change).
            let input = kAudioObjectPropertyScopeInput, output = kAudioObjectPropertyScopeOutput
            result.aggregateRate = (try? newAggregate.nominalSampleRate()) ?? 0
            result.safetyIn = newAggregate.safetyOffset(scope: input)
            result.safetyOut = newAggregate.safetyOffset(scope: output)
            result.latencyIn = newAggregate.deviceLatency(scope: input)
            result.latencyOut = newAggregate.deviceLatency(scope: output)
            result.tapStreamLatency = DeviceStreams.latency(ofStream: streamID)
            result.outputStreamLatency = layout.outputStreams.first.map { DeviceStreams.latency(ofStream: $0.objectID) } ?? 0
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    /// Sample rates listed in kAudioStreamPropertyAvailableVirtualFormats.
    private static func availableRates(of stream: AudioStreamID) -> [String] {
        let formats: [AudioStreamRangedDescription] =
            (try? AudioObject.readArray(
                stream, AudioObject.address(kAudioStreamPropertyAvailableVirtualFormats),
                element: AudioStreamRangedDescription(), "Formati disponibili")) ?? []
        var rates: [String] = []
        for format in formats {
            let range = format.mSampleRateRange
            let text =
                range.mMinimum == range.mMaximum
                ? "\(Int(range.mMinimum))" : "\(Int(range.mMinimum))-\(Int(range.mMaximum))"
            let entry = "\(text) Hz/\(format.mFormat.mChannelsPerFrame) ch"
            if !rates.contains(entry) { rates.append(entry) }
        }
        return rates
    }

    private static func writeReport(header: [String], results: [TapProbeResult]) {
        let text = (header + [""] + results.map(\.detail)).joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: reportURL, atomically: true, encoding: .utf8)
            Log.engine.notice("Tap diagnostic written to \(reportURL.path, privacy: .public)")
        } catch {
            Log.engine.error("Tap diagnostic file not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
