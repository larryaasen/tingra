//
//  SettingsView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// One pane of the settings window.
///
/// A closed list, so the source list's label and the title bar's heading are
/// drawn from **one** name per pane and cannot drift apart — the main Tingra
/// app's `SettingsPane` rule.
enum SettingsPane: String, CaseIterable, Hashable, Sendable {
    /// The app's appearance and whether the windows carry a status bar.
    case general

    /// Where the camera permission stands.
    case permissions

    /// The app's version and how long it has been running.
    case about

    /// The pane's user-facing name, shown in the source list and as the
    /// window's heading.
    var name: Text {
        switch self {
        case .general: Text("General", comment: "Settings window pane: general app settings")
        case .permissions: Text("Permissions", comment: "Settings window pane: the system permissions' status")
        case .about: Text("About", comment: "Settings window pane: the app's version")
        }
    }

    /// The SF Symbol beside that name in the source list.
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

/// The settings window, reached from the app menu with ⌘, — three panes:
/// General, Permissions, and About, the main Tingra app's settings window
/// cut to what this app has.
///
/// It is a `Window` scene with its own Settings… command
/// (``SettingsCommands``) rather than SwiftUI's `Settings` scene, for the
/// main app's reason: a `Settings` scene starts its content below the title
/// bar, so the source list draws as a card floating in the content area,
/// where every other sidebar on the Mac runs the full height of the window
/// with the close/minimize/zoom buttons sitting on it.
///
/// A `NavigationSplitView` with a source list, the shape System Settings and
/// Xcode settled on. The sidebar cannot collapse — it is the window's only
/// navigation — so its toggle is removed and its visibility is a constant.
/// Escape closes the window, the settings-window convention on macOS: every
/// pane writes as the operator acts, so there is no edit for it to cancel.
struct SettingsView: View {
    /// The shared hardware model — for its event bus (every control reports a
    /// `tap`) and its permissions.
    @Environment(HardwareModel.self) private var model

    /// The app's appearance, edited by the General pane.
    @Bindable var appearance: AppearanceModel

    /// Whether the windows carry a status bar, edited by the General pane.
    @Bindable var statusBar: StatusBarModel

    /// How long the app has been running, shown by the About pane.
    let uptime: AppUptime

    /// Closes the settings window — what Escape does.
    @Environment(\.dismiss) private var dismiss

    /// The pane on screen. View-local: a settings window that opens on
    /// General every time is what every Mac app does.
    @State private var selection: SettingsPane = .general

    /// The smallest the detail column may be, wide enough for a grouped form.
    /// On the detail rather than the split view, so the sidebar still reaches
    /// the title bar.
    private static let minimumSize = CGSize(width: 560, height: 360)

    /// The panes, with the open one's name as the window's title.
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: paneSelection) {
                ForEach(SettingsPane.allCases, id: \.self) { pane in
                    Label {
                        pane.name
                    } icon: {
                        Image(systemName: pane.systemImage)
                    }
                    .tag(pane)
                }
            }
            // The source-list style runs the column the full height of the
            // window, up behind the close/minimize/zoom buttons.
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                // An empty item keeps the window's unified toolbar title bar,
                // which the sidebar runs up through; with no toolbar at all
                // the split view starts below a short title bar.
                ToolbarItem(placement: .navigation) {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        } detail: {
            paneBody(for: selection)
                .navigationTitle(selection.name)
                .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        }
        .onExitCommand {
            model.recordTap("settingsClose.escape")
            dismiss()
        }
    }

    /// The pane binding, reporting its own `tap` before the switch lands — a
    /// setter runs only when the operator picks a pane, so opening on General
    /// records no tap nobody made.
    private var paneSelection: Binding<SettingsPane?> {
        Binding {
            selection
        } set: { pane in
            guard let pane else { return }
            model.recordTap("settingsPane.tab", params: ["pane": .string(pane.rawValue)])
            selection = pane
        }
    }

    /// One pane's own view.
    ///
    /// - Parameter pane: The pane to draw.
    /// - Returns: Its view.
    @ViewBuilder private func paneBody(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsView(appearance: appearance, statusBar: statusBar)
        case .permissions: PermissionsSettingsView()
        case .about: AboutSettingsView(uptime: uptime)
        }
    }
}

/// The app-menu command that opens the settings window.
///
/// `CommandGroup(replacing: .appSettings)` puts it in the slot macOS reserves
/// for Settings…, under ⌘, — the item the `Settings` scene would have
/// contributed on its own, now that settings live in a `Window` scene.
struct SettingsCommands: Commands {
    /// The shared hardware model, for the command's `tap` event.
    let model: HardwareModel

    /// Opens the settings window.
    @Environment(\.openWindow) private var openWindow

    /// The one app-menu item, keeping the system's own shortcut.
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                model.recordTap("settings.menuItem")
                openWindow(id: TingraCamerasApp.settingsWindowID)
            } label: {
                Text("Settings…", comment: "App menu item that opens the settings window")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
