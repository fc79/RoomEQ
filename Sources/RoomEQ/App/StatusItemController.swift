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
//  - a click on the icon opens the popover, a second click closes it; a
//    click anywhere else closes it too (.transient);
//  - opening activates the app, so the popover gets the keyboard (preset name
//    fields, Cmd-Q for "Esci");
//  - just before opening, what may have changed outside the app is refreshed
//    (login item status, candidate apps to exclude);
//  - while a file chooser opened from the panel is up, the popover stays
//    open (see `FileChooser`), so what the chooser leads to (an inline
//    confirmation, an error note) is seen right away.
// The icon and its accessibility label follow `controller.menuBarState`
// through Observation.

import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let controller: AudioEngineController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

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
            popover.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        refreshBeforeShowing()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Keyboard to the panel (the popover window may not take it alone).
        popover.contentViewController?.view.window?.makeKey()
        // Icon highlighted while the panel is open, like a menu.
        button.highlight(true)
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
        statusItem.button?.highlight(false)
    }

    // MARK: File choosers

    /// Runs a file chooser without blocking (`begin`, not `runModal`). A
    /// transient popover closes when another window is used (the chooser
    /// too): it is made application-defined meanwhile, transient again
    /// afterwards, and gets the keyboard back if still open.
    private func runFileChooser(_ panel: NSOpenPanel, completion: @escaping @MainActor (URL?) -> Void) {
        popover.behavior = .applicationDefined
        // A menu-bar-only app is not active by itself: without this the
        // chooser could open behind other apps' windows.
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                if let self {
                    self.popover.behavior = .transient
                    if self.popover.isShown {
                        self.popover.contentViewController?.view.window?.makeKey()
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
        NSApp.activate()
        panel.begin { response in
            MainActor.assumeIsolated { completion(response == .OK ? panel.url : nil) }
        }
    }
}

extension EnvironmentValues {
    @Entry var fileChooser: FileChooser = .standalone
}
