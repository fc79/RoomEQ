// Custom menu bar icons: the sliders of an equalizer, all drawn with round-capped
// strokes. There are only four looks, so one glance tells whether the
// correction is being applied:
//   applied      (.active)  three sliders at different heights
//   starting     (.starting) three dots on the rails
//   not applied  (stopped, paused) sliders lined up, crossed by a slash
//   error        (.failed)  exclamation mark between two side rails
// Drawn as vectors (sharp at any resolution) and marked as template, so macOS
// tints them for the light/dark menu bar and the highlighted state.

import AppKit

enum MenuBarIcons {
    /// What the icon shows; several `MenuBarState`s share one look.
    private enum Look: CaseIterable {
        case applied, starting, notApplied, error

        init(_ state: MenuBarState) {
            switch state {
            case .active: self = .applied
            case .starting: self = .starting
            case .failed: self = .error
            case .stopped, .paused: self = .notApplied
            }
        }
    }

    /// Icon canvas in points; the origin is top-left (flipped drawing).
    private static let size = NSSize(width: 24, height: 18)

    // Built once: the menu bar view only picks one on each state change.
    private static let images: [Look: NSImage] = Dictionary(
        uniqueKeysWithValues: Look.allCases.map { ($0, makeImage(for: $0)) })

    static func image(for state: MenuBarState) -> NSImage {
        let look = Look(state)
        return images[look] ?? makeImage(for: look)
    }

    /// Spoken label of the icon: unlike the looks, it tells every state
    /// apart (off and paused share one drawing).
    static func accessibilityLabel(for state: MenuBarState) -> String {
        switch state {
        case .stopped: String(localized: "Correzione spenta")
        case .starting: String(localized: "Correzione in avvio")
        case .active: String(localized: "Correzione attiva")
        case .failed: String(localized: "RoomEQ: errore")
        case .paused: String(localized: "Correzione in pausa per questa uscita")
        }
    }

    private static func makeImage(for look: Look) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            draw(look)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Drawing

    private static let railWidth: CGFloat = 1.2
    private static let railAlpha: CGFloat = 0.45
    private static let knobWidth: CGFloat = 2.4

    private static func draw(_ look: Look) {
        switch look {
        case .applied:
            rails(x: [7, 12, 17])
            knob(from: 5, to: 9, y: 11)
            knob(from: 10, to: 14, y: 5)
            knob(from: 15, to: 19, y: 9)
        case .starting:
            rails(x: [7, 12, 17])
            for x in [7.0, 12.0, 17.0] { dot(center: NSPoint(x: x, y: 9), radius: 1.6) }
        case .notApplied:
            rails(x: [7, 12, 17])
            for x in [5.0, 10.0, 15.0] { knob(from: x, to: x + 4, y: 9, alpha: 0.5) }
            let slash = line(from: NSPoint(x: 4, y: 17), to: NSPoint(x: 20, y: 1))
            // A transparent margin around the slash keeps it readable at real size.
            if let context = NSGraphicsContext.current {
                context.compositingOperation = .destinationOut
                stroke(slash, width: 3.4)
                context.compositingOperation = .sourceOver
            }
            stroke(slash, width: 1.6)
        case .error:
            rails(x: [5, 19])
            knob(from: 3, to: 7, y: 9, alpha: 0.5)
            knob(from: 17, to: 21, y: 9, alpha: 0.5)
            stroke(line(from: NSPoint(x: 12, y: 3), to: NSPoint(x: 12, y: 11)), width: knobWidth)
            dot(center: NSPoint(x: 12, y: 15), radius: 1.4)
        }
    }

    /// Vertical slider rails, from y=2 to y=16.
    private static func rails(x: [CGFloat]) {
        for x in x {
            stroke(line(from: NSPoint(x: x, y: 2), to: NSPoint(x: x, y: 16)),
                   width: railWidth, alpha: railAlpha)
        }
    }

    /// Horizontal slider knob.
    private static func knob(from x1: CGFloat, to x2: CGFloat, y: CGFloat, alpha: CGFloat = 1) {
        stroke(line(from: NSPoint(x: x1, y: y), to: NSPoint(x: x2, y: y)),
               width: knobWidth, alpha: alpha)
    }

    private static func line(from a: NSPoint, to b: NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        return path
    }

    /// Strokes `path` with round caps in the current compositing operation.
    private static func stroke(_ path: NSBezierPath, width: CGFloat, alpha: CGFloat = 1) {
        path.lineWidth = width
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private static func dot(center: NSPoint, radius: CGFloat) {
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }
}
