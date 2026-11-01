// Keeps the menu bar panel attached to the menu bar when its height changes.
//
// WHY
// The panel is a `MenuBarExtra` window whose height follows its content
// (collapsible sections). When the window is resized, AppKit keeps the
// frame's origin fixed, and screen coordinates start at the bottom-left: so
// the bottom edge stays put and the top edge moves, leaving the panel
// floating halfway down the screen.
//
// HOW
// The correct top edge is not "wherever it was at some moment" (that moment
// proved unreliable) but the menu bar itself:
//
//     top = window.screen.visibleFrame.maxY - gap
//
// `visibleFrame` excludes the menu bar, so its maxY is the bottom of the
// menu bar. `gap` is the small distance macOS leaves between the menu bar
// and the panel; it is measured when the window becomes key (the user just
// opened the panel and macOS just placed it) and kept only if plausible
// (0...12 pt), otherwise 0. The x coordinate is never touched.
//
// The top edge is put back:
//  - on every didResize, and again on the next run-loop turn, to win against
//    a resize animation or a later reposition by SwiftUI;
//  - on every didMove made by someone else while the window is visible
//    (our own moves are recognised by the `isApplying` flag).
// The correction is idempotent (it does nothing when the top edge is already
// within 0.5 pt of the target), so it cannot loop.
//
// Only the window that contains this view is observed: other windows (an
// NSOpenPanel opened from the panel, for instance) are ignored. A hidden
// window is left alone: macOS places it again when it is reopened.
//
// `frame` is not observed with KVO: Apple does not document NSWindow.frame
// as key-value observable, so the documented notifications are used instead.
//
// DIAGNOSTICS
// Every event is logged (category "panel", level notice, public values):
//   /usr/bin/log show --predicate 'subsystem == "com.federicociapi.RoomEQ" AND category == "panel"' --last 10m --info

import AppKit
import SwiftUI

extension View {
    /// Keeps the top edge of the window that contains this view attached to
    /// the menu bar when the window is resized (see the file header).
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
    /// Distance between the bottom of the menu bar and the top of the panel,
    /// as placed by macOS. Measured on didBecomeKey; 0 until then.
    private var gap: CGFloat = 0
    /// True while we move the window ourselves, so our own didMove is ignored.
    private var isApplying = false
    /// Owns the observer tokens; removes them when replaced or deallocated
    /// together with this view (so no isolated deinit is needed here).
    private var observers = ObserverBag()

    /// Differences below this are rounding noise, not a detached panel.
    private static let tolerance: CGFloat = 0.5
    /// A measured gap outside this range means the window was not placed
    /// under the menu bar yet (or was already detached): use 0 instead.
    private static let plausibleGap: ClosedRange<CGFloat> = 0...12

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers = ObserverBag()   // drops the observers of the previous window
        guard let window else {
            Log.panel.notice("viewDidMoveToWindow: no window")
            return
        }

        Log.panel.notice("""
            viewDidMoveToWindow: class=\(String(describing: type(of: window)), privacy: .public) \
            \(Self.describe(window), privacy: .public)
            """)

        observe(NSWindow.didBecomeKeyNotification, of: window) { view, window in
            view.measureGap(of: window)
        }
        observe(NSWindow.didResizeNotification, of: window) { view, window in
            view.restoreTopEdge(of: window, reason: "didResize")
            DispatchQueue.main.async { [weak view, weak window] in
                MainActor.assumeIsolated {
                    guard let view, let window else { return }
                    view.restoreTopEdge(of: window, reason: "didResize+async")
                }
            }
        }
        observe(NSWindow.didMoveNotification, of: window) { view, window in
            if view.isApplying {
                Log.panel.notice("didMove (ours): \(Self.describe(window), privacy: .public)")
                return
            }
            view.restoreTopEdge(of: window, reason: "didMove")
        }
    }

    /// Registers a main-queue observer for `name` posted by `window` only.
    private func observe(
        _ name: Notification.Name,
        of window: NSWindow,
        _ handler: @escaping @MainActor (AnchorView, NSWindow) -> Void
    ) {
        observers.add(NotificationCenter.default.addObserver(
            forName: name, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, window === self.window else { return }
                handler(self, window)
            }
        })
    }

    private func measureGap(of window: NSWindow) {
        guard let visible = window.screen?.visibleFrame else {
            Log.panel.notice("didBecomeKey: no screen, gap stays \(self.gap, privacy: .public)")
            return
        }
        let measured = visible.maxY - window.frame.maxY
        gap = Self.plausibleGap.contains(measured) ? measured : 0
        Log.panel.notice("""
            didBecomeKey: measured gap=\(measured, privacy: .public) -> using \(self.gap, privacy: .public) \
            \(Self.describe(window), privacy: .public)
            """)
    }

    private func restoreTopEdge(of window: NSWindow, reason: String) {
        let before = window.frame
        guard window.isVisible else {
            Log.panel.notice("\(reason, privacy: .public): hidden, left alone \(Self.describe(window), privacy: .public)")
            return
        }
        guard let screen = window.screen else {
            Log.panel.notice("\(reason, privacy: .public): no screen, left alone \(Self.describe(window), privacy: .public)")
            return
        }
        let targetTop = screen.visibleFrame.maxY - gap
        guard abs(before.maxY - targetTop) > Self.tolerance else {
            Log.panel.notice("\(reason, privacy: .public): already anchored \(Self.describe(window), privacy: .public)")
            return
        }

        isApplying = true
        window.setFrameTopLeftPoint(NSPoint(x: before.minX, y: targetTop))
        isApplying = false

        Log.panel.notice("""
            \(reason, privacy: .public): corrected top \(before.maxY, privacy: .public) -> \(targetTop, privacy: .public) \
            (gap \(self.gap, privacy: .public)); before \(Self.rect(before), privacy: .public) \
            after \(Self.rect(window.frame), privacy: .public)
            """)
    }

    // MARK: - Log formatting

    private static func rect(_ r: NSRect) -> String {
        String(format: "[x %.1f y %.1f w %.1f h %.1f top %.1f]",
               r.minX, r.minY, r.width, r.height, r.maxY)
    }

    private static func describe(_ window: NSWindow) -> String {
        var text = "frame=\(rect(window.frame)) visible=\(window.isVisible) key=\(window.isKeyWindow)"
        if let screen = window.screen {
            text += " screen.visibleFrame=\(rect(screen.visibleFrame)) screen.frame=\(rect(screen.frame))"
        } else {
            text += " screen=nil"
        }
        return text
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
