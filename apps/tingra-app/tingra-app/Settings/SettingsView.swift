//
//  SettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// One pane of the settings window.
///
/// A closed list rather than three hand-written tabs, so the sidebar's label
/// and the title bar's heading are drawn from **one** name per pane and cannot
/// drift apart — the rule ``SidebarSection`` follows for the main window's
/// sidebar. A pane added without an entry here does not compile.
enum SettingsPane: String, CaseIterable, Hashable, Sendable {
    /// The app's appearance.
    case general

    /// The production keyboard shortcuts.
    case shortcuts

    /// The app's version.
    case about

    /// The pane's user-facing name, shown in the sidebar and as the window's
    /// heading.
    var name: Text {
        switch self {
        case .general: Text("General", comment: "Settings window pane: general app settings")
        case .shortcuts: Text("Shortcuts", comment: "Settings window pane: the keyboard shortcuts listing")
        case .about: Text("About", comment: "Settings window pane: the app's version")
        }
    }

    /// The SF Symbol beside that name in the sidebar.
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .about: "info.circle"
        }
    }
}

/// The settings window, reached from the app menu with ⌘, the way macOS
/// reserves — three panes for now, General, Shortcuts, and About.
///
/// It is a `Window` scene with its own Settings… command (``TingraApp``)
/// rather than SwiftUI's `Settings` scene, for a reason that is only visible
/// with the two side by side: a `Settings` scene starts its content **below**
/// the title bar, so the source list draws as a card floating in the content
/// area, where every other sidebar on the Mac — the main window's, Xcode 26's
/// settings window, the Finder's — runs the full height of the window with
/// the close/minimize/zoom buttons sitting on it.
///
/// A `NavigationSplitView` with a source list rather than the older toolbar
/// tabs, because that is the shape macOS itself settled on: System Settings
/// and Xcode 26 both list their panes in a source list beside the pane's
/// content, and a settings window that still wore a row of toolbar icons
/// would read as an older app. The style also stays honest as panes are
/// added — a fourth and fifth pane extend a list, where they crowd a toolbar.
///
/// A split view rather than a `.sidebarAdaptable` `TabView`, which is the
/// other way to draw this: the split view is what makes the pane's own
/// toolbar reachable, and the toolbar is where both the title and the removed
/// collapse button live.
///
/// It takes the ``EngineModel`` for one reason only: the event bus, so a
/// setting the operator changes is reported as a `tap` like every other
/// control in the app (EVENTS.md, "The `tap` convention"). No pane reads or
/// writes the show.
struct SettingsView: View {
    /// The engine model — here for its event bus, not for the show.
    let model: EngineModel

    /// The app's appearance, edited by the General pane.
    @Bindable var appearance: AppearanceModel

    /// Closes the settings window — what Escape does (see ``body``).
    @Environment(\.dismiss) private var dismiss

    /// The pane on screen. View-local session state: which pane an operator
    /// last had open is not worth persisting, and a settings window that
    /// opens on General every time is what every Mac app does.
    @State private var pane: SettingsPane = .general

    /// The smallest the **detail column** may be: wide enough for a grouped
    /// form, tall enough for the Shortcuts pane's six rows without a scroll on
    /// a fresh install.
    ///
    /// It sits on the detail rather than on the split view, matching the main
    /// window — and that placement is load-bearing rather than stylistic. A
    /// frame around the whole split view stops the sidebar reaching the title
    /// bar, so the source list draws as a card floating below the
    /// close/minimize/zoom buttons instead of running the full height of the
    /// window with those buttons sitting on it.
    private static let minimumSize = CGSize(width: 700, height: 460)

    /// The three panes, with the open one's name as the window's title.
    ///
    /// **The title lands on the leading edge, not centered**, which is Xcode
    /// 26's settings window and what the pane name wants — a heading sits over
    /// the content it heads. That placement comes from the window's own
    /// unified title bar beside a split view rather than from anything
    /// arranged here; all this does is give the window a title worth reading,
    /// the open pane rather than the app's name repeated.
    ///
    /// **The sidebar's collapse button is deliberately removed.** A settings
    /// window's sidebar *is* its navigation — collapsing it leaves a pane the
    /// operator cannot get out of — so the control it offers is a trap rather
    /// than a convenience. That is why System Settings and Xcode do not show
    /// one either.
    ///
    /// **Escape closes the window**, beside the ⌘W every window already has.
    /// That is the settings-window convention on macOS — System Settings and
    /// Xcode both dismiss on Escape — and it reads correctly here for the
    /// reason it does there: nothing in this window is *committed*, so there
    /// is no edit for Escape to ambiguously cancel. Every pane writes as the
    /// operator acts, which makes Escape mean "I'm done looking" rather than
    /// "undo what I just did".
    ///
    /// `onExitCommand` is the whole of it — no hidden `.cancelAction` button
    /// standing in for the key, which is the other way this is often done and
    /// would have left a phantom control in the hierarchy to carry a key
    /// equivalent. The exit command reaches the split view from wherever
    /// focus sits, including the sidebar (verified 2026-08-08 against a clean
    /// build: Escape closes the window with the handler alone).
    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, id: \.self, selection: paneSelection) { pane in
                Label {
                    pane.name
                } icon: {
                    Image(systemName: pane.systemImage)
                }
                .tag(pane)
            }
            // The source-list style, the same one ``SidebarView`` uses. It is
            // what makes the column run the **full height of the window** —
            // up behind the close/minimize/zoom buttons, the way Xcode's
            // settings sidebar does — rather than sitting in the content area
            // as an inset card below the title bar, which is what a plain
            // `List` draws here.
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                // The window still needs a toolbar even though it shows no
                // toolbar control, and this empty item is what keeps one: a
                // window with no toolbar at all gets a plain short title bar,
                // and the split view starts *below* it, which is what leaves
                // the source list floating as a card under the
                // close/minimize/zoom buttons. With a toolbar the title bar is
                // the taller unified kind that the sidebar runs up through, so
                // the column reaches the top of the window with the buttons
                // sitting on it — the main window's look, and Xcode's.
                ToolbarItem(placement: .navigation) {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        } detail: {
            content(for: pane)
                .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        }
        .onExitCommand {
            model.eventBus.tap("settingsClose.escape", domain: .platform)
            dismiss()
        }
    }

    /// The pane binding, reporting its own `tap` before the switch lands —
    /// the `Binding.reportingTap` rule, so restoring General at launch
    /// records no tap nobody made.
    private var paneSelection: Binding<SettingsPane> {
        $pane.reportingTap(
            to: model.eventBus,
            "settingsPane.tab",
            domain: .platform,
            params: { ["pane": .string($0.rawValue)] }
        )
    }

    /// One pane's content, carrying the window chrome the pane names.
    ///
    /// The chrome modifiers live **here, on the detail column**, rather than
    /// on the split view: `navigationTitle` names the window from whichever
    /// pane is open, which is only a decision the detail can make.
    ///
    /// - Parameter pane: The pane to draw.
    /// - Returns: Its view.
    private func content(for pane: SettingsPane) -> some View {
        paneBody(for: pane)
            .navigationTitle(pane.name)
    }

    /// One pane's own view, without chrome.
    ///
    /// - Parameter pane: The pane to draw.
    /// - Returns: Its view.
    @ViewBuilder private func paneBody(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsView(model: model, appearance: appearance)
        case .shortcuts: ShortcutsSettingsView()
        case .about: AboutSettingsView()
        }
    }
}
