import Foundation
import Testing
@testable import RoomEQCore

@Suite("EQ curve and suggested preamp")
struct EQCurveTests {
    func maximumBoost(_ bands: [EQBand], sampleRate: Double = 48_000) -> Double {
        EQCurve.maximumBoostDecibels(design: EQDesign(bands: bands, sampleRate: sampleRate))
    }

    /// The search starts at the lowest allowed Fc (10 Hz), not 20 Hz.
    @Test func boostBelow20HzIsFound() {
        let boost = maximumBoost([EQBand(frequency: 12, gain: 6, q: 20)])
        #expect(abs(boost - 6) < 1e-6)
        #expect(EQCurve.boostSearchFrequencies.first == 10)
        #expect(abs(EQCurve.boostSearchFrequencies.last! - 20_000) < 1e-6)
    }

    @Test func cutsOnlyGiveNoBoostAndNoSuggestedPreamp() {
        let boost = maximumBoost(EQBand.defaultBands())
        #expect(boost == 0)
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: boost) == 0)
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: boost).sign == .plus)  // not "-0"
    }

    @Test func singleBoostIsFoundAtItsCentre() {
        // A narrow boost between grid points is still found (Fc is added).
        let boost = maximumBoost([EQBand(frequency: 1234.5, gain: 6, q: 30)])
        #expect(abs(boost - 6) < 1e-6)
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: boost) == -6)
    }

    @Test func overlappingBoostsAddUp() {
        let bands = [EQBand(frequency: 1000, gain: 3, q: 1), EQBand(frequency: 1100, gain: 3, q: 1)]
        let boost = maximumBoost(bands)
        #expect(boost > 5.5 && boost < 6)
        // Cuts elsewhere don't hide the boost; disabled bands don't count.
        var withCut = bands + [EQBand(frequency: 60, gain: -12, q: 5)]
        #expect(abs(maximumBoost(withCut) - boost) < 0.01)
        withCut[0].isEnabled = false
        #expect(abs(maximumBoost(withCut) - 3) < 0.05)
    }

    @Test func suggestedPreampRoundsUpToATenth() {
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: 3.21) == -3.3)
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: 3.2) == -3.2)
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: 3.2000000001) == -3.2)
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: 0.01) == -0.1)
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: 0) == 0)
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: -2) == 0)
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: .nan) == 0)
        // Never outside the preamp range.
        #expect(EQCurve.suggestedPreampDecibels(forMaximumBoost: 30) == -24)
    }

    @Test func curveMatchesTheSumOfTheBands() {
        let bands = EQBand.defaultBands()
        let design = EQDesign(bands: bands, sampleRate: 44_100)
        let frequencies = EQCurve.logFrequencies(count: 50)
        #expect(frequencies.count == 50)
        #expect(abs(frequencies.first! - 20) < 1e-9 && abs(frequencies.last! - 20_000) < 1e-6)
        let combined = EQCurve.responseDecibels(
            coefficients: design.coefficients, sampleRate: 44_100, frequencies: frequencies)
        for (index, frequency) in frequencies.enumerated() {
            let sum = design.coefficients.reduce(0.0) {
                $0 + $1.magnitudeDecibels(atFrequency: frequency, sampleRate: 44_100)
            }
            #expect(abs(combined[index] - sum) < 1e-9)
        }
        // Empty EQ: flat.
        #expect(EQCurve.responseDecibels(coefficients: [], sampleRate: 48_000, frequencies: [20, 1000]) == [0, 0])
    }
}

@Suite("EQ settings persistence")
struct EQSettingsTests {
    @Test func defaultsAreTheREWFiltersWithPreamp0AndEQOn() {
        let settings = EQSettings.defaults()
        #expect(settings.bands.map(\.frequency) == [58.80, 76.60, 140.0, 192.0])
        #expect(settings.preampDecibels == 0)
        #expect(settings.isEQEnabled)
    }

    @Test func roundTrip() throws {
        var bands = EQBand.defaultBands()
        bands[2].isEnabled = false
        let settings = EQSettings(bands: bands, preampDecibels: -3.5, isEQEnabled: false)
        let loaded = EQSettings.load(try settings.encoded())
        #expect(loaded.status == .complete && loaded.warnings.isEmpty && !loaded.needsBackup)
        #expect(loaded.settings == settings)
    }

    @Test func sanitizesWhatItLoads() throws {
        var bands = (0..<20).map { EQBand(frequency: 100 + Double($0), gain: -1, q: 1) }
        bands[1] = EQBand(id: bands[0].id, frequency: 50, gain: -1, q: 1)  // duplicate ID
        bands[2].gain = .nan
        let clean = EQSettings(bands: bands, preampDecibels: 6, isEQEnabled: true).sanitized()
        #expect(clean.bands.count == 16)
        #expect(clean.bands.allSatisfy { $0.isFinite })
        #expect(Set(clean.bands.map(\.id)).count == 16)
        #expect(clean.preampDecibels == 0)
        #expect(EQSettings(bands: [], preampDecibels: -99, isEQEnabled: true).sanitized().preampDecibels == -24)
        #expect(EQSettings(bands: [], preampDecibels: .nan, isEQEnabled: true).sanitized().preampDecibels == 0)
    }

    /// One bad band doesn't lose the others; missing optional fields get
    /// defaults; the result asks for a backup.
    @Test func unreadableBandsAreSkippedNotEverything() throws {
        let json = """
            {"version": 1, "preampDecibels": -2.5, "isEQEnabled": false, "bands": [
              {"id": "8B1F7C2A-0000-4000-8000-000000000001", "frequency": 58.8, "gain": -9.9, "q": 10.664, "isEnabled": true},
              {"frequency": "molto", "gain": -3, "q": 1},
              {"frequency": 140, "gain": -15.9, "q": 4.267},
              42,
              {"id": "not-a-uuid", "frequency": 192, "gain": -5.4, "q": 3.628, "isEnabled": false}
            ]}
            """
        let loaded = EQSettings.load(Data(json.utf8))
        #expect(loaded.status == .partial && loaded.needsBackup)
        #expect(loaded.settings.bands.map(\.frequency) == [58.8, 140, 192])
        #expect(loaded.settings.bands.map(\.isEnabled) == [true, true, false])
        #expect(loaded.settings.bands[0].id == UUID(uuidString: "8B1F7C2A-0000-4000-8000-000000000001"))
        #expect(loaded.settings.preampDecibels == -2.5)
        #expect(loaded.settings.isEQEnabled == false)
        // Every fallback is reported (so a backup is taken): band 3 had no
        // ID and no on/off, band 5 an unreadable ID.
        #expect(loaded.warnings == [
            "Filtro salvato 2 illeggibile, ignorato",
            "Filtro salvato 3: identificativo illeggibile, rigenerato; stato attivo/disattivo illeggibile, attivato",
            "Filtro salvato 4 illeggibile, ignorato",
            "Filtro salvato 5: identificativo illeggibile, rigenerato",
        ])
    }

    /// A newer format version: the known fields are read (and a backup is asked for).
    @Test func futureVersionsAreReadForTheKnownFields() throws {
        let json = """
            {"version": 7, "preampDecibels": -1, "isEQEnabled": true, "presets": {"x": 1},
             "bands": [{"frequency": 80, "gain": -4, "q": 6, "isEnabled": true, "type": "PK", "slope": 12}]}
            """
        let loaded = EQSettings.load(Data(json.utf8))
        #expect(loaded.status == .partial)
        #expect(loaded.settings.bands.count == 1 && loaded.settings.bands[0].frequency == 80)
        #expect(loaded.settings.preampDecibels == -1)
        #expect(loaded.warnings.first?.contains("versione 7") == true)
    }

    @Test func wrongOrMissingFieldsGetDefaults() {
        let loaded = EQSettings.load(Data(#"{"preampDecibels": "alto", "bands": "nessuno"}"#.utf8))
        #expect(loaded.status == .partial)
        #expect(loaded.settings.preampDecibels == 0)
        #expect(loaded.settings.isEQEnabled)
        #expect(loaded.settings.bands.map(\.frequency) == EQBand.defaultBands().map(\.frequency))
    }

    @Test func garbageIsUnreadable() {
        for text in ["not json", "[1, 2]", "\"string\"", ""] {
            let loaded = EQSettings.load(Data(text.utf8))
            #expect(loaded.status == .unreadable && loaded.needsBackup, "\(text)")
            #expect(loaded.settings.bands.count == 4)
        }
    }
}

@Suite("Band edits")
struct BandEditTests {
    /// Editing one field of an out-of-range imported band must not silently
    /// clamp (and so re-enable) the others.
    @Test func onlyChangedFieldsAreClamped() {
        let imported = EQBand(frequency: 80, gain: 35, q: 4)  // +35 dB: out of range
        var edited = imported
        edited.frequency = 90
        let result = imported.applyingEdit(edited)
        #expect(result.frequency == 90 && result.gain == 35 && result.q == 4)
        #expect(EQDesign(bands: [result], sampleRate: 48_000).sections.isEmpty)  // still excluded

        edited = imported
        edited.gain = 50
        #expect(imported.applyingEdit(edited).gain == 30)  // the edited field is clamped
        edited = imported
        edited.q = .nan
        #expect(imported.applyingEdit(edited).q == 4)  // non-finite edit ignored
        edited = imported
        edited.isEnabled = false
        #expect(imported.applyingEdit(edited).isEnabled == false)
        #expect(imported.applyingEdit(imported) == imported)
    }
}
