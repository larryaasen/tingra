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
    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                SidebarView(model: model)
            } detail: {
                ContentView(model: model)
                    .frame(minWidth: 640, minHeight: 480)
            }
            .task {
                appDelegate.model = model
                await model.start()
            }
        }
        .commands {
            MultiviewCommands(model: model)
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
            MultiviewView(model: model)
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
            SettingsView(model: model, appearance: appearance)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Holds quitting open until a recording in flight has been finalized.
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
