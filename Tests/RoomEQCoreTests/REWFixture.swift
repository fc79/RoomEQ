import Foundation
@testable import RoomEQCore

/// Test data: a real REW room measurement (Generic equaliser, PK filters),
/// which earlier versions of the app used as built-in default filters. The
/// app now starts with no filters (`AppSettings.defaults()`); these are kept
/// here as a realistic case (low Fc, high Q) for the filter, smoothing,
/// import and settings tests.
enum REWFixture {
    /// The four PK filters. New IDs each call.
    static func bands() -> [EQBand] {
        [
            EQBand(frequency: 58.80, gain: -9.90, q: 10.664),
            EQBand(frequency: 76.60, gain: -6.80, q: 14.316),
            EQBand(frequency: 140.0, gain: -15.90, q: 4.267),
            EQBand(frequency: 192.0, gain: -5.40, q: 3.628),
        ]
    }

    /// Settings holding these filters as the working state and as the active
    /// preset "Studio" (unmodified), Ableton Live excluded, correction on:
    /// what earlier versions created at first launch, and what a stage-3
    /// migration produces.
    static func settings() -> AppSettings {
        AppSettings.migrating(EQSettings(bands: bands(), preampDecibels: 0, isEQEnabled: true))
    }
}
