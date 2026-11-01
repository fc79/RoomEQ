// Per-output rule ("Preset per uscita") and the engine mode it leads to.
//
// Each output has no rule, a preset, or "no correction". With per-output
// presets on, RoomEQ PAUSES on a "no correction" output: tap, aggregate and
// IOProcs are released (audio goes straight to the device, as without
// RoomEQ) while the user's main switch stays on; it resumes by itself on an
// output with correction. The controller applies `EngineMode`.

import Foundation

/// The rule set for one output.
public enum OutputAssignment: Equatable, Hashable, Sendable {
    /// This preset is applied when the output becomes the macOS default.
    case preset(UUID)
    /// RoomEQ pauses while this output is the macOS default.
    case noCorrection
}

/// What RoomEQ should be doing.
public enum EngineMode: Equatable, Sendable {
    /// Switched off by the user.
    case off
    /// Switched on, but the current output is set to "no correction":
    /// nothing runs.
    case paused
    /// Switched on and correcting. The output's preset (if any) is applied
    /// by `AppSettings.outputDidChange`, not here.
    case active

    /// Pure decision. `assignment`: the rule of the macOS default output
    /// (nil = none, or no output). Rules count only with `perOutputEnabled`.
    public static func desired(userWantsOn: Bool, perOutputEnabled: Bool, assignment: OutputAssignment?) -> EngineMode {
        guard userWantsOn else { return .off }
        return perOutputEnabled && assignment == .noCorrection ? .paused : .active
    }
}
