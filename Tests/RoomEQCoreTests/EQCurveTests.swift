import Foundation
import Testing
@testable import RoomEQCore

@Suite("EQ curve and suggested preamp")
struct EQCurveTests {
    func maximumBoost(_ bands: [EQBand], sampleRate: Double = 48_000) -> Double {
        EQCurve.maximumBoostDecibels(design: EQDesign(bands: bands, sampleRate: sampleRate), bands: bands)
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
        let decoded = try #require(EQSettings.decode(try settings.encoded()))
        #expect(decoded == settings)
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
    }

    @Test func garbageOrOtherVersionsAreRejected() throws {
        #expect(EQSettings.decode(Data("not json".utf8)) == nil)
        #expect(EQSettings.decode(Data("{}".utf8)) == nil)
        var future = EQSettings.defaults()
        future.version = 99
        #expect(EQSettings.decode(try future.encoded()) == nil)
    }
}
