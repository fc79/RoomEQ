// Per-output rule ("Impostazioni per uscita") and the engine mode it leads to.
//
// Each output has no rule (the default: nothing happens), a preset, or "no
// correction". The rules always apply (version 4: there is no option to
// turn them off). RoomEQ PAUSES on a "no correction" output: tap, aggregate
// and IOProcs are released (audio goes straight to the device, as without
// RoomEQ) while the user's "Correzione" switch stays on; it resumes by
// itself on an output with correction. The controller applies `EngineMode`.

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
    /// "Correzione" switched off by the user.
    case off
    /// Switched on, but the current output is set to "no correction":
    /// nothing runs.
    case paused
    /// Switched on and correcting. The output's preset (if any) is applied
    /// by `AppSettings.outputDidChange`, not here.
    case active

    /// Pure decision. `userWantsOn`: the "Correzione" switch;
    /// `assignment`: the rule of the macOS default output (nil = none, or
    /// no output).
    public static func desired(userWantsOn: Bool, assignment: OutputAssignment?) -> EngineMode {
        guard userWantsOn else { return .off }
        return assignment == .noCorrection ? .paused : .active
    }
}
