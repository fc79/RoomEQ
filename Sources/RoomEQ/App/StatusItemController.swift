// The menu bar item: the icon (NSStatusItem) and the panel shown under it
// (NSPopover hosting `MenuPanelView`).
//
// AppKit instead of SwiftUI's MenuBarExtra because the MenuBarExtra window
// grows with its content but never shrinks, and resizing it by hand made the
// panel jump. A popover whose content is an NSHostingController with
// `sizingOptions = .preferredContentSize` follows the content height by
// itself, both ways, with the arrow kept under the icon.
//
// Behaviour:
//  - a click on the icon opens the popover, a second click closes it;
//  - opening activates the app for real (`activateApp()`, see there why not
//    `NSApp.activate()`) and makes the popover window key, again when the
//    activation arrives late (didBecomeActive): otherwise the first click in
//    the panel (e.g. on a pop-up menu) is spent making the window key, and
//    the panel gets no keyboard (preset name fields, Cmd-Q for "Esci");
//  - the popover is `.applicationDefined`: AppKit never closes it by itself,
//    every close is decided here, for one of these reasons (each logged at
//    debug level, category "panel"):
//      * a click on the icon (the toggle);
//      * a click in another app (windows, desktop, other menu bar icons),
//        seen by a global mouse monitor, which works even if the app did not
//        become active;
//      * a click in one of our own windows other than the panel and the icon
//        (local monitor; in practice there are none);
//      * Esc, when nothing in the panel uses it (a "Annulla" button or a
//        text field get it first);
//      * the app losing active status (e.g. Cmd-Tab to another app).
//    With `.transient` AppKit examined the click on the icon itself: the
//    popover either closed on the mouse-down and the button's action then
//    reopened it, or, when the delegate refused the close, the click was
//    swallowed and the action never ran (macOS 26: the popover stayed open).
//    Owning every close removes that interplay;
//  - pop-up menus (Picker) in the panel keep working: their clicks are
//    handled by the menu's own tracking loop, which monitors do not see;
//  - just before opening, what may have changed outside the app is refreshed
//    (login item status, candidate apps to exclude);
//  - while a file chooser opened from the panel is up, nothing closes the
//    popover (see `runFileChooser`), so what the chooser leads to (an inline
//    confirmation, an error note) is seen right away.
// The icon and its accessibility label follow `controller.menuBarState`
// through Observation.

import AppKit
import Observation
import os
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let controller: AudioEngineController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    /// Global monitor for clicks in other apps; set only while the popover
    /// is shown.
    private var outsideClickMonitor: Any?
    /// Local monitor for clicks in our own windows and for Esc; set only
    /// while the popover is shown.
    private var localEventMonitor: Any?
    /// True while a file chooser opened from the panel is up: the popover
    /// must stay open meanwhile.
    private var isChoosingFile = false

    /// Why the popover is being closed (for the log).
    private enum CloseReason: String {
        case iconClick = "icon click"
        case clickInOtherApp = "click in another app"
        case clickInOwnWindow = "click in another window of the app"
        case escape = "Esc"
        case appResignedActive = "app no longer active"
    }

    init(controller: AudioEngineController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let panel = MenuPanelView(controller: controller)
            .environment(\.fileChooser, FileChooser { [weak self] panel, completion in
                self?.runFileChooser(panel, completion: completion)
            })
        let host = NSHostingController(rootView: panel)
        // The popover takes the content's ideal size, and follows it.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        // Every close is ours (see the header).
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Default sending (on mouse-up) kept on purpose: with
            // `.applicationDefined` nothing else looks at the mouse-down, so
            // there is no race to avoid, and the button's own press highlight
            // stays consistent with `highlight(true)` below.
        }
        observeIcon()

        // Activation can arrive after `showPopover` returned: the popover
        // window is made key at that moment.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification, object: nil)
    }

    // MARK: Icon

    /// Shows the icon for the current state, then re-registers itself for
    /// the next change (Observation reports one change per registration).
    private func observeIcon() {
        withObservationTracking {
            updateIcon()
        } onChange: { [weak self] in
            // Called before the change is stored, possibly off the main
            // thread: read the new state on the main actor, afterwards.
            Task { @MainActor in self?.observeIcon() }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let state = controller.menuBarState
        button.image = MenuBarIcons.image(for: state)
        button.setAccessibilityLabel(MenuBarIcons.accessibilityLabel(for: state))
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        let shown = popover.isShown
        let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "none"
        Log.panel.debug(
            "Icon clicked: popover shown before = \(shown, privacy: .public), event = \(eventType, privacy: .public)")
        if shown {
            closePopover(reason: .iconClick)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        refreshBeforeShowing()
        activateApp()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Keyboard to the panel (the popover window may not take it alone).
        popoverWindow?.makeKey()
        // Icon highlighted while the panel is open, like a menu.
        button.highlight(true)
        installMonitors()
        Log.panel.debug("Popover opened")
        // Activation is asynchronous: check again on the next run loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.makePopoverKey()
        }
    }

    private func closePopover(reason: CloseReason) {
        guard popover.isShown else { return }
        Log.panel.debug("Closing popover: \(reason.rawValue, privacy: .public)")
        popover.close()
        // popoverDidClose does it too; repeated here in case close() is not
        // followed by the delegate call (tearDown is idempotent).
        tearDownAfterClose()
    }

    private var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    /// Makes the popover window key if it is shown and is not yet.
    private func makePopoverKey() {
        guard popover.isShown, let window = popoverWindow, !window.isKeyWindow else { return }
        window.makeKey()
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        makePopoverKey()
    }

    /// Cmd-Tab or another app taking the focus without a click: what
    /// `.transient` did by itself. Not while a file chooser is up.
    @objc private func appDidResignActive(_ notification: Notification) {
        guard popover.isShown, !isChoosingFile else { return }
        closePopover(reason: .appResignedActive)
    }

    /// Things that can change outside the app while the panel is closed.
    /// Done before showing, so the popover opens already at its final size.
    private func refreshBeforeShowing() {
        controller.refreshLaunchAtLoginStatus()
        controller.refreshCandidateApps()
    }

    func popoverDidClose(_ notification: Notification) {
        Log.panel.debug("Popover did close")
        tearDownAfterClose()
    }

    private func tearDownAfterClose() {
        statusItem.button?.highlight(false)
        removeMonitors()
    }

    // MARK: Monitors

    private func installMonitors() {
        if outsideClickMonitor == nil {
            // Copies of the mouse events sent to other apps (mouse events
            // need no accessibility permission). Clicks in our own windows
            // (the icon, the panel, a file chooser) are not delivered here.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                // Hop to the main actor explicitly instead of assuming the
                // handler's thread.
                Task { @MainActor in self?.clickedInOtherApp() }
            }
        }
        if localEventMonitor == nil {
            // Events of our own app, before they are dispatched. Not called
            // for events consumed by nested tracking loops (menu tracking of
            // a pop-up menu, control tracking), so Picker menus are not seen.
            localEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                // Local monitors run on the main thread, with the event
                // being dispatched: it does not leave this thread.
                nonisolated(unsafe) let event = event
                let swallow = MainActor.assumeIsolated {
                    self?.shouldSwallowLocalEvent(event) ?? false
                }
                return swallow ? nil : event
            }
        }
    }

    private func removeMonitors() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    private func clickedInOtherApp() {
        // A file chooser may live partly in another process: its clicks must
        // not close the popover.
        guard popover.isShown, !isChoosingFile else { return }
        closePopover(reason: .clickInOtherApp)
    }

    /// Handles an event of our own app; true to swallow it, false to let it
    /// be dispatched as usual.
    private func shouldSwallowLocalEvent(_ event: NSEvent) -> Bool {
        guard popover.isShown, !isChoosingFile else { return false }
        if event.type == .keyDown {
            return handleKeyDown(event)
        }
        // Mouse down in one of our windows.
        guard let window = event.window else { return false }
        if isPanelWindow(window) { return false }
        // The icon: the button's action (togglePopover) decides.
        if window === statusItem.button?.window { return false }
        // Menus and other system windows of our process (pop-up menus are
        // at this level or above): never a reason to close.
        if window.level >= .popUpMenu { return false }
        closePopover(reason: .clickInOwnWindow)
        return false
    }

    /// Esc closes the popover only if nothing in the panel wants it: a text
    /// field being edited gets it as usual, and a button with the cancel
    /// shortcut ("Annulla" of an inline confirmation) gets it through the
    /// window's key equivalents. True if the event was consumed here.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let escapeKeyCode: UInt16 = 53
        guard event.keyCode == escapeKeyCode,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
              let window = popoverWindow, event.window === window
        else { return false }
        if window.firstResponder is NSText { return false }
        if window.performKeyEquivalent(with: event) { return true }
        closePopover(reason: .escape)
        return true
    }

    /// The popover window, or a window attached to it (child, sheet).
    private func isPanelWindow(_ window: NSWindow) -> Bool {
        guard let panelWindow = popoverWindow else { return false }
        var current: NSWindow? = window
        while let candidate = current {
            if candidate === panelWindow { return true }
            current = candidate.parent ?? candidate.sheetParent
        }
        return false
    }

    // MARK: File choosers

    /// Runs a file chooser without blocking (`begin`, not `runModal`). While
    /// it is up (`isChoosingFile`) every monitor and the resign-active
    /// handler leave the popover open; afterwards the popover gets the
    /// keyboard back if still open.
    private func runFileChooser(_ panel: NSOpenPanel, completion: @escaping @MainActor (URL?) -> Void) {
        isChoosingFile = true
        // A menu-bar-only app is not active by itself: without this the
        // chooser could open behind other apps' windows.
        activateApp()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                if let self {
                    self.isChoosingFile = false
                    if self.popover.isShown {
                        self.popoverWindow?.makeKey()
                    }
                }
                completion(response == .OK ? panel.url : nil)
            }
        }
    }
}

/// Opens an NSOpenPanel for a view of the menu bar panel; the completion gets
/// the chosen file, nil when cancelled. Set by `StatusItemController`, which
/// keeps the popover open meanwhile; the default just opens the chooser.
struct FileChooser: Sendable {
    private let run: @MainActor @Sendable (NSOpenPanel, @escaping @MainActor (URL?) -> Void) -> Void

    init(_ run: @escaping @MainActor @Sendable (NSOpenPanel, @escaping @MainActor (URL?) -> Void) -> Void) {
        self.run = run
    }

    @MainActor
    func callAsFunction(_ panel: NSOpenPanel, completion: @escaping @MainActor (URL?) -> Void) {
        run(panel, completion)
    }

    static let standalone = FileChooser { panel, completion in
        activateApp()
        panel.begin { response in
            MainActor.assumeIsolated { completion(response == .OK ? panel.url : nil) }
        }
    }
}

extension EnvironmentValues {
    @Entry var fileChooser: FileChooser = .standalone
}

// MARK: Activation

/// Activates the app even if another app is frontmost.
///
/// `NSApp.activate()` (macOS 14+) is cooperative: Apple's documentation says
/// it "doesn't guarantee app activation". A menu-bar-only app opened from its
/// icon is then often left inactive, its popover window not key: the first
/// click in the panel only made the window key (a pop-up menu needed two
/// clicks) and `.transient` missed clicks in other apps. The deprecated
/// `activate(ignoringOtherApps: true)` still exists and, per the
/// documentation, with `true` "the app activates regardless". It is called
/// through `ForcedActivation` so the deprecation warning is not repeated at
/// every call site. To revisit if Apple removes it.
@MainActor
func activateApp() {
    (NSApp as ForcedActivation).activate(ignoringOtherApps: true)
}

/// Exposes NSApplication's deprecated `activate(ignoringOtherApps:)` without
/// a deprecation warning at the call site (see `activateApp()`).
@MainActor
private protocol ForcedActivation {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: ForcedActivation {}
