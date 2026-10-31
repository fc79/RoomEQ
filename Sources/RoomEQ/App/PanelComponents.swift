// Small reusable SwiftUI pieces and formatting helpers for the menu panel.

import AppKit
import SwiftUI

// MARK: - Layout

/// A titled block of the panel (small caption title + content).
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Level meter

/// Horizontal peak meter for one channel, scaled from -60 dBFS to 0 dBFS.
struct LevelMeterRow: View {
    let channel: String
    /// Linear peak amplitude (1.0 = 0 dBFS).
    let peak: Float

    private static let floorDecibels: Float = -60

    private var decibels: Float { peak > 0 ? 20 * log10(peak) : -.infinity }
    private var fraction: Double {
        guard decibels.isFinite else { return 0 }
        return Double(max(0, min(1, (decibels - Self.floorDecibels) / -Self.floorDecibels)))
    }
    private var barColor: Color {
        if decibels >= -0.5 { return .red }
        if decibels >= -6 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(channel)
                .font(.caption.weight(.medium))
                .frame(width: 10, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(0, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(Format.decibels(decibels))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// Red "CLIP" badge.
struct ClipBadge: View {
    var body: some View {
        Text("CLIP")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.red))
    }
}

// MARK: - Formatting (Italian conventions: decimal comma)

enum Format {
    private static let locale = Locale(identifier: "it_IT")

    /// "12,3" (one decimal).
    static func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// "44,1 kHz", "48 kHz".
    static func sampleRate(_ hertz: Double) -> String {
        let kilohertz = (hertz / 1000).formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return "\(kilohertz) kHz"
    }

    /// "-12,3 dB", or "-∞ dB" for silence.
    static func decibels(_ value: Float) -> String {
        guard value.isFinite else { return "-∞ dB" }
        let text = Double(value).formatted(.number.precision(.fractionLength(1)).locale(locale))
        return "\(text) dB"
    }

    /// "-3,5 dB" with a real minus sign (U+2212); "0,0 dB" for zero (never
    /// "-0,0"). `plusSign` adds "+" to positive values (gains of a filter).
    static func signedDecibels(_ value: Double, plusSign: Bool = false) -> String {
        "\(signedNumber(value, decimals: 1, plusSign: plusSign)) dB"
    }

    /// Number with a fixed count of decimals and a real minus sign; a value
    /// that rounds to zero is shown without sign.
    static func signedNumber(_ value: Double, decimals: Int, plusSign: Bool = false) -> String {
        guard value.isFinite else { return "—" }
        let scale = pow(10, Double(decimals))
        let rounded = (value * scale).rounded() / scale + 0  // "+ 0" turns -0 into 0
        let text = abs(rounded).formatted(.number.precision(.fractionLength(decimals)).grouping(.never).locale(locale))
        if rounded < 0 { return "\u{2212}\(text)" }
        return plusSign && rounded > 0 ? "+\(text)" : text
    }

    /// "58,8 Hz", "140 Hz", "1,20 kHz".
    static func frequency(_ hertz: Double) -> String {
        guard hertz.isFinite else { return "—" }
        if hertz >= 1000 {
            let text = (hertz / 1000).formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(locale))
            return "\(text) kHz"
        }
        let text = hertz.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))
        return "\(text) Hz"
    }

    /// "Q 10,66".
    static func qFactor(_ q: Double) -> String {
        guard q.isFinite else { return "Q —" }
        return "Q \(q.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(locale)))"
    }

    /// Number format of the editable fields (Italian decimal comma).
    static func fieldStyle(maxDecimals: Int) -> FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...maxDecimals)).grouping(.never).locale(locale)
    }

    /// Friendly name for a bundle ID: the installed app's name when found,
    /// otherwise the bundle ID itself.
    static func appName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
