import Foundation
import Testing
@testable import RoomEQCore

private let own = "com.federicociapi.RoomEQ"

/// Studio on the speakers, "Cuffie" on the headphones, "no correction" on
/// the TV (rules always apply); current output: the speakers.
private func setup() throws -> (AppSettings, studio: UUID, headphones: UUID) {
    var settings = AppSettings.defaults()
    settings.bands[0].gain = -3
    try settings.saveCurrentAsNewPreset(name: "Cuffie")
    let studio = settings.presets[0].id, headphones = settings.presets[1].id
    try settings.applyPreset(id: studio)
    try settings.assignPreset(id: studio, toDeviceUID: "casse")
    try settings.assignPreset(id: headphones, toDeviceUID: "cuffie")
    settings.assignNoCorrection(toDeviceUID: "tv")
    #expect(settings.outputDidChange(to: "casse") == .appliedPreset(studio))
    return (settings, studio, headphones)
}

@Suite("No correction: decision")
struct EngineModeDecisionTests {
    @Test(arguments: [nil, OutputAssignment.noCorrection, .preset(UUID())])
    func offWhenTheUserSwitchedOff(assignment: OutputAssignment?) {
        #expect(EngineMode.desired(userWantsOn: false, assignment: assignment) == .off)
    }

    /// The rules always apply: "no correction" pauses, anything else
    /// ("Nessuna regola" included) corrects.
    @Test func pausedOnlyForNoCorrection() {
        #expect(EngineMode.desired(userWantsOn: true, assignment: .noCorrection) == .paused)
        #expect(EngineMode.desired(userWantsOn: true, assignment: .preset(UUID())) == .active)
        #expect(EngineMode.desired(userWantsOn: true, assignment: nil) == .active)
    }

    @Test func fromTheSettings() throws {
        var (settings, _, _) = try setup()
        #expect(settings.engineMode(userWantsOn: true, outputUID: "tv") == .paused)
        #expect(settings.engineMode(userWantsOn: false, outputUID: "tv") == .off)
        #expect(settings.engineMode(userWantsOn: true, outputUID: "cuffie") == .active)
        #expect(settings.engineMode(userWantsOn: true, outputUID: "hdmi") == .active)  // no rule
        #expect(settings.engineMode(userWantsOn: true, outputUID: nil) == .active)  // no output
        settings.clearAssignment(deviceUID: "tv")  // "Nessuna regola": corrects
        #expect(settings.engineMode(userWantsOn: true, outputUID: "tv") == .active)
    }
}

@Suite("No correction: rules")
struct NoCorrectionRuleTests {
    @Test func oneRulePerOutput() throws {
        var (settings, studio, _) = try setup()
        #expect(settings.outputAssignment(forDeviceUID: "tv") == .noCorrection)
        #expect(settings.outputAssignment(forDeviceUID: "casse") == .preset(studio))
        #expect(settings.outputAssignment(forDeviceUID: "hdmi") == nil)

        settings.assignNoCorrection(toDeviceUID: "casse")  // replaces the preset
        #expect(settings.presetAssignments["casse"] == nil && settings.noCorrectionOutputs.contains("casse"))
        #expect(settings.outputAssignment(forDeviceUID: "casse") == .noCorrection)

        try settings.assignPreset(id: studio, toDeviceUID: "tv")  // replaces "no correction"
        #expect(!settings.noCorrectionOutputs.contains("tv"))
        #expect(settings.outputAssignment(forDeviceUID: "tv") == .preset(studio))

        settings.clearAssignment(deviceUID: "casse")
        #expect(settings.outputAssignment(forDeviceUID: "casse") == nil)
        settings.assignNoCorrection(toDeviceUID: "")  // ignored
        #expect(!settings.noCorrectionOutputs.contains(""))
    }

    @Test func deletingAPresetLeavesNoCorrectionAlone() throws {
        var (settings, _, headphones) = try setup()
        try settings.deletePreset(id: headphones)
        #expect(settings.noCorrectionOutputs == ["tv"])
        #expect(settings.outputAssignment(forDeviceUID: "cuffie") == nil)
    }

    @Test func namesAreKeptForNoCorrectionOutputs() throws {
        var (settings, _, _) = try setup()
        settings.deviceNames = ["tv": "Televisore", "altro": "Non serve"]
        settings.pruneDeviceNames()
        #expect(settings.deviceNames == ["tv": "Televisore"])
        #expect(settings.outputsWithRules == ["casse", "cuffie", "tv"])
        settings.clearAssignment(deviceUID: "tv")
        #expect(settings.deviceNames.isEmpty)
    }
}

@Suite("No correction: output changes")
struct NoCorrectionOutputChangeTests {
    /// A "no correction" output is transparent: going there and back
    /// changes nothing, unsaved edits included.
    @Test func goingToNoCorrectionAndBackKeepsTheSound() throws {
        var (settings, studio, _) = try setup()
        settings.bands[0].gain = -1  // unsaved edit on the speakers
        let edited = settings.bands
        #expect(settings.outputDidChange(to: "tv") == .noCorrection)
        #expect(settings.lastOutputDeviceUID == "casse")
        #expect(settings.bands == edited && settings.editsByDevice.isEmpty)
        #expect(settings.outputDidChange(to: "tv") == .noCorrection)  // still there: same answer
        #expect(settings.outputDidChange(to: "casse") == .unchanged)
        #expect(settings.bands == edited && settings.activePresetID == studio)
    }

    /// From "no correction" to another output: the edits belong to the
    /// output before the pause.
    @Test func goingOnFromNoCorrectionStashesForThePreviousOutput() throws {
        var (settings, studio, headphones) = try setup()
        settings.bands[0].gain = -1
        let edited = settings.bands
        _ = settings.outputDidChange(to: "tv")
        #expect(settings.outputDidChange(to: "cuffie") == .appliedPreset(headphones))
        #expect(settings.editsByDevice["casse"]?.bands == edited)
        #expect(settings.editsByDevice["tv"] == nil)
        #expect(settings.outputDidChange(to: "casse") == .restoredEdits(presetID: studio, assignedPresetID: nil))
    }

    /// Paused on the TV (recorded: the speakers), the TV gets a preset: it
    /// is applied, the speakers' unsaved edits are remembered for them.
    @Test func leavingNoCorrectionOnTheCurrentOutputAppliesItsPreset() throws {
        var (settings, studio, headphones) = try setup()
        settings.bands[0].gain = -1
        let edited = settings.bands
        _ = settings.outputDidChange(to: "tv")
        try settings.assignPreset(id: headphones, toDeviceUID: "tv")
        #expect(settings.noCorrectionLifted(onCurrentOutput: "tv") == .appliedPreset(headphones))
        #expect(settings.lastOutputDeviceUID == "tv" && settings.activePresetID == headphones)
        #expect(settings.editsByDevice["casse"]?.bands == edited)
        #expect(settings.outputDidChange(to: "casse") == .restoredEdits(presetID: studio, assignedPresetID: nil))
    }

    /// (a) "No correction" set on the output in use (already recorded),
    /// then replaced by a preset: applied at once, always; the unsaved
    /// edits are remembered for that output and come back with it.
    @Test func noCorrectionOnTheRecordedOutputThenAPreset() throws {
        var (settings, studio, headphones) = try setup()
        settings.bands[0].gain = -1
        let edited = settings.bands
        settings.assignNoCorrection(toDeviceUID: "casse")  // while in use
        #expect(settings.engineMode(userWantsOn: true, outputUID: "casse") == .paused)
        #expect(settings.outputDidChange(to: "casse") == .noCorrection)  // even though recorded
        try settings.assignPreset(id: headphones, toDeviceUID: "casse")
        #expect(settings.noCorrectionLifted(onCurrentOutput: "casse") == .appliedPreset(headphones))
        #expect(settings.activePresetID == headphones && !settings.hasUnsavedChanges)
        #expect(settings.editsByDevice["casse"]?.bands == edited)
        #expect(settings.editsByDevice["casse"]?.presetID == studio)
        // Leaving without new unsaved changes keeps them; back on the
        // speakers they are restored (user work wins over the assignment).
        #expect(settings.outputDidChange(to: "cuffie") == .appliedPreset(headphones))
        #expect(settings.editsByDevice["casse"]?.bands == edited)
        #expect(settings.outputDidChange(to: "casse") == .restoredEdits(presetID: studio, assignedPresetID: headphones))
        #expect(settings.bands == edited)
    }

    /// Lifting "no correction" with no preset (no rule): like arriving, the
    /// sound stays.
    @Test func noCorrectionLiftedWithoutAPreset() throws {
        var (settings, _, _) = try setup()
        let before = settings.bands
        settings.clearAssignment(deviceUID: "tv")
        #expect(settings.noCorrectionLifted(onCurrentOutput: "tv") == .unchanged)
        #expect(settings.bands == before && settings.lastOutputDeviceUID == "tv")
    }

    /// (b) The recorded output has "no correction" (rule set while in use):
    /// going on to another output remembers the edits for it, and they come
    /// back when it has correction again.
    @Test func recordedOutputWithNoCorrectionKeepsItsEdits() throws {
        var (settings, studio, headphones) = try setup()
        settings.bands[0].gain = -1
        let edited = settings.bands
        settings.assignNoCorrection(toDeviceUID: "casse")
        #expect(settings.outputDidChange(to: "cuffie") == .appliedPreset(headphones))
        #expect(settings.editsByDevice["casse"]?.bands == edited)
        #expect(settings.outputDidChange(to: "casse") == .noCorrection)  // kept, not restored
        #expect(settings.editsByDevice["casse"]?.bands == edited)
        settings.clearAssignment(deviceUID: "casse")
        #expect(settings.outputDidChange(to: "casse") == .restoredEdits(presetID: studio, assignedPresetID: nil))
        #expect(settings.bands == edited)
    }

    /// (b) A version-3 document saved with the option off may have recorded
    /// a "no correction" output: now that the rules always apply it pauses
    /// there, and edits are still remembered for it.
    @Test func recordedWithTheOldOptionOff() throws {
        var (settings, studio, headphones) = try setup()
        settings.lastOutputDeviceUID = "tv"  // as recorded by version 3 with the option off
        settings.bands[0].gain = -1
        let edited = settings.bands
        #expect(settings.engineMode(userWantsOn: true, outputUID: "tv") == .paused)
        #expect(settings.outputDidChange(to: "tv") == .noCorrection)
        #expect(settings.outputDidChange(to: "cuffie") == .appliedPreset(headphones))
        #expect(settings.editsByDevice["tv"]?.bands == edited)
        try settings.assignPreset(id: studio, toDeviceUID: "tv")
        #expect(settings.outputDidChange(to: "tv") == .restoredEdits(presetID: studio, assignedPresetID: nil))
    }

    /// "No correction" outputs are never recorded; no output changes nothing.
    @Test func noCorrectionOutputIsNotRecorded() throws {
        var (settings, _, _) = try setup()
        #expect(settings.outputDidChange(to: "tv") == .noCorrection)
        #expect(settings.outputDidChange(to: nil) == .unchanged)
        #expect(settings.lastOutputDeviceUID == "casse")
    }
}

@Suite("No correction: settings document")
struct NoCorrectionDocumentTests {
    @Test func roundTrip() throws {
        let (settings, _, _) = try setup()
        let data = try settings.encoded()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["noCorrectionOutputs"] as? [String] == ["tv"])
        #expect(object["version"] as? Int == 4)
        let loaded = AppSettings.load(current: data, legacy: nil, ownBundleID: own)
        #expect(loaded.settings == settings)
        #expect(loaded.backups.isEmpty && loaded.warnings.isEmpty && loaded.notice == nil)
    }

    /// Documents saved before this feature (version 2, no field) load as
    /// before, with no warning and no notice (a plain backup of the older
    /// format is kept before it is converted).
    @Test func version2DocumentsLoadUnchanged() throws {
        var (settings, _, _) = try setup()
        settings.clearAssignment(deviceUID: "tv")
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        object.removeValue(forKey: "noCorrectionOutputs")
        object["version"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)
        let loaded = AppSettings.load(current: data, legacy: nil, ownBundleID: own)
        #expect(loaded.settings == settings)
        #expect(loaded.settings.noCorrectionOutputs.isEmpty && loaded.settings.version == AppSettings.currentVersion)
        #expect(loaded.warnings.isEmpty && loaded.notice == nil && loaded.upgraded)
        #expect(loaded.backups == [.init(sourceKey: "RoomEQSettings", data: data)])
    }

    @Test func unreadableFieldIsReportedAndTheRestIsKept() throws {
        let (settings, studio, _) = try setup()
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        object["noCorrectionOutputs"] = ["tv": true]  // wrong type
        let loaded = AppSettings.load(
            current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(loaded.settings.noCorrectionOutputs.isEmpty)
        #expect(loaded.settings.presetAssignments["casse"] == studio)
        #expect(loaded.warnings.contains("Uscite senza correzione illeggibile"))
        #expect(loaded.backups.map(\.sourceKey) == ["RoomEQSettings"])
    }

    /// The set is stored as a sorted array: same content, same bytes.
    @Test func storedSortedAndByteStable() throws {
        var (settings, _, _) = try setup()
        for uid in ["zeta", "alfa", "mu"] { settings.assignNoCorrection(toDeviceUID: uid) }
        let data = try settings.encoded()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["noCorrectionOutputs"] as? [String] == ["alfa", "mu", "tv", "zeta"])
        var copy = settings
        copy.noCorrectionOutputs = Set(["tv", "zeta", "mu", "alfa"])
        #expect(try copy.encoded() == data)
    }

    /// (c) One unreadable element does not lose the others.
    @Test func unreadableElementIsSkipped() throws {
        let (settings, _, _) = try setup()
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        object["noCorrectionOutputs"] = ["tv", 7, "hdmi"]
        let loaded = AppSettings.load(
            current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(loaded.settings.noCorrectionOutputs == ["tv", "hdmi"])
        #expect(loaded.warnings.contains("1 uscite senza correzione illeggibili ignorate"))
        #expect(loaded.backups.map(\.sourceKey) == ["RoomEQSettings"])
    }

    /// (d) A newer document with the field: read, and backed up.
    @Test func newerVersionKeepsTheField() throws {
        let (settings, _, _) = try setup()
        var object = try JSONSerialization.jsonObject(with: try settings.encoded()) as! [String: Any]
        object["version"] = 9
        object["noCorrectionOutputs"] = ["tv", "hdmi"]
        object["somethingNew"] = 1
        let loaded = AppSettings.load(
            current: try JSONSerialization.data(withJSONObject: object), legacy: nil, ownBundleID: own)
        #expect(loaded.settings.noCorrectionOutputs == ["tv", "hdmi"])
        #expect(loaded.settings.version == AppSettings.currentVersion)
        #expect(loaded.backups.count == 1)
        #expect(loaded.warnings.first?.contains("versione 9") == true)
    }

    @Test func sanitizingKeepsOneRulePerOutput() throws {
        var (settings, studio, _) = try setup()
        settings.presetAssignments["tv"] = studio  // conflict (hand-edited data)
        settings.noCorrectionOutputs.insert("")
        let clean = settings.sanitized(ownBundleID: own)
        #expect(clean.noCorrectionOutputs == ["tv"])
        #expect(clean.presetAssignments["tv"] == nil && clean.presetAssignments["casse"] == studio)
    }
}
