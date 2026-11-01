// Fits the menu bar panel window to its content, top edge under the menu bar.
//
// WHY
// The panel is a `MenuBarExtra` window whose content changes height
// (collapsible sections). The diagnostic log showed that the window GROWS
// with the content but does NOT SHRINK when the content gets shorter: after
// opening and closing sections the window stayed 738 pt tall around ~428 pt
// of content, and SwiftUI centred the content in it, leaving empty space
// above and below. That is what made the panel look detached from the menu
// bar (the window itself was always anchored: top = visibleFrame.maxY).
//
// HOW
// The modifier measures the height of the content it is applied to (the
// panel's VStack with its fixed width, NOT a view that fills the window,
// otherwise it would measure the window itself) and hands it to an invisible
// AppKit view living in the same window. That view sets the window frame with
// `setFrame(_:display:)` whenever the window's content height differs from
// the content's height by more than 0.5 pt:
//
//     height = frameRect(forContentRect: content of that height).height
//     top    = window.screen.visibleFrame.maxY - gap
//     x, width unchanged
//
// `visibleFrame` excludes the menu bar, so its maxY is the bottom of the
// menu bar. `gap` is the small distance macOS leaves between the menu bar
// and the panel; it is measured when the window becomes key (the user just
// opened the panel and macOS just placed it) and kept only if plausible
// (0...12 pt), otherwise 0.
//
// When it runs:
//  - when the measured content height changes (coalesced to one fit per
//    run-loop turn, so an animated disclosure does not queue many);
//  - when the window becomes key (the panel was just opened);
//  - on every didResize made by someone else: if SwiftUI resizes the window
//    away from the content height, it is fitted again, but at most
//    `maxRefitsPerHeight` times per measured height, so a disagreement with
//    SwiftUI cannot become an endless loop (the log says "gave up");
//  - on every didMove made by someone else: only the top edge is put back.
// Every correction is idempotent (nothing happens within 0.5 pt of the
// target). Our own resizes and moves are recognised by the `isApplying` flag.
//
// Only the window that contains this view is observed: other windows (an
// NSOpenPanel opened from the panel, for instance) are ignored. A hidden
// window is left alone: it is fitted again when it becomes key.
//
// `frame` is not observed with KVO: Apple does not document NSWindow.frame
// as key-value observable, so the documented notifications are used instead.
//
// DIAGNOSTICS
// Every event is logged (category "panel", level notice, public values),
// including the measured content height and every resize (before/after):
//   /usr/bin/log show --predicate 'subsystem == "com.federicociapi.RoomEQ" AND category == "panel"' --last 10m --info

import AppKit
import SwiftUI

extension View {
    /// Keeps the window that contains this view as tall as this view, with
    /// its top edge under the menu bar (see the file header). Apply it to the
    /// content itself (fixed width, natural height), not to a view that fills
    /// the window.
    func fitsWindowToContent() -> some View {
        modifier(FitsWindowToContent())
    }
}

private struct FitsWindowToContent: ViewModifier {
    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            .background(PanelWindowAnchor(contentHeight: contentHeight))
    }
}

/// Invisible view whose only job is to find its window and size it.
private struct PanelWindowAnchor: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.contentHeightChanged(to: contentHeight)
    }
}

@MainActor
private final class AnchorView: NSView {
    /// Height of the SwiftUI content, as last measured; 0 until measured.
    private var contentHeight: CGFloat = 0
    /// Distance between the bottom of the menu bar and the top of the panel,
    /// as placed by macOS. Measured on didBecomeKey; 0 until then.
    private var gap: CGFloat = 0
    /// True while we resize/move the window ourselves, so our own
    /// notifications are ignored.
    private var isApplying = false
    /// A fit is already scheduled for the next run-loop turn.
    private var isFitScheduled = false
    /// Fits made after a resize by someone else, since the last height change.
    private var refits = 0
    /// Owns the observer tokens; removes them when replaced or deallocated
    /// together with this view (so no isolated deinit is needed here).
    private var observers = ObserverBag()

    /// Differences below this are rounding noise.
    private static let tolerance: CGFloat = 0.5
    /// A measured gap outside this range means the window was not placed
    /// under the menu bar yet (or was already detached): use 0 instead.
    private static let plausibleGap: ClosedRange<CGFloat> = 0...12
    /// How many times a resize by someone else is undone for the same
    /// content height before giving up (prevents a tug of war with SwiftUI).
    private static let maxRefitsPerHeight = 3

    // MARK: - Inputs

    func contentHeightChanged(to height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > Self.tolerance else { return }
        Log.panel.notice("content height measured: \(self.contentHeight, privacy: .public) -> \(height, privacy: .public)")
        contentHeight = height
        refits = 0
        scheduleFit(reason: "contentHeight")
    }

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
            view.fit(window, reason: "didBecomeKey")
        }
        observe(NSWindow.didResizeNotification, of: window) { view, window in
            if view.isApplying {
                Log.panel.notice("didResize (ours): \(Self.describe(window), privacy: .public)")
                return
            }
            view.handleForeignResize(of: window)
        }
        observe(NSWindow.didMoveNotification, of: window) { view, window in
            if view.isApplying {
                Log.panel.notice("didMove (ours): \(Self.describe(window), privacy: .public)")
                return
            }
            view.fit(window, reason: "didMove")
        }

        scheduleFit(reason: "viewDidMoveToWindow")
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

    // MARK: - Fitting

    /// Fits on the next run-loop turn: never inside a SwiftUI update, and
    /// several height changes in the same turn produce one fit.
    private func scheduleFit(reason: String) {
        guard !isFitScheduled else { return }
        isFitScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isFitScheduled = false
                guard let window = self.window else { return }
                self.fit(window, reason: reason)
            }
        }
    }

    /// Someone else (SwiftUI, AppKit) resized the window: fit it again, a
    /// limited number of times per content height.
    private func handleForeignResize(of window: NSWindow) {
        Log.panel.notice("didResize (not ours): \(Self.describe(window), privacy: .public)")
        if contentHeight > 0, abs(contentFrameHeight(of: window) - contentHeight) > Self.tolerance {
            guard refits < Self.maxRefitsPerHeight else {
                Log.panel.notice("""
                    didResize: window content height \(self.contentFrameHeight(of: window), privacy: .public) \
                    != content \(self.contentHeight, privacy: .public) after \(self.refits, privacy: .public) \
                    refits: gave up until the content height changes
                    """)
                // Still keep the top edge under the menu bar.
                fit(window, reason: "didResize (top only)", resizing: false)
                return
            }
            refits += 1
        }
        fit(window, reason: "didResize")
    }

    /// Sets the window frame so that its content is `contentHeight` tall
    /// (unless `resizing` is false or the height is not known yet) and its
    /// top edge is under the menu bar. Does nothing when already right.
    private func fit(_ window: NSWindow, reason: String, resizing: Bool = true) {
        let before = window.frame
        guard window.isVisible else {
            Log.panel.notice("\(reason, privacy: .public): hidden, left alone \(Self.describe(window), privacy: .public)")
            return
        }
        guard let screen = window.screen else {
            Log.panel.notice("\(reason, privacy: .public): no screen, left alone \(Self.describe(window), privacy: .public)")
            return
        }

        var height = before.height
        if resizing, contentHeight > 0 {
            let contentRect = window.contentRect(forFrameRect: before)
            height = window.frameRect(forContentRect: NSRect(
                x: contentRect.minX, y: contentRect.minY,
                width: contentRect.width, height: contentHeight
            )).height
        }
        let top = screen.visibleFrame.maxY - gap
        let target = NSRect(x: before.minX, y: top - height, width: before.width, height: height)

        guard abs(before.height - target.height) > Self.tolerance
                || abs(before.maxY - target.maxY) > Self.tolerance else {
            Log.panel.notice("""
                \(reason, privacy: .public): already fitted (content \(self.contentHeight, privacy: .public)) \
                \(Self.describe(window), privacy: .public)
                """)
            return
        }

        isApplying = true
        window.setFrame(target, display: true)
        isApplying = false

        Log.panel.notice("""
            \(reason, privacy: .public): resized/moved for content \(self.contentHeight, privacy: .public) \
            (gap \(self.gap, privacy: .public)); before \(Self.rect(before), privacy: .public) \
            target \(Self.rect(target), privacy: .public) after \(Self.rect(window.frame), privacy: .public)
            """)
    }

    private func contentFrameHeight(of window: NSWindow) -> CGFloat {
        window.contentRect(forFrameRect: window.frame).height
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

    // MARK: - Log formatting

    private static func rect(_ r: NSRect) -> String {
        String(format: "[x %.1f y %.1f w %.1f h %.1f top %.1f]",
               r.minX, r.minY, r.width, r.height, r.maxY)
    }

    private static func describe(_ window: NSWindow) -> String {
        let content = window.contentRect(forFrameRect: window.frame)
        var text = "frame=\(rect(window.frame)) content=\(rect(content))"
        text += String(format: " minSize=%.1fx%.1f maxSize=%.1fx%.1f contentMinSize=%.1fx%.1f contentMaxSize=%.1fx%.1f",
                       window.minSize.width, window.minSize.height,
                       window.maxSize.width, window.maxSize.height,
                       window.contentMinSize.width, window.contentMinSize.height,
                       window.contentMaxSize.width, window.contentMaxSize.height)
        text += " visible=\(window.isVisible) key=\(window.isKeyWindow)"
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
