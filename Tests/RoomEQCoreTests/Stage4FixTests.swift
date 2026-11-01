import Foundation
import Testing
@testable import RoomEQCore

private let own = "com.federicociapi.RoomEQ"

@Suite("Stage 4 review fixes")
struct Stage4FixTests {
    /// Finding 1 (seam): the working state is published WITH its preamp, so
    /// applying a preset (or an automatic switch) also moves the gain.
    @Test func applyingAPresetPublishesItsPreamp() throws {
        var settings = REWFixture.settings()
        settings.preampDecibels = -6
        try settings.saveCurrentAsNewPreset(name: "Basso")
        try settings.applyPreset(id: settings.presets[0].id)  // Studio, 0 dB
        let handle = DSPTest.makeHandle(sampleRate: 48_000, filters: [], gain: Preamp.linearGain(decibels: -6)!)
        try settings.applyPreset(id: settings.presets[0].id)
        handle.publishWorkingState(bands: settings.bands, preampDecibels: settings.preampDecibels)
        #expect(handle.targetGain == 1)
        try settings.applyPreset(id: settings.presets[1].id)
        let design = handle.publishWorkingState(bands: settings.bands, preampDecibels: settings.preampDecibels)
        #expect(abs(Double(handle.targetGain) - pow(10, -6.0 / 20)) < 1e-6)
        // The filters too: after a render cycle the processor targets them.
        _ = DSPTest.renderCycle(handle, left: [Float](repeating: 0, count: 64), right: [Float](repeating: 0, count: 64))
        #expect(handle.eqActiveTargets == design.sections)
    }

    @Test func suggestedNameAndSuffixesRespectTheLimit() throws {
        var settings = REWFixture.settings()
        #expect(settings.suggestedNewPresetName == "Senza nome")
        try settings.saveCurrentAsNewPreset(name: "Senza nome")
        #expect(settings.suggestedNewPresetName == "Senza nome 2")

        let long = String(repeating: "x", count: 40)
        try settings.renamePreset(id: settings.presets[0].id, name: long)
        let copy = try settings.duplicatePreset(id: settings.presets[0].id)
        #expect(copy.name.count <= PresetNames.maximumLength)
        #expect(PresetNames.unique(long, among: [long]).count == 40)
        #expect(PresetNames.unique(long, among: [long]).hasSuffix(" 2"))
        var names = [long]
        for _ in 0..<12 { names.append(PresetNames.unique(long, among: names)) }
        #expect(names.allSatisfy { $0.count <= 40 })
        #expect(Set(names.map { $0.lowercased() }).count == names.count)
    }

    /// Finding 4: sanitising keeps remembered edits (base cleared).
    @Test func sanitizingKeepsRememberedEdits() {
        var settings = REWFixture.settings()
        settings.editsByDevice["usb"] = DeviceEdits(presetID: UUID(), bands: REWFixture.bands(), preampDecibels: -1)
        settings.deviceNames = ["usb": "Cuffie", "vecchio": "Non serve più"]
        let clean = settings.sanitized(ownBundleID: own)
        #expect(clean.editsByDevice["usb"]?.presetID == nil)
        #expect(clean.editsByDevice["usb"]?.bands.count == 4)
        #expect(clean.deviceNames == ["usb": "Cuffie"])  // finding 7: pruned
    }

    /// Finding 10: every lenient fallback is reported, so a backup is taken.
    @Test func lenientFallbacksAreReported() throws {
        let settings = REWFixture.settings()
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        var preset = (object["presets"] as! [[String: Any]])[0]
        preset["id"] = "non-un-uuid"
        preset.removeValue(forKey: "name")
        preset["preampDecibels"] = "zero"
        var band = (preset["bands"] as! [[String: Any]])[0]
        band.removeValue(forKey: "id")
        preset["bands"] = [band]
        object["presets"] = [preset]
        object["activePresetID"] = "rotto"
        object["editsByDevice"] = ["usb": ["presetID": 7, "bands": [], "preampDecibels": -1]]
        let loaded = AppSettings.load(current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(loaded.backups.count == 1)
        #expect(loaded.warnings.contains("Preset «Preset»: identificativo illeggibile, rigenerato"))
        #expect(loaded.warnings.contains("Preset senza nome leggibile, chiamato «Preset»"))
        #expect(loaded.warnings.contains("Preset «Preset»: preamp illeggibile, 0 dB"))
        #expect(loaded.warnings.contains { $0.contains("identificativo illeggibile, rigenerato") && $0.hasPrefix("Preset «Preset»: ") })
        #expect(loaded.warnings.contains("Preset attivo illeggibile"))
        #expect(loaded.warnings.contains("Modifiche per uscita: preset di base illeggibile"))
        #expect(loaded.settings.editsByDevice["usb"] != nil)  // kept
    }

    /// Finding 9: backups once per content, at most 5.
    @Test func backupsAreDedupedAndLimited() {
        let a = Data("a".utf8), b = Data("b".utf8)
        let first = SettingsBackups.plan(existing: [:], adding: [.init(sourceKey: "RoomEQSettings", data: a)], timestamp: 100)
        #expect(first.writes == ["RoomEQSettings.backup.100": a] && first.hasNewContent)
        let again = SettingsBackups.plan(existing: first.writes, adding: [.init(sourceKey: "RoomEQSettings", data: a)], timestamp: 200)
        #expect(!again.hasNewContent && again.writes.isEmpty && again.deletions.isEmpty)

        var existing: [String: Data] = [:]
        for index in 1...5 { existing["EQSettings.backup.\(index)"] = Data("old\(index)".utf8) }
        let full = SettingsBackups.plan(existing: existing, adding: [.init(sourceKey: "RoomEQSettings", data: b)], timestamp: 900)
        #expect(full.writes == ["RoomEQSettings.backup.900": b])
        #expect(full.deletions == ["EQSettings.backup.1"])  // the oldest
        let sameSecond = SettingsBackups.plan(
            existing: ["RoomEQSettings.backup.900": a], adding: [.init(sourceKey: "RoomEQSettings", data: b)], timestamp: 900)
        #expect(sameSecond.writes == ["RoomEQSettings.backup.900-2": b])
    }

    /// Finding 6: matching ignores case; very short IDs get a warning.
    @Test func exclusionMatchingAndBroadIDs() {
        #expect(ExclusionRules.matches(processBundleID: "COM.Ableton.Live", excluded: "com.ableton.live"))
        #expect(ExclusionRules.matches(processBundleID: "com.ableton.live.helper", excluded: "com.Ableton.Live"))
        #expect(!ExclusionRules.matches(processBundleID: "com.ableton.livestream", excluded: "com.ableton.live"))
        #expect(ExclusionRules.warning(forBundleID: "com.apple")?.contains("escluderebbe molte app") == true)
        #expect(ExclusionRules.warning(forBundleID: "com.apple", isInstalledApp: true) == nil)
        #expect(ExclusionRules.warning(forBundleID: "com.apple.Music") == nil)
        #expect(ExclusionRules.warning(forBundleID: "roomeqwizard.launcher") == ExclusionRules.rewWarning)
    }

    /// Finding 5 (low): rates compared with a ±0,5 Hz tolerance.
    @Test func sampleRateTolerance() {
        #expect(SampleRates.same(48_000, 48_000.4))
        #expect(!SampleRates.same(48_000, 48_001))
        #expect(SampleRates.contains([44_100, 48_000], 47_999.8))
        #expect(SampleRateGuard.violation(tapRate: 48_000.2, deviceRate: 48_000, captureRate: 47_999.9) == nil)
        #expect(SampleRateGuard.violation(tapRate: 44_100, deviceRate: 48_000, captureRate: 48_000) != nil)
        #expect(AudioFormatText.change(from: 44_100, to: 48_000) == "44,1 → 48 kHz")
        #expect(AudioFormatText.change(from: nil, to: 96_000) == "96 kHz")
    }

    /// Buffer size and per-output channel pair are persisted.
    @Test func bufferAndChannelPairArePersisted() throws {
        var settings = REWFixture.settings()
        #expect(settings.bufferFrames == 64 && settings.outputPairs.isEmpty)
        settings.bufferFrames = 128
        settings.outputPairs = ["usb-10ch": 4]
        let loaded = AppSettings.load(current: try settings.encoded(), legacy: nil, ownBundleID: own)
        #expect(loaded.settings.bufferFrames == 128 && loaded.settings.outputPairs == ["usb-10ch": 4])
        #expect(loaded.backups.isEmpty)

        settings.bufferFrames = 7
        settings.outputPairs = ["a": 3, "b": -2, "": 0, "c": 2]
        let clean = settings.sanitized(ownBundleID: own)
        #expect(clean.bufferFrames == 64 && clean.outputPairs == ["c": 2])
    }
}
