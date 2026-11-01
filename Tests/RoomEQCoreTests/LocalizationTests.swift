import Foundation
import Testing
@testable import RoomEQCore

/// Texts and number formats of RoomEQCore. The texts are looked up with
/// `String(localized:)` in the main bundle: here the test runner, which has
/// no translations, so they stay Italian (the keys). The app's English texts
/// are checked by tools/check-localizations.swift at every build.
@Suite("Localization")
struct LocalizationTests {
    /// Without the app setting it, the locale is Italian (what the other
    /// tests expect), whatever the region of the machine.
    @Test func defaultLocaleIsItalian() {
        #expect(TextLocale.current.identifier == "it_IT")
        #expect(NumberText.string(44.1, decimals: 0...1) == "44,1")
    }

    @Test func textsStayItalianWithoutTranslations() {
        #expect(CorrectionStatusText.off == "Correzione spenta")
        #expect(PresetNames.untitled == "Senza nome")
        #expect(PresetError.duplicateName("Studio").errorDescription == "Esiste già un preset chiamato «Studio».")
    }

    /// The same numbers with a US region: only the separator changes.
    @Test func decimalPoint() {
        let us = Locale(identifier: "en_US")
        #expect(AudioFormatText.kilohertz(44_100, locale: us) == "44.1 kHz")
        #expect(AudioFormatText.kilohertz(48_000, locale: us) == "48 kHz")
        #expect(AudioFormatText.oneDecimal(-3.46, locale: us) == "-3.5")
        #expect(AudioFormatText.oneDecimal(-0.04, locale: us) == "0.0")
        #expect(NumberText.compact(58.80, locale: us) == "58.8")
        #expect(NumberText.compact(1000, locale: us) == "1000")
        #expect(NumberText.compact(19_845.4, maxDecimals: 0, locale: us) == "19845")
        #expect(NumberText.compact(-24, locale: us) == "-24")
    }

    /// The one formatter: fixed or variable decimals, no thousands
    /// separator, halves away from zero, no sign on a rounded zero.
    @Test func numberText() {
        let it = Locale(identifier: "it_IT")
        #expect(NumberText.string(19_845.4, decimals: 0...1, locale: it) == "19845,4")
        #expect(NumberText.string(5, decimals: 1...1, locale: it) == "5,0")
        #expect(NumberText.string(1.25, decimals: 1...1, locale: it) == "1,3")
        #expect(NumberText.string(-1.25, decimals: 1...1, locale: it) == "-1,3")
        #expect(NumberText.string(0.105, decimals: 0...2, locale: it) == "0,11")
        #expect(NumberText.string(-0.04, decimals: 1...1, minusSign: "\u{2212}", locale: it) == "0,0")
        #expect(NumberText.string(-3.5, decimals: 1...1, minusSign: "\u{2212}", locale: it) == "\u{2212}3,5")
        #expect(NumberText.string(2, decimals: 1...1, plusSign: true, locale: it) == "+2,0")
        #expect(NumberText.string(0.01, decimals: 1...1, plusSign: true, locale: it) == "0,0")
        #expect(NumberText.string(.nan, decimals: 1...1, locale: it) == "—")
        #expect(NumberText.string(-.infinity, decimals: 1...1, locale: it) == "—")
        #expect(NumberText.format(.nan, decimals: 1, locale: it) == "non valido")
        #expect(NumberText.format(.infinity, decimals: 1, locale: it) == "∞")
        // The locale's own digits, as everywhere in macOS (Arabic, Egypt).
        #expect(NumberText.string(-0.04, decimals: 1...1, locale: Locale(identifier: "ar_EG")) == "٠٫٠")
        #expect(AudioFormatText.kilohertz(44_100, locale: Locale(identifier: "ar_EG")) == "٤٤٫١ kHz")
    }

    /// The separator really comes from the locale's conventions.
    @Test func separatorsOfLocales() {
        #expect(NumberText.string(1.5, decimals: 1...1, locale: Locale(identifier: "en_US")) == "1.5")
        #expect(NumberText.string(1.5, decimals: 1...1, locale: Locale(identifier: "en_IT")) == "1,5")  // English, Italian region
    }

    /// Preset names compare the same way whatever the region: case and
    /// accents ignored, Turkish dotless ı still different from I.
    @Test func presetNamesIgnoreRegion() {
        #expect(PresetNames.same("Studio", "STUDIO"))
        #expect(PresetNames.same("Città", "citta"))
        #expect(PresetNames.same("Ìnterno", "interno"))
        #expect(!PresetNames.same("I", "ı"))
        #expect(!PresetNames.same("Studio", "Studio 2"))
    }
}
