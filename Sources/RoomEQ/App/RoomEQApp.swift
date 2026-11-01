// App entry point: a menu-bar-only app (LSUIElement in Info.plist).
//
// The menu bar icon and its panel are AppKit (NSStatusItem + NSPopover, see
// StatusItemController.swift), created by AppDelegate. The panel content is
// `MenuPanelView` (MenuPanelView.swift), made of one view per block
// (PresetRowView, MetersViews, FiltersSectionView, OutputSectionView,
// OutputRulesView, ExclusionsView, StartupSectionView); shared pieces are in
// PanelComponents.swift.
//
// Language: the texts follow the macOS language (also the per-app choice in
// System Settings › General › Language & Region): Italian (it.lproj, the
// development texts) or English (en.lproj); any other language falls back to
// English (CFBundleDevelopmentRegion "en" in Info.plist). Numbers follow the
// user's locale (`TextLocale`, set by AppDelegate before anything is formatted).

import SwiftUI

@main
struct RoomEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // A SwiftUI app needs at least one scene: an empty Settings scene shows
    // no window by itself. Its "Settings…" command (Cmd-,) is removed, so it
    // cannot open an empty window while the panel has the keyboard.
    var body: some Scene {
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}
