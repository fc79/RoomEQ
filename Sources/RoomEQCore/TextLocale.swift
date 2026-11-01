// The locale of the numbers written in texts, shared by RoomEQCore and the
// app, and the one number formatter that uses it (`NumberText`).
//
// Italian by default: the development language, and what the unit tests
// expect ("44,1 kHz"), whatever the region of the machine running them. The
// app sets it to the user's locale at launch (AppDelegate.init, before
// anything is formatted), so numbers follow the macOS region like in Apple's
// apps: decimal comma in Italy, point in the US, also when the interface is
// in English.
//
// Preset names are NOT compared with this locale: see `PresetNames.same`.
//
// The texts themselves are localized with `String(localized:)`, which reads
// the app bundle at runtime (en.lproj / it.lproj); in the unit tests the
// main bundle has no translations, so they stay Italian.

import Foundation
import Synchronization

public enum TextLocale {
    private static let storage = Mutex(Locale(identifier: "it_IT"))

    /// Locale for the numbers in texts.
    public static var current: Locale {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// The one number formatter of RoomEQ, used by RoomEQCore and by the app's
/// `Format`, so that every number shows the same digits and decimal
/// separator: the full rules of `TextLocale.current` (digits, separator),
/// never a thousands separator ("19845 Hz"), halves rounded away from zero.
public enum NumberText {
    /// Format style of every number: also used directly by the editable
    /// fields of the app (which need a style, to parse what the user types).
    public static func style(
        decimals: ClosedRange<Int>, locale: Locale = TextLocale.current
    ) -> FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(decimals)).grouping(.never)
            .rounded(rule: .toNearestOrAwayFromZero).locale(locale)
    }

    /// `value` with at least `decimals.lowerBound` and at most
    /// `decimals.upperBound` decimals (trailing zeros dropped in between):
    /// "58,8" for 58.80 with 0...2, "5,0" for 5 with 1...1.
    /// A value that rounds to zero has no sign ("0,0", never "-0,0");
    /// `minusSign` is the sign of negative values ("-", or the real minus
    /// U+2212 in the UI); `plusSign` adds "+" to positive ones.
    /// Not finite: "—".
    public static func string(
        _ value: Double, decimals: ClosedRange<Int>, minusSign: String = "-", plusSign: Bool = false,
        locale: Locale = TextLocale.current
    ) -> String {
        guard value.isFinite else { return "—" }
        let decimals = max(0, decimals.lowerBound)...max(0, decimals.upperBound)
        let text = abs(value).formatted(style(decimals: decimals, locale: locale))
        // Zero after rounding? Checked on the same rounding with plain ASCII
        // digits (the locale may use other digits, e.g. Arabic-Indic).
        let ascii = abs(value).formatted(style(decimals: decimals, locale: Locale(identifier: "en_US_POSIX")))
        guard ascii.contains(where: { "123456789".contains($0) }) else { return text }
        if value < 0 { return minusSign + text }
        return plusSign ? "+" + text : text
    }

    /// Fixed count of decimals ("5,70" with 2); "non valido" / "∞" / "-∞"
    /// for values that are not finite (messages about invalid input).
    static func format(_ value: Double, decimals: Int, locale: Locale = TextLocale.current) -> String {
        guard value.isFinite else {
            return value.isNaN ? String(localized: "non valido") : (value > 0 ? "∞" : "-∞")
        }
        return string(value, decimals: decimals...decimals, locale: locale)
    }

    /// "58,8" / "1000" style: up to `maxDecimals`, trailing zeros removed.
    static func compact(_ value: Double, maxDecimals: Int = 2, locale: Locale = TextLocale.current) -> String {
        guard value.isFinite else { return format(value, decimals: 0, locale: locale) }
        return string(value, decimals: 0...max(0, maxDecimals), locale: locale)
    }
}
