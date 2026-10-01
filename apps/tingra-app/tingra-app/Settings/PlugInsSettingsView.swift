//
//  PlugInsSettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-30.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import ExtensionKit
import SwiftUI
import TingraAppPlugInKit
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// The Plug-ins settings pane: every plug-in Tingra knows, both tiers, one
/// row per plug-in (PLUGINS.md, Decision 36).
///
/// **Installed** lists the bundles from both plug-in folders and the
/// app-tier plug-ins shipped in other apps. A bundle's row carries Tingra's
/// toggle, which writes `plug-ins.json` for the next launch — never this
/// one, since loading or unloading a bundle's code mid-show is exactly what
/// the loader refuses to do (Decision 27) — and a refused bundle carries its
/// refusal and Show in Finder instead. Under the rows is the app tier's own
/// switch: the system's `EXAppExtensionBrowserViewController`, behind
/// Manage…, is the only switch for an app-tier half, because two switches
/// for one thing is worse than one.
///
/// **Built In** lists the compiled-in plug-ins and the extensions embedded in
/// Tingra.app, with no toggles.
///
/// There is deliberately no Relaunch button: relaunching quits a live show.
/// The footer's Shift hint is how the operator learns safe mode's key.
struct PlugInsSettingsView: View {
    /// The engine model — for its event bus (every control reports a `tap`),
    /// the launch's plug-in report, safe mode, and the enablement model.
    let model: EngineModel

    /// The app-tier plug-in host: the extensions discovered and the system's
    /// counts of the ones that are off.
    @Environment(AppPlugInHost.self) private var plugInHost: AppPlugInHost?

    /// Whether the system's extension browser is showing.
    @State private var isManagePresented = false

    /// The user's plug-in folder, the first the loader scans and the one
    /// Open Plug-ins Folder opens.
    private static var userFolder: URL {
        PlugInBundleLoader.standardFolders[0]
    }

    /// The user's plug-in folder's path, home folder as `~`, as the CLI and
    /// the log name it.
    private static var userFolderDisplayPath: String {
        (userFolder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    /// The pane.
    var body: some View {
        let listing = PlugInListing(report: model.plugInReport, appTier: appTier)
        Form {
            if let trigger = model.safeModeTrigger {
                SafeModeBanner(trigger: trigger)
            }

            Section {
                if listing.installed.isEmpty {
                    Text(
                        "No plug-ins installed.",
                        comment: "Plug-ins settings: shown under Installed when there are none"
                    )
                    .foregroundStyle(.secondary)
                }
                ForEach(listing.installed) { row in
                    PlugInRow(model: model, row: row)
                }
                manageRow
            } header: {
                Text("Installed", comment: "Plug-ins settings: heading over the plug-ins the operator installed")
            } footer: {
                if let problem = model.plugInEnablement.problem {
                    Label {
                        Text(verbatim: problem)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .textSelection(.enabled)
                }
            }

            Section {
                ForEach(listing.builtIn) { row in
                    PlugInRow(model: model, row: row)
                }
            } header: {
                Text("Built In", comment: "Plug-ins settings: heading over the plug-ins that come with Tingra")
            }

            Section {
                folderRow
            } footer: {
                Text(
                    "Hold Shift while opening Tingra to open it without the plug-ins you installed.",
                    comment: "Plug-ins settings: footer teaching the safe-mode key")
            }
        }
        .formStyle(.grouped)
        .task {
            // Appearing is the moment the file is read: `tingra-cli plug-ins
            // enable|disable` may have changed it since the last look.
            model.plugInEnablement.refresh()
        }
        .sheet(isPresented: $isManagePresented) {
            ManagePlugInsSheet(model: model)
        }
    }

    /// The app-tier plug-ins the host discovered, as the listing needs them.
    private var appTier: [PlugInListing.AppTierPlugIn] {
        (plugInHost?.plugIns ?? []).map {
            PlugInListing.AppTierPlugIn(
                id: $0.id, name: $0.manifest.name, version: $0.version, isBuiltIn: $0.isBuiltIn)
        }
    }

    /// The app tier's own switch: the system's count of the plug-ins in
    /// other apps that are off, and Manage…, which presents the system's
    /// extension browser.
    private var manageRow: some View {
        LabeledContent {
            Button {
                model.eventBus.tap("plugInsManage.button", domain: .plugIn)
                isManagePresented = true
            } label: {
                Text(
                    "Manage…", comment: "Plug-ins settings: button presenting the system's switches for app extensions")
            }
        } label: {
            Text("Plug-ins in Other Apps", comment: "Plug-ins settings: label of the row managing app extensions")
            availabilityText
        }
    }

    /// How many plug-ins in other apps are off, as the system counts them.
    @ViewBuilder private var availabilityText: some View {
        let off = plugInHost?.availability?.off ?? 0
        if off > 0 {
            Text(
                "\(off) plug-ins in other apps are off",
                comment: "Plug-ins settings: how many app extensions are off; the placeholder is the count")
        } else {
            Text(
                "Turn their panes and commands on and off in Manage…",
                comment: "Plug-ins settings: shown under Plug-ins in Other Apps when none are off")
        }
    }

    /// The user's plug-in folder and the button opening it in the Finder.
    private var folderRow: some View {
        LabeledContent {
            Button {
                model.eventBus.tap("plugInsOpenFolder.button", domain: .plugIn)
                openUserFolder()
            } label: {
                Text("Open Plug-ins Folder", comment: "Plug-ins settings: button opening the plug-ins folder")
            }
        } label: {
            Text("Plug-ins Folder", comment: "Plug-ins settings: label of the row naming the plug-ins folder")
            Text(verbatim: Self.userFolderDisplayPath)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    /// Opens the user's plug-in folder in the Finder, creating it first:
    /// until the first plug-in is installed the folder does not exist, and
    /// it is where the operator puts one.
    private func openUserFolder() {
        do {
            try FileManager.default.createDirectory(at: Self.userFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Self.userFolder)
        } catch {
            model.eventBus.error(
                "plugin.folder", domain: .plugIn,
                params: [
                    "path": .string(Self.userFolderDisplayPath),
                    "error": .string(String(describing: error)),
                ])
        }
    }
}

/// The banner topping the Plug-ins pane in safe mode, saying why the
/// installed plug-ins did not load and that the next launch loads them.
struct SafeModeBanner: View {
    /// Why this launch is in safe mode.
    let trigger: PlugInSafeModeTrigger

    /// The banner.
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Safe Mode", comment: "Plug-ins settings: title of the safe-mode banner")
                        .font(.headline)
                    Text(explanation)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .font(.title2)
            }
        }
    }

    /// Why the plug-ins did not load, by trigger.
    private var explanation: LocalizedStringResource {
        switch trigger {
        case .afterUncleanExit:
            LocalizedStringResource(
                "You chose to open Tingra without the plug-ins you installed after it quit unexpectedly. They load again the next time Tingra opens.",
                comment: "Plug-ins settings: safe-mode banner text after the operator chose Open in Safe Mode")
        case .shiftKey, .flag:
            LocalizedStringResource(
                "Shift was held as Tingra opened, so the plug-ins you installed were not loaded. They load again the next time Tingra opens.",
                comment: "Plug-ins settings: safe-mode banner text after Shift was held at launch")
        }
    }
}

/// One plug-in's row: its name, version, and id on the leading edge, with
/// what became of it below; Tingra's toggle, or Show in Finder for a refused
/// bundle, on the trailing edge.
struct PlugInRow: View {
    /// The engine model — for its event bus and the enablement model.
    let model: EngineModel

    /// The row.
    let row: PlugInListing.Row

    /// The row.
    var body: some View {
        LabeledContent {
            trailing
        } label: {
            title
            if let plugInID = row.plugInID {
                Text(verbatim: plugInID.rawValue)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            details
        }
    }

    /// The name, the version beside it, and a warning symbol when the
    /// plug-in has a problem to read below.
    private var title: some View {
        HStack(spacing: 6) {
            if row.hasWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(
                        Text("Warning", comment: "Plug-ins settings: accessibility label of a row's warning symbol"))
            }
            Text(verbatim: row.name)
            if let version = row.version {
                Text(verbatim: version)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What became of the plug-in, one line per fact.
    @ViewBuilder private var details: some View {
        switch row.bundle {
        case .switchable(let wasOn):
            if let plugInID = row.plugInID {
                if model.plugInEnablement.isCrashed(plugInID) {
                    Text(
                        "Turned off because Tingra quit unexpectedly while loading it.",
                        comment: "Plug-ins settings: a bundle the load-crash guard turned off")
                }
                if !model.plugInEnablement.isUnreadable, model.plugInEnablement.isOn(plugInID) != wasOn {
                    Text(
                        "Takes effect the next time Tingra opens",
                        comment: "Plug-ins settings: a changed toggle applies at the next launch")
                }
            }
        case .refused(let message, _), .undetermined(let message):
            Text(verbatim: message)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
        if let activationError = row.activationError {
            Text(verbatim: activationError)
                .textSelection(.enabled)
        }
        ForEach(row.warnings, id: \.self) { warning in
            Text(verbatim: warning)
                .textSelection(.enabled)
        }
        if row.section == .installed, row.hasAppTierHalf {
            if row.bundle == nil {
                Text(
                    "Turned on and off in Manage…",
                    comment: "Plug-ins settings: an installed app extension, switched in the system's browser")
            } else {
                Text(
                    "Its panes and commands are turned on and off in Manage…",
                    comment:
                        "Plug-ins settings: a plug-in with both halves, whose app half the system's browser switches")
            }
        }
    }

    /// The trailing control: Tingra's toggle for a bundle it can switch,
    /// Show in Finder for a refused one, nothing otherwise.
    @ViewBuilder private var trailing: some View {
        switch row.bundle {
        case .switchable:
            if let plugInID = row.plugInID {
                Toggle(isOn: enabledBinding(for: plugInID)) {
                    Text(verbatim: row.name)
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.plugInEnablement.isUnreadable)
            }
        case .refused(_, let url):
            Button {
                var params: [String: EventValue] = [:]
                if let plugInID = row.plugInID { params["id"] = .string(plugInID.rawValue) }
                model.eventBus.tap("plugInShowInFinder.button", domain: .plugIn, params: params)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text("Show in Finder", comment: "Plug-ins settings: button revealing a refused plug-in bundle")
            }
        case .undetermined, nil:
            EmptyView()
        }
    }

    /// The toggle's binding, reading the enablement model and writing
    /// through it, its `tap` reported first — the setter runs only when the
    /// operator flips the switch.
    ///
    /// - Parameter plugInID: The plug-in the toggle switches.
    private func enabledBinding(for plugInID: PlugInID) -> Binding<Bool> {
        Binding {
            model.plugInEnablement.isOn(plugInID)
        } set: { isOn in
            model.eventBus.tap(
                "plugInEnabled.toggle", domain: .plugIn,
                params: ["id": .string(plugInID.rawValue), "enabled": .bool(isOn)])
            model.plugInEnablement.setOn(isOn, for: plugInID)
        }
    }
}

/// The sheet behind Manage…: the system's own switches for Tingra's app
/// extensions, with a Done button.
struct ManagePlugInsSheet: View {
    /// The engine model, for the Done button's `tap`.
    let model: EngineModel

    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// The sheet.
    var body: some View {
        VStack(spacing: 0) {
            AppExtensionBrowser()
                .frame(minWidth: 560, minHeight: 400)
            Divider()
            HStack {
                Spacer()
                Button {
                    model.eventBus.tap("plugInsManageDone.button", domain: .plugIn)
                    dismiss()
                } label: {
                    Text("Done", comment: "Plug-ins settings: button closing the Manage sheet")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }
}

/// The system's extension browser, `EXAppExtensionBrowserViewController`,
/// hosted in SwiftUI. It lists every extension for Tingra's extension point
/// and switches each on or off, out of process.
struct AppExtensionBrowser: NSViewControllerRepresentable {
    /// Creates the browser.
    func makeNSViewController(context: Context) -> EXAppExtensionBrowserViewController {
        EXAppExtensionBrowserViewController()
    }

    /// Nothing to update: the browser reads the system's own state.
    func updateNSViewController(_ controller: EXAppExtensionBrowserViewController, context: Context) {}
}
