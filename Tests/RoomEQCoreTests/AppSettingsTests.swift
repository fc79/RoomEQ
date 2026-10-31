import CoreAudio
import Foundation
import Testing
@testable import RoomEQCore

private let own = "com.federicociapi.RoomEQ"

private func settingsWithTwoPresets() throws -> AppSettings {
    var settings = AppSettings.defaults()
    settings.bands[0].gain = -3
    try settings.saveCurrentAsNewPreset(name: "Cuffie")
    return settings
}

@Suite("Presets")
struct PresetTests {
    @Test func firstLaunchHasStudioActiveAndUnmodified() {
        let settings = AppSettings.defaults()
        #expect(settings.presets.map(\.name) == ["Studio"])
        #expect(settings.activePresetID == settings.presets[0].id)
        #expect(!settings.isActivePresetModified)
        #expect(settings.bands.map(\.frequency) == EQBand.defaultBands().map(\.frequency))
        #expect(settings.excludedApps.map(\.bundleID) == ["com.ableton.live"])
        #expect(!settings.isPresetPerOutputEnabled && !settings.autoStartEngineOnLaunch)
    }

    @Test func modifiedFlagFollowsTheSoundNotTheIDs() throws {
        var settings = AppSettings.defaults()
        settings.bands[1].gain += 1
        #expect(settings.isActivePresetModified)
        settings.bands[1].gain -= 1
        #expect(!settings.isActivePresetModified)
        settings.bands = settings.bands.map { EQBand(frequency: $0.frequency, gain: $0.gain, q: $0.q) }  // new IDs
        #expect(!settings.isActivePresetModified)
        settings.preampDecibels = -2
        #expect(settings.isActivePresetModified)
        try settings.saveCurrentToActivePreset()
        #expect(!settings.isActivePresetModified)
        #expect(settings.activePreset?.preampDecibels == -2)
    }

    @Test func saveApplyAndRename() throws {
        var settings = try settingsWithTwoPresets()
        #expect(settings.presets.map(\.name) == ["Studio", "Cuffie"])
        #expect(settings.activePreset?.name == "Cuffie")
        let studio = settings.presets[0].id
        try settings.applyPreset(id: studio)
        #expect(settings.bands[0].gain == -9.9 && settings.activePresetID == studio && !settings.isActivePresetModified)

        try settings.renamePreset(id: studio, name: "  Sala   regia ")
        #expect(settings.presets[0].name == "Sala regia")
        try settings.renamePreset(id: studio, name: "SALA REGIA")  // own name, other case: fine
        #expect(throws: PresetError.emptyName) { try settings.renamePreset(id: studio, name: "   ") }
        #expect(throws: PresetError.duplicateName("Cuffie")) { try settings.renamePreset(id: studio, name: "cuffìe") }
        #expect(throws: PresetError.nameTooLong(maximum: 40)) {
            try settings.renamePreset(id: studio, name: String(repeating: "x", count: 41))
        }
        #expect(throws: PresetError.duplicateName("Cuffie")) { try settings.saveCurrentAsNewPreset(name: "CUFFIE") }
        #expect(throws: PresetError.notFound) { try settings.applyPreset(id: UUID()) }
        #expect(PresetError.duplicateName("Cuffie").localizedDescription == "Esiste già un preset chiamato «Cuffie».")
    }

    @Test func deleteRules() throws {
        var settings = try settingsWithTwoPresets()
        let studio = settings.presets[0].id, headphones = settings.presets[1].id
        try settings.assignPreset(id: headphones, toDeviceUID: "usb-1")
        settings.editsByDevice["usb-1"] = DeviceEdits(presetID: headphones, bands: [], preampDecibels: 0)
        let playing = settings.bands
        #expect(!settings.hasUnsavedChanges)
        try settings.deletePreset(id: headphones)  // the active one
        #expect(settings.presets.map(\.id) == [studio])
        #expect(settings.activePresetID == nil && !settings.isActivePresetModified)
        #expect(settings.bands == playing)  // the sound doesn't change
        // ...and it now exists in no preset: replacing it must be confirmed.
        #expect(settings.hasUnsavedChanges)
        #expect(settings.presetAssignments.isEmpty)
        // Remembered edits are kept, only their base is cleared.
        #expect(settings.editsByDevice["usb-1"] == DeviceEdits(presetID: nil, bands: [], preampDecibels: 0))
        #expect(throws: PresetError.lastPreset) { try settings.deletePreset(id: studio) }
        #expect(throws: PresetError.noActivePreset) { try settings.saveCurrentToActivePreset() }
    }

    @Test func duplicateNames() throws {
        var settings = AppSettings.defaults()
        let studio = settings.presets[0].id
        let first = try settings.duplicatePreset(id: studio)
        let second = try settings.duplicatePreset(id: studio)
        #expect(first.name == "Studio copia" && second.name == "Studio copia 2")
        #expect(settings.presets.map(\.name) == ["Studio", "Studio copia 2", "Studio copia"])
        #expect(settings.activePresetID == studio)  // not activated
        #expect(first.bands == settings.presets[0].bands)
    }
}

@Suite("Per-output presets")
struct OutputPresetTests {
    /// Studio on the speakers, "Cuffie" assigned to the headphones.
    func setup() throws -> (AppSettings, studio: UUID, headphones: UUID) {
        var settings = try settingsWithTwoPresets()
        let studio = settings.presets[0].id, headphones = settings.presets[1].id
        try settings.applyPreset(id: studio)
        settings.isPresetPerOutputEnabled = true
        try settings.assignPreset(id: headphones, toDeviceUID: "cuffie")
        try settings.assignPreset(id: studio, toDeviceUID: "casse")
        #expect(settings.outputDidChange(to: "casse") == .appliedPreset(studio))
        return (settings, studio, headphones)
    }

    @Test func optionOffOnlyRecordsTheOutput() throws {
        var settings = try settingsWithTwoPresets()
        try settings.assignPreset(id: settings.presets[0].id, toDeviceUID: "cuffie")
        let before = settings.bands
        #expect(settings.outputDidChange(to: "cuffie") == .unchanged)
        #expect(settings.lastOutputDeviceUID == "cuffie" && settings.bands == before)
        #expect(settings.outputDidChange(to: "cuffie") == .unchanged)  // same output: nothing
    }

    @Test func assignedPresetIsApplied() throws {
        var (settings, studio, headphones) = try setup()
        #expect(settings.outputDidChange(to: "cuffie") == .appliedPreset(headphones))
        #expect(settings.activePresetID == headphones && !settings.isActivePresetModified)
        #expect(settings.outputDidChange(to: "casse") == .appliedPreset(studio))
        #expect(settings.editsByDevice.isEmpty)  // nothing unsaved, nothing remembered
    }

    @Test func unsavedEditsAreRememberedPerOutputAndRestored() throws {
        var (settings, studio, headphones) = try setup()
        settings.bands[0].gain = -1  // unsaved edit on the speakers
        let edited = settings.bands
        #expect(settings.outputDidChange(to: "cuffie") == .appliedPreset(headphones))
        #expect(settings.editsByDevice["casse"]?.bands == edited)
        settings.preampDecibels = -4  // unsaved edit on the headphones
        #expect(settings.outputDidChange(to: "casse") == .restoredEdits(presetID: studio, assignedPresetID: nil))
        #expect(settings.bands == edited && settings.activePresetID == studio && settings.isActivePresetModified)
        #expect(settings.editsByDevice["casse"] == nil)
        #expect(settings.editsByDevice["cuffie"]?.preampDecibels == -4)
        #expect(settings.outputDidChange(to: "cuffie") == .restoredEdits(presetID: headphones, assignedPresetID: nil))
        #expect(settings.preampDecibels == -4)
    }

    /// User work wins over a changed assignment: the edits are restored and
    /// the result names the preset assigned now.
    @Test func rememberedEditsWinOverAChangedAssignment() throws {
        var (settings, studio, headphones) = try setup()
        settings.bands[0].gain = -1
        let edited = settings.bands
        _ = settings.outputDidChange(to: "cuffie")
        try settings.assignPreset(id: headphones, toDeviceUID: "casse")  // reassigned meanwhile
        #expect(settings.outputDidChange(to: "casse") == .restoredEdits(presetID: studio, assignedPresetID: headphones))
        #expect(settings.bands == edited && settings.activePresetID == studio)
    }

    /// Edits whose base preset was deleted are still restored (no base).
    @Test func rememberedEditsSurviveDeletingTheirPreset() throws {
        var (settings, studio, _) = try setup()
        settings.bands[0].gain = -1
        let edited = settings.bands
        _ = settings.outputDidChange(to: "cuffie")
        try settings.deletePreset(id: studio)
        #expect(settings.editsByDevice["casse"]?.bands == edited)
        #expect(settings.outputDidChange(to: "casse") == .restoredEdits(presetID: nil, assignedPresetID: nil))
        #expect(settings.bands == edited && settings.activePresetID == nil && settings.hasUnsavedChanges)
    }

    @Test func unassignedOutputKeepsTheCurrentSound() throws {
        var (settings, _, _) = try setup()
        settings.bands[0].gain = -1
        let edited = settings.bands
        #expect(settings.outputDidChange(to: "hdmi") == .unchanged)
        #expect(settings.bands == edited)
        #expect(settings.editsByDevice.isEmpty)  // nothing was replaced, nothing stashed
    }

    @Test func leavingAnUnassignedOutputWithEditsComesBackToThem() throws {
        var (settings, _, headphones) = try setup()
        _ = settings.outputDidChange(to: "hdmi")
        settings.bands[2].gain = -2  // edits made on the unassigned output
        let edited = settings.bands
        #expect(settings.outputDidChange(to: "cuffie") == .appliedPreset(headphones))
        #expect(settings.outputDidChange(to: "hdmi") == .restoredEdits(presetID: settings.presets[0].id, assignedPresetID: nil))
        #expect(settings.bands == edited)
    }

    @Test func deletedPresetAssignmentsAreIgnored() throws {
        var (settings, _, headphones) = try setup()
        settings.presetAssignments["vecchio"] = UUID()
        #expect(settings.outputDidChange(to: "vecchio") == .unchanged)
        try settings.deletePreset(id: headphones)
        #expect(settings.outputDidChange(to: "cuffie") == .unchanged)
    }
}

@Suite("Settings document")
struct AppSettingsDocumentTests {
    @Test func roundTrip() throws {
        var settings = try settingsWithTwoPresets()
        settings.isPresetPerOutputEnabled = true
        settings.presetAssignments = ["usb-1": settings.presets[1].id]
        settings.deviceNames = ["usb-1": "Cuffie USB"]
        settings.editsByDevice = ["usb-1": DeviceEdits(presetID: settings.presets[1].id, bands: settings.bands, preampDecibels: -1)]
        settings.lastOutputDeviceUID = "usb-1"
        settings.excludedApps.append(ExcludedAppRecord(bundleID: "com.apple.Music", name: "Musica"))
        settings.autoStartEngineOnLaunch = true
        let loaded = AppSettings.load(current: try settings.encoded(), legacy: nil, ownBundleID: own)
        #expect(loaded.settings == settings)
        #expect(loaded.backups.isEmpty && loaded.warnings.isEmpty && loaded.notice == nil && !loaded.migrated)
    }

    @Test func migratesStage3Losslessly() throws {
        var bands = EQBand.defaultBands()
        bands[1].isEnabled = false
        let old = EQSettings(bands: bands, preampDecibels: -3.5, isEQEnabled: false)
        let loaded = AppSettings.load(current: nil, legacy: try old.encoded(), ownBundleID: own)
        #expect(loaded.migrated && loaded.backups.isEmpty && loaded.notice == nil)
        let settings = loaded.settings
        #expect(settings.bands == bands && settings.preampDecibels == -3.5 && !settings.isEQEnabled)
        #expect(settings.presets.map(\.name) == ["Studio"])
        #expect(settings.presets[0].bands == bands && settings.presets[0].preampDecibels == -3.5)
        #expect(settings.activePresetID == settings.presets[0].id && !settings.isActivePresetModified)
        #expect(settings.excludedApps.map(\.bundleID) == ["com.ableton.live"])
    }

    @Test func corruptedStage3IsBackedUp() {
        let garbage = Data("{not json".utf8)
        let loaded = AppSettings.load(current: nil, legacy: garbage, ownBundleID: own)
        #expect(loaded.backups == [.init(sourceKey: "EQSettings", data: garbage)])
        #expect(loaded.notice?.hasPrefix("Le impostazioni salvate non erano leggibili") == true)
        #expect(loaded.settings.presets.map(\.name) == ["Studio"])
        #expect(loaded.settings.bands.count == 4)

        let partial = Data(#"{"version":1,"bands":[{"frequency":80,"gain":-3,"q":4},{"frequency":"x"}],"preampDecibels":-1,"isEQEnabled":true}"#.utf8)
        let fromPartial = AppSettings.load(current: nil, legacy: partial, ownBundleID: own)
        #expect(fromPartial.backups.map(\.sourceKey) == ["EQSettings"])
        #expect(fromPartial.settings.bands.map(\.frequency) == [80])
        #expect(fromPartial.notice?.hasPrefix("Parte delle impostazioni") == true)
    }

    @Test func unreadableCurrentFallsBackToStage3() throws {
        let current = Data("[]".utf8)
        let legacy = try EQSettings(bands: [EQBand(frequency: 70, gain: -5, q: 6)], preampDecibels: -2, isEQEnabled: true).encoded()
        let loaded = AppSettings.load(current: current, legacy: legacy, ownBundleID: own)
        #expect(loaded.backups.map(\.sourceKey) == ["RoomEQSettings"])
        #expect(loaded.settings.bands.map(\.frequency) == [70])
        #expect(loaded.notice?.contains("recuperato i filtri della versione precedente") == true)

        let alone = AppSettings.load(current: current, legacy: nil, ownBundleID: own)
        #expect(alone.backups.count == 1 && alone.settings.presets.map(\.name) == ["Studio"])
        #expect(alone.notice == "Le impostazioni salvate non erano leggibili: ne ho conservato una copia e ho caricato i filtri iniziali.")
    }

    @Test func partialDocumentKeepsWhatIsReadable() throws {
        var settings = try settingsWithTwoPresets()
        settings.autoStartEngineOnLaunch = true
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        var presets = object["presets"] as! [Any]
        presets.append("rotto")  // unreadable preset
        var first = presets[0] as! [String: Any]
        var bands = first["bands"] as! [Any]
        bands.append(["frequency": "x"])  // unreadable band inside a preset
        first["bands"] = bands
        presets[0] = first
        object["presets"] = presets
        object["presetAssignments"] = 42  // wrong type
        object["futureField"] = ["anything": true]  // unknown: ignored
        let data = try JSONSerialization.data(withJSONObject: object)
        let loaded = AppSettings.load(current: data, legacy: nil, ownBundleID: own)
        #expect(loaded.backups.map(\.sourceKey) == ["RoomEQSettings"])
        #expect(loaded.settings.presets.map(\.name) == ["Studio", "Cuffie"])
        #expect(loaded.settings.presets[0].bands.count == 4)
        #expect(loaded.settings.autoStartEngineOnLaunch)
        #expect(loaded.settings.presetAssignments.isEmpty)
        #expect(loaded.warnings.contains("Associazioni preset-uscita illeggibile"))
        #expect(loaded.warnings.contains("1 preset illeggibili ignorati"))
        #expect(loaded.notice?.hasPrefix("Parte delle impostazioni") == true)
    }

    @Test func futureVersionIsReadForKnownFields() throws {
        var settings = AppSettings.defaults()
        settings.autoStartEngineOnLaunch = true
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        object["version"] = 9
        let loaded = AppSettings.load(current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(loaded.settings.autoStartEngineOnLaunch)
        #expect(loaded.backups.count == 1)  // so a downgrade never loses the newer data
        #expect(loaded.settings.version == AppSettings.currentVersion)
    }

    @Test func sanitizingMakesItConsistent() {
        let preset = EQPreset(name: "Studio", bands: EQBand.defaultBands(), preampDecibels: 3)
        let twin = EQPreset(id: preset.id, name: " studio ", bands: [], preampDecibels: -50)
        var settings = AppSettings(
            bands: EQBand.defaultBands(), preampDecibels: 0, isEQEnabled: true, presets: [preset, twin],
            activePresetID: UUID(), presetAssignments: ["a": preset.id, "b": UUID(), "": preset.id],
            excludedApps: [
                ExcludedAppRecord(bundleID: own, name: "RoomEQ"), ExcludedAppRecord(bundleID: "com.ableton.live", name: "Live"),
                ExcludedAppRecord(bundleID: "COM.ABLETON.LIVE", name: "Live"), ExcludedAppRecord(bundleID: "bad id!", name: "x"),
            ])
        settings = settings.sanitized(ownBundleID: own)
        #expect(settings.presets.map(\.name) == ["Studio", "studio 2"])
        #expect(Set(settings.presets.map(\.id)).count == 2)
        #expect(settings.presets[0].preampDecibels == 0 && settings.presets[1].preampDecibels == -24)
        #expect(settings.activePresetID == nil)
        #expect(settings.presetAssignments == ["a": preset.id])
        #expect(settings.excludedApps.map(\.bundleID) == ["com.ableton.live"])

        var empty = AppSettings.defaults()
        empty.presets = []
        #expect(empty.sanitized(ownBundleID: own).presets.map(\.name) == ["Studio"])
    }
}

@Suite("Exclusion rules")
struct ExclusionRuleTests {
    @Test func validation() throws {
        let existing = ExclusionRules.defaultApps
        #expect(try ExclusionRules.validateNew(" com.apple.Music ", existing: existing, ownBundleID: own) == "com.apple.Music")
        #expect(throws: ExclusionError.ownApp) { try ExclusionRules.validateNew(own, existing: existing, ownBundleID: own) }
        #expect(throws: ExclusionError.ownApp) {
            try ExclusionRules.validateNew("com.federicociapi.roomeq.helper", existing: existing, ownBundleID: own)
        }
        #expect(throws: ExclusionError.alreadyExcluded("Ableton Live")) {
            try ExclusionRules.validateNew("COM.ableton.live", existing: existing, ownBundleID: own)
        }
        for bad in ["", "   ", "con spazi", "è.strano", "...", String(repeating: "a", count: 256)] {
            #expect(throws: ExclusionError.invalidBundleID) { try ExclusionRules.validateNew(bad, existing: [], ownBundleID: own) }
        }
    }

    @Test func rewIsAllowedWithAWarning() throws {
        #expect(try ExclusionRules.validateNew("roomeqwizard.launcher", existing: [], ownBundleID: own) == "roomeqwizard.launcher")
        #expect(ExclusionRules.warning(forBundleID: "roomeqwizard.launcher") == "Escludendo REW, le misure non passeranno da RoomEQ")
        #expect(ExclusionRules.warning(forBundleID: "com.ableton.live") == nil)
        #expect(!ExclusionRules.defaultApps.contains { ExclusionRules.isREW($0.bundleID) })
    }
}

@Suite("Device formats")
struct DeviceFormatTests {
    @Test func sampleRateRangesExpandToStandardRates() {
        #expect(SampleRates.expand([(44_100, 44_100), (48_000, 48_000), (96_000, 96_000)]) == [44_100, 48_000, 96_000])
        #expect(SampleRates.expand([(44_100, 192_000)]) == SampleRates.standard)
        #expect(SampleRates.expand([(8_000, 96_000)]) == [44_100, 48_000, 88_200, 96_000])
        #expect(SampleRates.expand([(32_000, 32_000), (44_100, 48_000), (48_000, 48_000)]) == [32_000, 44_100, 48_000])
        #expect(SampleRates.expand([(0, 0), (.nan, 48_000), (-1, 5)]).isEmpty)
        #expect(SampleRates.expand([(96_000, 44_100)]) == [44_100, 48_000, 88_200, 96_000])  // reversed range
        #expect(SampleRates.expand([]).isEmpty)
    }

    @Test func transportNames() {
        #expect(TransportType.name(kAudioDeviceTransportTypeUSB) == "USB")
        #expect(TransportType.name(kAudioDeviceTransportTypeBuiltIn) == "Integrato")
        #expect(TransportType.name(kAudioDeviceTransportTypeBluetoothLE) == "Bluetooth")
        #expect(TransportType.name(0) == "Altro")
        #expect(TransportType.isAggregate(kAudioDeviceTransportTypeAggregate))
        #expect(!TransportType.isAggregate(kAudioDeviceTransportTypeUSB))
    }
}
