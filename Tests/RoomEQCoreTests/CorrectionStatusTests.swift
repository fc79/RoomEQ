import Testing
@testable import RoomEQCore

@Suite("Correction status texts")
struct CorrectionStatusTests {
    @Test func numbersUseTheItalianComma() {
        #expect(AudioFormatText.oneDecimal(6.25) == "6,3")
        #expect(AudioFormatText.oneDecimal(6) == "6,0")
        #expect(AudioFormatText.oneDecimal(0.04) == "0,0")
        #expect(AudioFormatText.oneDecimal(-0.04) == "0,0")  // never "-0,0"
        #expect(AudioFormatText.oneDecimal(-3.46) == "-3,5")
        #expect(AudioFormatText.oneDecimal(12.96) == "13,0")
        #expect(AudioFormatText.oneDecimal(.nan) == "—")
        #expect(AudioFormatText.milliseconds(5.714) == "5,7 ms")
    }

    @Test func activeLine() {
        #expect(CorrectionStatusText.active(outputName: "Quantum", latencyMilliseconds: 6.28)
            == "Correzione attiva · Quantum · 6,3 ms")
        #expect(CorrectionStatusText.active(outputName: "Quantum", latencyMilliseconds: nil)
            == "Correzione attiva · Quantum")
        #expect(CorrectionStatusText.active(outputName: nil, latencyMilliseconds: 0) == "Correzione attiva")
    }

    @Test func otherLines() {
        #expect(CorrectionStatusText.off == "Correzione spenta")
        #expect(CorrectionStatusText.notActive == "Correzione non attiva")
        #expect(CorrectionStatusText.paused(outputName: "Altoparlanti MacBook")
            == "In pausa: nessuna correzione per «Altoparlanti MacBook»")
        #expect(CorrectionStatusText.paused(outputName: nil) == "In pausa: nessuna correzione per questa uscita")
        #expect(CorrectionStatusText.waiting(outputName: "Quantum") == "Attendo che l'uscita «Quantum» sia pronta…")
        #expect(CorrectionStatusText.waiting(outputName: "") == "Attendo un'uscita audio…")
        #expect(CorrectionStatusText.resuming(outputName: "Quantum") == "Riprendo su «Quantum»…")
        #expect(CorrectionStatusText.deviceLost(name: "Quantum") == "«Quantum» scollegato, passo all'uscita di macOS…")
        #expect(CorrectionStatusText.starting == "Avvio…" && CorrectionStatusText.restarting == "Riavvio…")
        #expect(CorrectionStatusText.stopping == "Spegnimento…")
    }

    /// The panel speaks of "Correzione" only: no EQ / bypass wording.
    @Test func noEQOrBypassWording() {
        let texts = [
            CorrectionStatusText.off, CorrectionStatusText.notActive, CorrectionStatusText.starting,
            CorrectionStatusText.restarting, CorrectionStatusText.stopping, CorrectionStatusText.retryAfterRateChange,
            CorrectionStatusText.active(outputName: "X", latencyMilliseconds: 5),
            CorrectionStatusText.paused(outputName: "X"), CorrectionStatusText.waiting(outputName: "X"),
            CorrectionStatusText.resuming(outputName: "X"), CorrectionStatusText.deviceLost(name: "X"),
        ]
        for text in texts {
            #expect(!text.contains("EQ") && !text.lowercased().contains("bypass"), "\(text)")
        }
    }
}
