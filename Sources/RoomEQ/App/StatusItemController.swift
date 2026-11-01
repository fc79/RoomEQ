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
//  - a click anywhere else closes it: in our own app through `.transient`,
//    in other apps (windows, desktop, other menu bar icons) through a global
//    mouse monitor installed while the popover is open, which works even if
//    the app did not become active (`.transient` alone would then miss those
//    clicks);
//  - just before opening, what may have changed outside the app is refreshed
//    (login item status, candidate apps to exclude);
//  - while a file chooser opened from the panel is up, the popover stays
//    open (see `runFileChooser`), so what the chooser leads to (an inline
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
    /// True while a file chooser opened from the panel is up: the popover
    /// must stay open meanwhile.
    private var isChoosingFile = false

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
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        observeIcon()

        // Activation can arrive after `showPopover` returned: the popover
        // window is made key at that moment.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil)
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
        if popover.isShown {
            closePopover()
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
        installOutsideClickMonitor()
        // Activation is asynchronous: check again on the next run loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.makePopoverKey()
        }
    }

    private func closePopover() {
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

    /// Things that can change outside the app while the panel is closed.
    /// Done before showing, so the popover opens already at its final size.
    private func refreshBeforeShowing() {
        controller.refreshLaunchAtLoginStatus()
        controller.refreshCandidateApps()
    }

    /// A click on the icon is handled by `togglePopover`: if the transient
    /// behaviour closed the popover on that same click, the click would then
    /// reopen it at once.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              let buttonWindow = statusItem.button?.window
        else { return true }
        return event.window !== buttonWindow
    }

    func popoverDidClose(_ notification: Notification) {
        tearDownAfterClose()
    }

    private func tearDownAfterClose() {
        statusItem.button?.highlight(false)
        removeOutsideClickMonitor()
    }

    // MARK: Clicks in other apps

    /// `.transient` only sees clicks that reach this app, or the app losing
    /// active status; if the app never became active, a click in another app
    /// would leave the popover open. A global monitor receives copies of the
    /// mouse events sent to other apps (mouse events need no accessibility
    /// permission). Clicks in our own windows (the icon, the panel, a file
    /// chooser) are not delivered to it.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Hop to the main actor explicitly instead of assuming the
            // handler's thread.
            Task { @MainActor in self?.clickedInOtherApp() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func clickedInOtherApp() {
        // A file chooser may live partly in another process: its clicks must
        // not close the popover.
        guard popover.isShown, !isChoosingFile else { return }
        closePopover()
    }

    // MARK: File choosers

    /// Runs a file chooser without blocking (`begin`, not `runModal`). A
    /// transient popover closes when another window is used (the chooser
    /// too): it is made application-defined meanwhile, transient again
    /// afterwards, and gets the keyboard back if still open. The global
    /// click monitor is ignored meanwhile too (`isChoosingFile`).
    private func runFileChooser(_ panel: NSOpenPanel, completion: @escaping @MainActor (URL?) -> Void) {
        popover.behavior = .applicationDefined
        isChoosingFile = true
        // A menu-bar-only app is not active by itself: without this the
        // chooser could open behind other apps' windows.
        activateApp()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                if let self {
                    self.isChoosingFile = false
                    self.popover.behavior = .transient
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
