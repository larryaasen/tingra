//
//  TingraApp.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The Tingra app entry point (phase 3, scaffolded at roadmap step 6).
///
/// It owns the ``EngineModel`` — the one `@Observable` that boots the host,
/// activates the capture and generator plug-ins, and drives the compositor —
/// and hands it to the main window. The engine starts once the window
/// appears; production controls (presets, shots, the mixer) hang off this
/// same model as they land.
@main
struct TingraApp: App {
    /// The engine model, owned for the app's lifetime.
    @State private var model = EngineModel()

    /// The app's appearance, owned for the app's lifetime and installed on
    /// the application the moment it is created — before the first window is
    /// drawn, so an operator on Dark never sees a light window correct itself
    /// (see ``AppearanceModel``).
    @State private var appearance = AppearanceModel()

    /// Whether the windows carry a status bar, owned for the app's lifetime
    /// so the General settings pane's checkbox reaches every window at once
    /// (see ``StatusBarModel``).
    @State private var statusBar = StatusBarModel()

    /// Whether the main window's sidebar is showing — the split view's own
    /// state, held here so the View menu's Show/Hide Sidebar item can read and
    /// write it (see ``SidebarVisibilityCommands``).
    ///
    /// It starts at `.all` rather than `.automatic` for one reason: the menu
    /// item's title has to say *show* or *hide*, and `.automatic` is neither —
    /// it is "let the system decide", which the item cannot print.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    /// The delegate that holds quitting open until a recording in flight is
    /// finalized (see ``TingraAppDelegate``).
    @NSApplicationDelegateAdaptor(TingraAppDelegate.self) private var appDelegate

    /// The identifier the View menu's Multiview command opens.
    static let multiviewWindowID = "multiview"

    /// The identifier the app menu's Settings… command opens.
    static let settingsWindowID = "settings"

    /// The scenes: the main production window, the multiview monitoring
    /// window it can open, and the settings window (``SettingsView``).
    ///
    /// The main window is a two-column `NavigationSplitView`: the shot and
    /// device sidebar on the leading edge (``SidebarView``) beside the
    /// production surfaces (``ContentView``). A standard split view rather
    /// than a hand-built column, because the standard sidebar is what carries
    /// the system's own material — Liquid Glass on macOS 26 — its collapse and
    /// resize behavior, and its toolbar toggle, none of which an app should
    /// reimplement (see ``SidebarView``). The detail column keeps the minimum
    /// size the production surfaces need, so the sidebar's own minimum widens
    /// the window rather than squeezing them.
    ///
    /// The **status bar** rides on the detail column rather than under the
    /// whole split view, which is where every macOS window that has both puts
    /// it: a sidebar's material runs the full height of the window, so a bar
    /// drawn across the bottom of it would cut the one surface the system draws
    /// for us (see ``SidebarView``). A bottom safe-area inset rather than a
    /// row in the stack, so it stays put while the production surfaces scroll
    /// (``StatusBarView``).
    var body: some Scene {
        WindowGroup {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                SidebarView(model: model)
            } detail: {
                ContentView(model: model)
                    .frame(minWidth: 640, minHeight: 480)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        StatusBarView(model: model, statusBar: statusBar)
                    }
            }
            .task {
                appDelegate.model = model
                await model.start()
            }
        }
        .commands {
            SidebarVisibilityCommands(model: model, visibility: $sidebarVisibility)
            MultiviewCommands(model: model)
            StatusBarCommands(model: model, statusBar: statusBar)
            SettingsCommands(model: model)
        }

        // Multiview is a **separate window**, not a panel: the main window
        // already carries both monitors, both switcher rows, the layer
        // editor, the mixer, and the destination list, and a tile grid would
        // compete with the very surfaces it duplicates. A window also puts it
        // on a second display for free — and its closed state is what makes
        // multiview genuinely free, since nothing draws and nothing is read
        // while it is shut (ARCHITECTURE.md, "Multiview").
        Window(
            String(
                localized: "Multiview",
                comment: "Title of the multiview monitoring window, and its View-menu command"
            ),
            id: Self.multiviewWindowID
        ) {
            MultiviewView(model: model, statusBar: statusBar)
                .frame(minWidth: 640, minHeight: 400)
        }

        // Settings is a `Window` rather than the `Settings` scene, for one
        // reason that is visible the moment you look at the two side by side:
        // **a `Settings` scene does not run its sidebar under the title bar.**
        // Its split view starts below the title bar, so the source list draws
        // as a card floating in the content area, where every other sidebar on
        // this Mac — the main window's above, Xcode 26's settings window, the
        // Finder's — runs the full height of the window with the
        // close/minimize/zoom buttons sitting on it. A `Window` scene gets the
        // main window's treatment, which is exactly the treatment wanted here.
        //
        // `SettingsCommands` puts Settings… back where macOS reserves it,
        // under ⌘, in the app menu, so nothing an operator can see moved.
        Window(
            String(localized: "Settings", comment: "Title of the settings window"),
            id: Self.settingsWindowID
        ) {
            SettingsView(model: model, appearance: appearance, statusBar: statusBar)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Holds quitting open until a recording in flight has been finalized, and
/// turns off the window tabbing this app has no use for.
///
/// SwiftUI gives a scene no async hook that runs before the process exits, and
/// a recording that is not finalized is an **unplayable file** — the one piece
/// of the operator's work the app can actually destroy by quitting. AppKit's
/// `applicationShouldTerminate(_:)` is the sanctioned way to ask for that time:
/// answer `.terminateLater`, close the file, then let the quit proceed
/// (ARCHITECTURE.md, "Recording in the app").
///
/// A quit with nothing recording is unchanged — it terminates immediately.
final class TingraAppDelegate: NSObject, NSApplicationDelegate {
    /// The engine model, handed over once the main window's task runs.
    var model: EngineModel?

    /// Turns off automatic window tabbing, before any window exists.
    ///
    /// That single line is what removes **Show Tab Bar** and **Show All Tabs**
    /// from the View menu: AppKit contributes both to every app whose windows
    /// can be tabbed, and they are the only two items in Tingra's View menu
    /// that do nothing an operator wants. Tabbing production windows together
    /// is not a workflow this app has — the main window is one per show, and
    /// multiview's whole point is to sit on a *second display*, which is the
    /// opposite of being folded into a tab beside the window it monitors.
    ///
    /// It belongs in `applicationWillFinishLaunching` rather than
    /// `applicationDidFinishLaunching`: the setting is read as each window is
    /// created, and by "did" the first window already exists.
    ///
    /// - Parameter notification: The launch notification (unused).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Lets a quit through immediately unless a recording is open, in which
    /// case the file is finalized first.
    ///
    /// - Parameter sender: The application quitting.
    /// - Returns: `.terminateNow` when nothing is recording, `.terminateLater`
    ///   while the file is being closed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRecording else { return .terminateNow }
        Task {
            await model.finishRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The View-menu command that opens the multiview window.
///
/// Its own `Commands` type rather than an inline group so it can take
/// `openWindow` from the environment, and so the `tap` fires where the user
/// action is executed (EVENTS.md, "The `tap` convention") rather than in the
/// app's scene body.
struct MultiviewCommands: Commands {
    /// The engine model, for the command's `tap` event.
    let model: EngineModel

    /// Opens the multiview window.
    @Environment(\.openWindow) private var openWindow

    /// A single View-menu item, with the conventional secondary-window
    /// shortcut.
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button {
                model.eventBus.tap("multiview.menuItem", domain: .composition)
                openWindow(id: TingraApp.multiviewWindowID)
            } label: {
                Text("Multiview", comment: "Title of the multiview monitoring window, and its View-menu command")
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}

/// The View-menu command that shows or hides the **main window's** sidebar,
/// ⌃⌘S — the standard macOS item, in the standard place, with the standard key.
///
/// **Written rather than taken, after taking it was measured and rejected.**
/// SwiftUI ships `SidebarCommands()`, which is the obvious answer and was the
/// first one tried. Against this app it did two wrong things (verified
/// 2026-08-08 on a clean build): its ⌃⌘S collapsed the **settings** window's
/// source list — the one sidebar in the app that must never collapse, since it
/// is that window's only navigation — and once the settings window existed it
/// stopped reaching the main window at all, while its title stayed on "Show
/// Sidebar" with the sidebar plainly showing. A command that aims at the wrong
/// window and mislabels itself is worse than one written here, because both
/// failures are silent.
///
/// Driving ``TingraApp/sidebarVisibility`` directly fixes all of it: the item
/// can only ever mean the main window, the title is read from the same state
/// the split view draws from, and the toolbar's own toggle writes that state
/// too — so the button and the menu item cannot disagree.
///
/// The title flips, Show to Hide, for the reason ``StatusBarCommands`` records:
/// a menu item says what choosing it will *do*.
struct SidebarVisibilityCommands: Commands {
    /// The engine model, for the command's `tap` event.
    let model: EngineModel

    /// The main window's split-view column visibility.
    @Binding var visibility: NavigationSplitViewVisibility

    /// Whether the sidebar is on screen. Anything but `detailOnly` shows it —
    /// a two-column split view has more than one way to say "both columns",
    /// and only one way to say "just the detail".
    private var isShowing: Bool {
        visibility != .detailOnly
    }

    /// The one View-menu item, in the slot macOS reserves for it.
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button {
                model.eventBus.tap(
                    "sidebar.menuItem",
                    domain: .platform,
                    params: ["visible": .bool(!isShowing)]
                )
                visibility = isShowing ? .detailOnly : .all
            } label: {
                Label {
                    if isShowing {
                        Text("Hide Sidebar", comment: "View menu item that hides the main window's sidebar")
                    } else {
                        Text("Show Sidebar", comment: "View menu item that shows the main window's sidebar")
                    }
                } icon: {
                    Image(systemName: "sidebar.leading")
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}

/// The View-menu command that shows or hides the status bar.
///
/// **The title flips rather than carrying a checkmark** — Show Status Bar when
/// it is off, Hide Status Bar when it is on. That is the macOS convention for
/// this exact item (the Finder's and Safari's View menus both do it), and it
/// reads as an instruction the way a menu item should: the item says what
/// choosing it will do, not what is currently true. The General settings row is
/// a checkbox for the opposite reason — a settings row states the current
/// state.
///
/// It sits in the View menu at `CommandGroupPlacement.sidebar`, directly after
/// the Show/Hide Sidebar item (``SidebarVisibilityCommands``) — the Finder's
/// arrangement — and takes **⌘/**, the Finder's and Safari's
/// assignment for the status bar and free in Tingra. The key comes from
/// ``ProductionShortcut/toggleStatusBar`` rather than being spelled here, so
/// the Shortcuts settings pane cannot print a shortcut this item does not bind.
///
/// **The dividers are not decoration.** They put the item in a section of its
/// own, which is both the Finder's layout and the only way it lines up: an
/// AppKit menu section indents every item past an icon column as soon as *one*
/// item in it has an icon, and the neighbours on both sides have one (Hide
/// Sidebar above, Enter Full Screen below). Merging it into Multiview's section
/// instead was tried and is worse — that indents both.
///
/// It drives the same ``StatusBarModel`` the settings checkbox writes, so the
/// two can never disagree and either one persists the choice.
struct StatusBarCommands: Commands {
    /// The engine model, for the command's `tap` event.
    let model: EngineModel

    /// Whether the status bar is shown.
    let statusBar: StatusBarModel

    /// The one View-menu item, in a section of its own (see the type's note on
    /// placement).
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button {
                model.eventBus.tap(
                    "statusBar.menuItem",
                    domain: .platform,
                    params: ["visible": .bool(!statusBar.isVisible)]
                )
                statusBar.isVisible.toggle()
            } label: {
                if statusBar.isVisible {
                    Text("Hide Status Bar", comment: "View menu item that hides the window status bar")
                } else {
                    Text("Show Status Bar", comment: "View menu item that shows the window status bar")
                }
            }
            .keyboardShortcut(ProductionShortcut.toggleStatusBar.shortcut)

            Divider()
        }
    }
}

/// The app-menu command that opens the settings window.
///
/// `CommandGroup(replacing: .appSettings)` puts it in the slot macOS reserves
/// for Settings…, under ⌘, — the item the `Settings` scene would have
/// contributed on its own. Replacing it rather than adding one is what keeps
/// the app menu from carrying two, now that settings live in a `Window` scene
/// (see ``TingraApp/body``).
struct SettingsCommands: Commands {
    /// The engine model, for the command's `tap` event.
    let model: EngineModel

    /// Opens the settings window.
    @Environment(\.openWindow) private var openWindow

    /// The one app-menu item, keeping the system's own shortcut.
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                model.eventBus.tap("settings.menuItem", domain: .platform)
                openWindow(id: TingraApp.settingsWindowID)
            } label: {
                Text("Settings…", comment: "App menu item that opens the settings window")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
