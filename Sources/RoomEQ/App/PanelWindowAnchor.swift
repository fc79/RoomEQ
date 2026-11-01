// Keeps the menu bar panel attached to the menu bar when its height changes.
//
// The panel is a `MenuBarExtra` window whose height follows its content
// (collapsible sections). When SwiftUI resizes that window, AppKit keeps the
// frame's origin fixed, and screen coordinates start at the bottom-left: so
// the bottom edge stays put and the top edge moves, leaving the panel
// floating halfway down the screen. This modifier remembers where the top
// edge was and puts it back after every resize.
//
// The top-left point is recorded when the view first enters its window and
// every time the window becomes key (i.e. every time the user opens the
// panel, right after macOS has placed it under the status item). Only the
// window that contains the view is observed: other windows (an NSOpenPanel
// opened from the panel, for instance) are ignored.
//
// No feedback loop: `setFrameTopLeftPoint` only moves the window, it posts
// didMove, not didResize.

import AppKit
import SwiftUI

extension View {
    /// Keeps the top edge of the window that contains this view fixed when
    /// the window is resized (see the file header).
    func keepsTopEdgeAnchored() -> some View {
        background(PanelWindowAnchor())
    }
}

/// Invisible view whose only job is to find its window and watch it.
private struct PanelWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ nsView: AnchorView, context: Context) {}
}

@MainActor
private final class AnchorView: NSView {
    /// Remembered top-left corner (x = minX, y = maxY), in screen coordinates.
    private var anchor: NSPoint?
    /// Owns the observer tokens; removes them when replaced or deallocated
    /// together with this view (so no isolated deinit is needed here).
    private var observers = ObserverBag()

    /// Moves smaller than this are rounding noise, not a detached panel.
    private static let tolerance: CGFloat = 0.5

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers = ObserverBag()   // drops the observers of the previous window
        anchor = nil
        guard let window else { return }

        recordAnchor(of: window)
        let center = NotificationCenter.default
        observers.add(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.recordAnchor(of: window)
            }
        })
        observers.add(center.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.restoreTopEdge(of: window)
            }
        })
    }

    private func recordAnchor(of window: NSWindow) {
        anchor = NSPoint(x: window.frame.minX, y: window.frame.maxY)
    }

    private func restoreTopEdge(of window: NSWindow) {
        // Hidden panel: macOS places it again when it is reopened.
        guard window === self.window, window.isVisible, let anchor else { return }
        guard abs(window.frame.maxY - anchor.y) > Self.tolerance else { return }
        window.setFrameTopLeftPoint(anchor)
    }
}

/// Block-based NotificationCenter observers, removed on deinit.
/// Not actor-isolated on purpose: `removeObserver` is thread-safe, and this
/// lets the deinit run wherever the owning view is released.
private final class ObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
