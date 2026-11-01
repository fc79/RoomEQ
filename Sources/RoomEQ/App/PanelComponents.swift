// Small reusable SwiftUI pieces and formatting helpers for the menu panel:
// the collapsible section, dismissible messages and inline notes, the inline
// confirmation card, the level meter and the number formats.
//
// Texts: fixed texts are localized (String(localized:) / LocalizedStringKey,
// en.lproj and it.lproj in the app bundle, see tools/check-localizations.swift);
// parameters that always receive a fixed text take a `String.LocalizationValue`,
// parameters that receive composed or user text take an already localized `String`.

import AppKit
import Observation
import RoomEQCore
import SwiftUI

// MARK: - Layout

/// A collapsible block of the panel: title on the left, a short summary on
/// the right (visible also when closed), chevron to open it. The whole title
/// row toggles it. Closed by default; the open/closed state is remembered
/// between launches (UserDefaults key "panel.section.<storageKey>").
struct CollapsibleSection<Content: View>: View {
    let title: String
    let summary: String?
    /// An unread error is inside: a red dot next to the title (visible also
    /// when the section is closed).
    let hasError: Bool
    @AppStorage private var isExpanded: Bool
    private let content: Content

    init(
        title: String.LocalizationValue, summary: String? = nil, hasError: Bool = false, storageKey: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = String(localized: title)
        self.summary = summary
        self.hasError = hasError
        _isExpanded = AppStorage(wrappedValue: false, "panel.section.\(storageKey)")
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                        .font(.body.weight(.semibold))
                        .fixedSize()
                    if hasError {
                        Circle().fill(.red).frame(width: 7, height: 7)
                    }
                    Spacer(minLength: 8)
                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                ([title] + (summary.map { [$0] } ?? []) + (hasError ? [String(localized: "contiene un errore")] : []))
                    .joined(separator: ", "))
            .accessibilityValue(isExpanded ? String(localized: "aperta") : String(localized: "chiusa"))
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A message line with a dismiss button (✕).
struct DismissibleMessage: View {
    let text: String
    var color: Color = .red
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Chiudi il messaggio")
            .accessibilityLabel("Chiudi il messaggio")
        }
    }
}

/// A small status/error message that can be shown under a control.
struct InlineNote: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool

    static func error(_ text: String) -> InlineNote { InlineNote(text: text, isError: true) }
    static func info(_ text: String) -> InlineNote { InlineNote(text: text, isError: false) }
}

struct InlineNoteView: View {
    let note: InlineNote?

    var body: some View {
        if let note {
            Text(note.text)
                .font(.callout.weight(note.isError ? .medium : .regular))
                .foregroundStyle(note.isError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension NSImage {
    /// A copy scaled to a square of `side` points (the original is untouched).
    func resized(toSide side: CGFloat) -> NSImage {
        let copy = (self.copy() as? NSImage) ?? self
        copy.size = NSSize(width: side, height: side)
        return copy
    }
}

// MARK: - Inline confirmations
//
// Confirmations are drawn INSIDE the panel (a card over the dimmed panel
// content), never with `.alert` / `.confirmationDialog` / sheets: those open
// separate windows, the menu-bar panel loses key status and closes, taking
// them with it. Any view asks through the `ConfirmationPresenter` in the
// environment (installed by MenuPanelView).

/// A question with one or more actions; "Annulla" is always added. The
/// title and the option titles are fixed texts (localized here), the message
/// is composed by the caller (already localized).
struct InlineConfirmation: Identifiable {
    enum Role {
        /// The expected answer: gets the Return key.
        case standard
        /// Throws something away: red, never the Return key.
        case destructive
    }

    struct Option: Identifiable {
        let id = UUID()
        let title: String
        let role: Role
        let action: () -> Void
    }

    let id = UUID()
    let title: String
    let message: String
    let options: [Option]

    init(title: String.LocalizationValue, message: String = "", options: [Option]) {
        self.title = String(localized: title)
        self.message = message
        self.options = options
    }
}

extension InlineConfirmation.Option {
    static func standard(_ title: String.LocalizationValue, action: @escaping () -> Void) -> Self {
        Self(title: String(localized: title), role: .standard, action: action)
    }

    static func destructive(_ title: String.LocalizationValue, action: @escaping () -> Void) -> Self {
        Self(title: String(localized: title), role: .destructive, action: action)
    }
}

/// Holds the confirmation currently shown (at most one).
@MainActor
@Observable
final class ConfirmationPresenter {
    private(set) var current: InlineConfirmation?

    /// Shows a confirmation (replacing a pending one).
    func present(_ confirmation: InlineConfirmation) { current = confirmation }

    func dismiss() { current = nil }

    /// Closes the card, then runs the chosen action.
    func choose(_ option: InlineConfirmation.Option) {
        current = nil
        option.action()
    }
}

/// The card: title, message, one full-width button per answer.
struct InlineConfirmationCard: View {
    let confirmation: InlineConfirmation
    let choose: (InlineConfirmation.Option) -> Void
    let cancel: () -> Void

    /// The first standard option answers to Return.
    private var defaultOptionID: UUID? { confirmation.options.first { $0.role == .standard }?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(confirmation.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !confirmation.message.isEmpty {
                Text(confirmation.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(confirmation.options) { option in
                    if option.id == defaultOptionID {
                        button(option).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    } else {
                        button(option).buttonStyle(.bordered)
                    }
                }
                Button(action: cancel) {
                    Text("Annulla").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func button(_ option: InlineConfirmation.Option) -> some View {
        Button(role: option.role == .destructive ? .destructive : nil) {
            choose(option)
        } label: {
            Text(option.title).frame(maxWidth: .infinity)
        }
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
                .font(.callout.weight(.medium))
                .frame(width: 12, alignment: .leading)
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
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

/// Red "CLIP" badge.
struct ClipBadge: View {
    var body: some View {
        Text(verbatim: "CLIP")
            .font(.callout.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.red))
    }
}

// MARK: - Formatting
//
// Numbers follow the user's locale (`TextLocale.current`, set at launch to
// the macOS language and region, like Apple's apps do): "−12,3 dB" with an
// Italian region, "−12.3 dB" with a US one. They all go through
// `NumberText` (RoomEQCore), the same formatter as the messages of
// RoomEQCore, so digits and separators are the same everywhere. The minus
// sign of the UI is the real one (U+2212); units are not translated.

enum Format {
    /// "−12,3 dB" (real minus sign), or "—" for silence (zero, −∞ or below
    /// -90 dB: such values would only show a meaningless long number).
    static func decibels(_ value: Float) -> String {
        guard value.isFinite, value >= -90 else { return "—" }
        return "\(signedNumber(Double(value), decimals: 1)) dB"
    }

    /// "-3,5 dB" with a real minus sign (U+2212); "0,0 dB" for zero (never
    /// "-0,0"). `plusSign` adds "+" to positive values (gains of a filter).
    static func signedDecibels(_ value: Double, plusSign: Bool = false) -> String {
        "\(signedNumber(value, decimals: 1, plusSign: plusSign)) dB"
    }

    /// Number with a fixed count of decimals and a real minus sign; a value
    /// that rounds to zero is shown without sign.
    static func signedNumber(_ value: Double, decimals: Int, plusSign: Bool = false) -> String {
        NumberText.string(value, decimals: decimals...decimals, minusSign: "\u{2212}", plusSign: plusSign)
    }

    /// "58,8 Hz", "140 Hz", "1,20 kHz".
    static func frequency(_ hertz: Double) -> String {
        guard hertz.isFinite else { return "—" }
        if hertz >= 1000 {
            return "\(NumberText.string(hertz / 1000, decimals: 2...2)) kHz"
        }
        return "\(NumberText.string(hertz, decimals: 0...1)) Hz"
    }

    /// "Q 10,66".
    static func qFactor(_ q: Double) -> String {
        guard q.isFinite else { return "Q —" }
        return "Q \(NumberText.string(q, decimals: 2...2))"
    }

    /// Number format of the editable fields (same rules as the texts).
    static func fieldStyle(maxDecimals: Int) -> FloatingPointFormatStyle<Double> {
        NumberText.style(decimals: 0...maxDecimals)
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
