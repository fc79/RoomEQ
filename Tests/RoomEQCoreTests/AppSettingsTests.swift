import CoreAudio
import Foundation
import Testing
@testable import RoomEQCore

private let own = "com.federicociapi.RoomEQ"

private func settingsWithTwoPresets() throws -> AppSettings {
    var settings = REWFixture.settings()
    settings.bands[0].gain = -3
    try settings.saveCurrentAsNewPreset(name: "Cuffie")
    return settings
}

@Suite("Presets")
struct PresetTests {
    /// First launch is neutral: no filters, preamp 0, one empty preset
    /// ("Senza nome", active, unmodified), the correction OFF.
    @Test func firstLaunchIsNeutral() {
        let loaded = AppSettings.load(current: nil, legacy: nil, ownBundleID: own)
        #expect(loaded.notice == nil && loaded.backups.isEmpty && !loaded.migrated && !loaded.upgraded)
        let settings = loaded.settings
        #expect(settings.bands.isEmpty && settings.preampDecibels == 0)
        #expect(settings.presets.map(\.name) == [PresetNames.untitled])
        #expect(settings.presets[0].bands.isEmpty && settings.presets[0].preampDecibels == 0)
        #expect(settings.activePresetID == settings.presets[0].id)
        #expect(!settings.isActivePresetModified && !settings.hasUnsavedChanges)
        #expect(settings.excludedApps.isEmpty)  // no app excluded by default
        #expect(!settings.isCorrectionOn)  // nothing to correct until filters are imported
        #expect(settings.suggestedNewPresetName == "Senza nome 2")
    }

    /// The first REW import marks the empty preset modified; "Salva" stores
    /// the filters in it.
    @Test func firstImportIsSavedIntoTheEmptyPreset() throws {
        var settings = AppSettings.defaults()
        settings.bands = REWFixture.bands()
        #expect(settings.isActivePresetModified && settings.hasUnsavedChanges)
        try settings.saveCurrentToActivePreset()
        #expect(!settings.hasUnsavedChanges && settings.presets[0].bands.count == 4)
    }

    /// The fixture has the shape of a stage-3 migration: the filters as
    /// working state and active preset "Studio", Ableton Live excluded (as
    /// stage 3 always did), correction on.
    @Test func fixtureHasStudioActiveAndUnmodified() {
        let settings = REWFixture.settings()
        #expect(settings.presets.map(\.name) == ["Studio"])
        #expect(settings.activePresetID == settings.presets[0].id)
        #expect(!settings.isActivePresetModified)
        #expect(settings.bands.map(\.frequency) == REWFixture.bands().map(\.frequency))
        #expect(settings.excludedApps.map(\.bundleID) == ["com.ableton.live"])
        #expect(settings.isCorrectionOn)
    }

    /// A stored document keeps loading as before the neutral first launch:
    /// missing filters give an empty list, a missing switch is ON.
    @Test func storedDocumentWithoutSwitchStaysOn() throws {
        var object = try JSONSerialization.jsonObject(with: try REWFixture.settings().encoded()) as! [String: Any]
        object.removeValue(forKey: "isCorrectionOn")
        let loaded = AppSettings.load(
            current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(loaded.settings.isCorrectionOn)
        #expect(loaded.settings.presets.map(\.name) == ["Studio"] && loaded.settings.bands.count == 4)
    }

    /// A stored list of excluded apps is kept as it is (existing
    /// installations keep their exclusions); only a document without one
    /// gets the empty default.
    @Test func storedExclusionsAreKept() throws {
        let stored = REWFixture.settings()
        let kept = AppSettings.load(current: try stored.encoded(), legacy: nil, ownBundleID: own)
        #expect(kept.settings.excludedApps.map(\.bundleID) == ["com.ableton.live"] && kept.notice == nil)

        var emptied = stored
        emptied.excludedApps = []
        let empty = AppSettings.load(current: try emptied.encoded(), legacy: nil, ownBundleID: own)
        #expect(empty.settings.excludedApps.isEmpty)

        var object = try JSONSerialization.jsonObject(with: try stored.encoded()) as! [String: Any]
        object.removeValue(forKey: "excludedApps")
        let missing = AppSettings.load(
            current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(missing.settings.excludedApps.isEmpty && missing.notice == nil)
    }

    /// A stored document whose presets are all unreadable keeps its working
    /// state in one "Senza nome" preset, named as at first launch.
    @Test func unreadablePresetsBecomeUntitled() throws {
        var object = try JSONSerialization.jsonObject(with: try REWFixture.settings().encoded()) as! [String: Any]
        object["presets"] = ["rotto"]
        let loaded = AppSettings.load(
            current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(loaded.settings.presets.map(\.name) == [PresetNames.untitled])
        #expect(loaded.settings.presets[0].bands.count == 4 && loaded.settings.bands.count == 4)
        #expect(loaded.settings.activePresetID == loaded.settings.presets[0].id)
        #expect(loaded.backups.count == 1)
    }

    @Test func modifiedFlagFollowsTheSoundNotTheIDs() throws {
        var settings = REWFixture.settings()
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
        var settings = REWFixture.settings()
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
        try settings.assignPreset(id: headphones, toDeviceUID: "cuffie")
        try settings.assignPreset(id: studio, toDeviceUID: "casse")
        #expect(settings.outputDidChange(to: "casse") == .appliedPreset(studio))
        return (settings, studio, headphones)
    }

    /// The rules always apply (version 4: no option to switch on first).
    @Test func rulesApplyWithoutAnOption() throws {
        var settings = try settingsWithTwoPresets()  // active: "Cuffie", unmodified
        let studio = settings.presets[0].id
        try settings.assignPreset(id: studio, toDeviceUID: "cuffie")
        #expect(settings.outputDidChange(to: "cuffie") == .appliedPreset(studio))
        #expect(settings.lastOutputDeviceUID == "cuffie" && settings.activePresetID == studio)
        #expect(settings.outputDidChange(to: "cuffie") == .unchanged)  // same output: nothing
        let before = settings.bands
        #expect(settings.outputDidChange(to: "hdmi") == .unchanged)  // "Preset attuale" (no rule): only recorded
        #expect(settings.lastOutputDeviceUID == "hdmi" && settings.bands == before)
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

    /// No recorded output yet (first launch, unreadable record) and unsaved
    /// changes: there is no output to remember them for, so they are never
    /// replaced by the new output's preset or remembered edits.
    @Test func unsavedChangesWithoutAPreviousOutputAreKept() throws {
        var settings = try settingsWithTwoPresets()
        let studio = settings.presets[0].id, headphones = settings.presets[1].id
        try settings.assignPreset(id: studio, toDeviceUID: "cuffie")
        try settings.assignPreset(id: headphones, toDeviceUID: "casse")
        #expect(settings.lastOutputDeviceUID == nil)
        settings.bands[0].gain = -1  // unsaved
        let edited = settings.bands
        #expect(settings.outputDidChange(to: "cuffie") == .unchanged)
        #expect(settings.bands == edited && settings.activePresetID == headphones && settings.hasUnsavedChanges)
        #expect(settings.lastOutputDeviceUID == "cuffie")
        // From now on they belong to "cuffie": kept when leaving, restored on return.
        #expect(settings.outputDidChange(to: "casse") == .appliedPreset(headphones))
        #expect(settings.editsByDevice["cuffie"]?.bands == edited)
        #expect(settings.outputDidChange(to: "cuffie") == .restoredEdits(presetID: headphones, assignedPresetID: studio))
        #expect(settings.bands == edited)
    }

    /// Same with edits remembered for that output: both are kept.
    @Test func rememberedEditsWithoutAPreviousOutputStayRemembered() throws {
        var settings = try settingsWithTwoPresets()
        let studio = settings.presets[0].id
        let stash = DeviceEdits(presetID: studio, bands: [EQBand(frequency: 90, gain: -2, q: 3)], preampDecibels: -1)
        settings.editsByDevice["cuffie"] = stash
        settings.bands[0].gain = -1
        let edited = settings.bands
        #expect(settings.outputDidChange(to: "cuffie") == .unchanged)
        #expect(settings.bands == edited && settings.editsByDevice["cuffie"] == stash)
    }

    /// Without unsaved changes nothing can be lost: the rule applies.
    @Test func noPreviousOutputAndNothingUnsavedAppliesTheRule() throws {
        var settings = try settingsWithTwoPresets()
        let studio = settings.presets[0].id
        try settings.assignPreset(id: studio, toDeviceUID: "cuffie")
        #expect(!settings.hasUnsavedChanges)
        #expect(settings.outputDidChange(to: "cuffie") == .appliedPreset(studio))
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
        settings.presetAssignments = ["usb-1": settings.presets[1].id]
        settings.deviceNames = ["usb-1": "Cuffie USB"]
        settings.editsByDevice = ["usb-1": DeviceEdits(presetID: settings.presets[1].id, bands: settings.bands, preampDecibels: -1)]
        settings.lastOutputDeviceUID = "usb-1"
        settings.excludedApps.append(ExcludedAppRecord(bundleID: "com.apple.Music", name: "Musica"))
        settings.isCorrectionOn = false
        let loaded = AppSettings.load(current: try settings.encoded(), legacy: nil, ownBundleID: own)
        #expect(loaded.settings == settings)
        #expect(loaded.backups.isEmpty && loaded.warnings.isEmpty && loaded.notice == nil)
        #expect(!loaded.migrated && !loaded.upgraded)
    }

    /// Stage 3's "EQ off" is not kept: version 4 never bypasses. Stage 3's
    /// built-in exclusion of Ableton Live is kept (the sound does not change).
    @Test func migratesStage3Losslessly() throws {
        var bands = REWFixture.bands()
        bands[1].isEnabled = false
        let old = EQSettings(bands: bands, preampDecibels: -3.5, isEQEnabled: false)
        let loaded = AppSettings.load(current: nil, legacy: try old.encoded(), ownBundleID: own)
        #expect(loaded.migrated && loaded.backups.isEmpty && loaded.notice == nil)
        let settings = loaded.settings
        #expect(settings.bands == bands && settings.preampDecibels == -3.5 && settings.isCorrectionOn)
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
        // Nothing readable: the neutral state, as at first launch.
        #expect(loaded.settings.presets.map(\.name) == [PresetNames.untitled])
        #expect(loaded.settings.bands.isEmpty && !loaded.settings.isCorrectionOn)

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
        #expect(alone.backups.count == 1 && alone.settings.presets.map(\.name) == [PresetNames.untitled])
        #expect(alone.settings.bands.isEmpty && !alone.settings.isCorrectionOn)
        #expect(alone.notice == "Le impostazioni salvate non erano leggibili: ne ho conservato una copia e sono ripartito senza filtri, con la correzione spenta.")
    }

    @Test func partialDocumentKeepsWhatIsReadable() throws {
        var settings = try settingsWithTwoPresets()
        settings.isCorrectionOn = false
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
        #expect(!loaded.settings.isCorrectionOn)
        #expect(loaded.settings.presetAssignments.isEmpty)
        #expect(loaded.warnings.contains("Associazioni preset-uscita illeggibile"))
        #expect(loaded.warnings.contains("1 preset illeggibili ignorati"))
        #expect(loaded.notice?.hasPrefix("Parte delle impostazioni") == true)
    }

    @Test func futureVersionIsReadForKnownFields() throws {
        var settings = REWFixture.settings()
        settings.isCorrectionOn = false
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        object["version"] = 9
        let loaded = AppSettings.load(current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(!loaded.settings.isCorrectionOn && !loaded.upgraded)
        #expect(loaded.backups.count == 1)  // so a downgrade never loses the newer data
        #expect(loaded.settings.version == AppSettings.currentVersion)
    }

    @Test func sanitizingMakesItConsistent() {
        let preset = EQPreset(name: "Studio", bands: REWFixture.bands(), preampDecibels: 3)
        let twin = EQPreset(id: preset.id, name: " studio ", bands: [], preampDecibels: -50)
        var settings = AppSettings(
            bands: REWFixture.bands(), preampDecibels: 0, presets: [preset, twin],
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

        var empty = REWFixture.settings()
        empty.presets = []
        #expect(empty.sanitized(ownBundleID: own).presets.map(\.name) == [PresetNames.untitled])
    }
}

@Suite("Settings version 4 (one switch, rules always on)")
struct SettingsVersion4Tests {
    /// A version-3 document as last saved by the previous build: EQ off,
    /// per-output option off with rules, remembered edits, auto-start set.
    func version3Document(autoStart: Bool) throws -> (data: Data, expected: AppSettings) {
        var settings = try settingsWithTwoPresets()
        let studio = settings.presets[0].id, headphones = settings.presets[1].id
        try settings.assignPreset(id: headphones, toDeviceUID: "cuffie")
        settings.assignNoCorrection(toDeviceUID: "macbook")
        settings.editsByDevice["cuffie"] = DeviceEdits(presetID: studio, bands: settings.bands, preampDecibels: -2)
        settings.deviceNames = ["cuffie": "Cuffie USB", "macbook": "Altoparlanti MacBook"]
        settings.lastOutputDeviceUID = "macbook"  // recorded while the option was off
        settings.bufferFrames = 128
        settings.outputPairs = ["quantum": 2]
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        object["version"] = 3
        object.removeValue(forKey: "isCorrectionOn")
        object["isEQEnabled"] = false
        object["isPresetPerOutputEnabled"] = false
        object["autoStartEngineOnLaunch"] = autoStart
        return (try JSONSerialization.data(withJSONObject: object), settings)
    }

    @Test(arguments: [true, false])
    func version3IsConvertedWithoutLosingAnything(autoStart: Bool) throws {
        let (data, expected) = try version3Document(autoStart: autoStart)
        let loaded = AppSettings.load(current: data, legacy: nil, ownBundleID: own)
        // Everything kept; the correction is on at launch whatever the old
        // auto-start was; the old rules become active as they are.
        #expect(loaded.settings == expected)
        #expect(loaded.settings.isCorrectionOn)
        #expect(loaded.settings.engineMode(userWantsOn: true, outputUID: "macbook") == .paused)
        #expect(loaded.settings.outputAssignment(forDeviceUID: "cuffie") == .preset(expected.presets[1].id))
        #expect(loaded.settings.editsByDevice["cuffie"]?.preampDecibels == -2)
        // Silent (old keys are not "unreadable"), but the old document is kept.
        #expect(loaded.warnings.isEmpty && loaded.notice == nil && loaded.upgraded && !loaded.migrated)
        #expect(loaded.backups == [.init(sourceKey: "RoomEQSettings", data: data)])
        // Saved again: version 4, without the old keys.
        let saved = try JSONSerialization.jsonObject(with: try loaded.settings.encoded()) as! [String: Any]
        #expect(saved["version"] as? Int == 4 && saved["isCorrectionOn"] as? Bool == true)
        for key in ["isEQEnabled", "isPresetPerOutputEnabled", "autoStartEngineOnLaunch"] {
            #expect(saved[key] == nil, "\(key)")
        }
    }

    /// The switch is restored as the user left it.
    @Test(arguments: [true, false])
    func switchIsRemembered(on: Bool) throws {
        var settings = REWFixture.settings()
        settings.isCorrectionOn = on
        let loaded = AppSettings.load(current: try settings.encoded(), legacy: nil, ownBundleID: own)
        #expect(loaded.settings.isCorrectionOn == on && loaded.backups.isEmpty)
    }

    @Test func unreadableSwitchIsOnAndReported() throws {
        var object = try JSONSerialization.jsonObject(with: try REWFixture.settings().encoded()) as! [String: Any]
        object["isCorrectionOn"] = "sì"
        let loaded = AppSettings.load(
            current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(loaded.settings.isCorrectionOn)
        #expect(loaded.warnings == ["Stato della correzione illeggibile"])
        #expect(loaded.backups.count == 1 && !loaded.upgraded)
    }

    /// Old keys found in a version-4 document (hand-edited) change nothing.
    @Test func oldKeysAreIgnored() throws {
        var settings = REWFixture.settings()
        settings.isCorrectionOn = false
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        object["isEQEnabled"] = "rotto"
        object["autoStartEngineOnLaunch"] = true
        let loaded = AppSettings.load(
            current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(loaded.settings == settings)
        #expect(loaded.warnings.isEmpty && loaded.backups.isEmpty)
    }

    /// No version at all: treated as an older document (backed up, converted).
    @Test func missingVersionIsUpgraded() throws {
        var object = try JSONSerialization.jsonObject(with: try REWFixture.settings().encoded()) as! [String: Any]
        object.removeValue(forKey: "version")
        let data = try JSONSerialization.data(withJSONObject: object)
        let loaded = AppSettings.load(current: data, legacy: nil, ownBundleID: own)
        #expect(loaded.upgraded && loaded.backups.count == 1 && loaded.settings.version == 4)
    }
}

@Suite("Exclusion rules")
struct ExclusionRuleTests {
    @Test func validation() throws {
        let existing = [ExcludedAppRecord(bundleID: "com.ableton.live", name: "Ableton Live")]
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
        #expect(ExclusionRules.defaultApps.isEmpty)  // nothing excluded by default, REW included
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
