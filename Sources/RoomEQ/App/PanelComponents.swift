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

    /// Friendly name for a bundle ID: the installed app's name when found,
    /// otherwise the bundle ID itself.
    static func appName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
