// Custom menu bar icons, one per `MenuBarState`: a filled rounded rectangle
// with the state's symbol cut out of it. Drawn as vectors (sharp at any
// resolution) and marked as template, so macOS tints them for the light/dark
// menu bar and the highlighted state.

import AppKit

enum MenuBarIcons {
    /// Icon canvas in points; the origin is top-left (flipped drawing).
    private static let size = NSSize(width: 24, height: 18)

    // Built once: the menu bar view only picks one on each state change.
    private static let images: [MenuBarState: NSImage] = {
        let states: [MenuBarState] = [.stopped, .starting, .active, .bypassed, .failed]
        return Dictionary(uniqueKeysWithValues: states.map { ($0, makeImage(for: $0)) })
    }()

    static func image(for state: MenuBarState) -> NSImage {
        images[state] ?? makeImage(for: state)
    }

    private static func makeImage(for state: MenuBarState) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Drawing

    private static func draw(_ state: MenuBarState) {
        guard let context = NSGraphicsContext.current else { return }
        let base = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 20, height: 14),
                                xRadius: 2.5, yRadius: 2.5)
        NSColor.black.withAlphaComponent(state == .stopped ? 0.55 : 1).setFill()
        base.fill()

        // Everything below removes alpha from the base (destinationOut).
        context.compositingOperation = .destinationOut
        defer { context.compositingOperation = .sourceOver }

        switch state {
        case .active:
            cutEQCurves(top: 7.6, bottom: 10.4)
        case .bypassed:
            cutEQCurves(top: 4.8, bottom: 13.2)
        case .stopped:
            let slash = line(from: NSPoint(x: 3, y: 17), to: NSPoint(x: 21, y: 1))
            cut(slash, width: 3.6)
            // The slash itself is drawn back on top, fully opaque.
            context.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            slash.lineWidth = 1.5
            slash.stroke()
        case .starting:
            for x in [8.0, 12.0, 16.0] { cutDot(center: NSPoint(x: x, y: 9), radius: 1.4) }
        case .failed:
            cut(line(from: NSPoint(x: 12, y: 5), to: NSPoint(x: 12, y: 10)), width: 2)
            cutDot(center: NSPoint(x: 12, y: 13.1), radius: 1.2)
        }
    }

    /// Two crossing S-curves: the first fully cut, the second only partly
    /// (about 53% removed, so it stays at ~47% opacity).
    private static func cutEQCurves(top: CGFloat, bottom: CGFloat) {
        cut(curve(from: top, to: bottom), width: 1.7)
        cut(curve(from: bottom, to: top), width: 1.7, alpha: 0.53)
    }

    private static func curve(from startY: CGFloat, to endY: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 4.5, y: startY))
        path.curve(to: NSPoint(x: 19.5, y: endY),
                   controlPoint1: NSPoint(x: 9, y: startY),
                   controlPoint2: NSPoint(x: 15, y: endY))
        return path
    }

    private static func line(from a: NSPoint, to b: NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        return path
    }

    /// Strokes `path` with round caps in the current compositing operation.
    private static func cut(_ path: NSBezierPath, width: CGFloat, alpha: CGFloat = 1) {
        path.lineWidth = width
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private static func cutDot(center: NSPoint, radius: CGFloat) {
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }
}
