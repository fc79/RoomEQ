// Texts (localized) of the panel's one-line status ("Correzione …"). Pure, so
// the wording is unit-tested; the controller picks one per engine state.
// "Correzione" is the only word used for what RoomEQ does (never EQ/bypass).

import Foundation

public enum CorrectionStatusText {
    /// Switched off: audio goes straight to the output.
    public static let off = String(localized: "Correzione spenta")
    /// Switched on but stopped by an error (the detail is shown apart).
    public static let notActive = String(localized: "Correzione non attiva")
    /// A start in progress.
    public static let starting = String(localized: "Avvio…")
    /// A restart in progress (buffer, exclusions, output or format change).
    public static let restarting = String(localized: "Riavvio…")
    /// Switching off in progress.
    public static let stopping = String(localized: "Spegnimento…")
    /// Retrying once after a sample-rate change.
    public static let retryAfterRateChange = String(localized: "Riprovo dopo il cambio di frequenza…")

    /// "Correzione attiva · Studio Interface · 6,3 ms" (no guillemets here, unlike the
    /// other sentences; parts without a value are left out).
    public static func active(outputName: String?, latencyMilliseconds: Double?) -> String {
        var parts = [String(localized: "Correzione attiva")]
        if let outputName, !outputName.isEmpty { parts.append(outputName) }
        if let latencyMilliseconds, latencyMilliseconds.isFinite, latencyMilliseconds > 0 {
            parts.append(AudioFormatText.milliseconds(latencyMilliseconds))
        }
        return parts.joined(separator: " · ")
    }

    /// "In pausa: nessuna correzione per «MacBook Speakers»".
    public static func paused(outputName: String?) -> String {
        guard let outputName, !outputName.isEmpty else { return String(localized: "In pausa: nessuna correzione per questa uscita") }
        return String(localized: "In pausa: nessuna correzione per «\(outputName)»")
    }

    /// "Attendo che l'uscita «Studio Interface» sia pronta…" (no output yet: "Attendo un'uscita audio…").
    public static func waiting(outputName: String?) -> String {
        guard let outputName, !outputName.isEmpty else { return String(localized: "Attendo un'uscita audio…") }
        return String(localized: "Attendo che l'uscita «\(outputName)» sia pronta…")
    }

    /// "Riprendo su «Studio Interface»…" (automatic resume after a pause).
    public static func resuming(outputName: String) -> String { String(localized: "Riprendo su «\(outputName)»…") }

    /// "«Studio Interface» scollegato, passo all'uscita di macOS…".
    public static func deviceLost(name: String) -> String {
        String(localized: "«\(name)» scollegato, passo all'uscita di macOS…")
    }
}
