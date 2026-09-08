//
//  DataSettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraEventBus

/// The Data settings pane: everything Tingra has saved on this Mac — what
/// each thing is, how much of it there is, and where — and the one action
/// that removes all of it and quits, so the next launch is a first run.
///
/// Built for the operator who wants to start over and for the developer
/// checking a first run by hand: both need to know exactly what "all data"
/// covers before removing it, so the pane lists every kind
/// (``AppDataKind``) with its count, its size on disk, and where it is — the
/// **folder** for the documents, the counter, and the recordings, clickable
/// to open in the Finder, since the folder is what an operator goes and
/// looks in — and the confirmation repeats the list with the counts of the
/// moment rather than a summary. Recordings are in the list and out of the
/// removal — the operator's shows, not the app's state about them — and the
/// pane says so on the row, in the confirmation, and in the footer. The rows
/// carry no description line (dropped 2026-09-07, Larry): the name says what
/// each thing is, and the confirmation is where the explaining happens.
///
/// **The removal quits the app.** The engine holds the show in memory, and
/// resetting every model in place would be a second copy of the app's boot
/// — the honest "state before the app was ever used" is a process that has
/// not launched yet. ``EngineModel/removeAllData()`` turns saving off before
/// the files go, so the quit's own flush cannot write the document back. A
/// kind that could not be removed keeps the app open instead, listed under
/// its own heading with the reason, so the operator sees what is still
/// there rather than reading it out of a log.
///
/// Permissions are not here: they are the Permissions pane's, where each row
/// has its own Reset (``PermissionRow``).
struct DataSettingsView: View {
    /// The engine model — for its event bus (every button reports a `tap`),
    /// its app-data model, and the removal.
    let model: EngineModel

    /// Whether the confirmation is showing.
    @State private var isConfirmationPresented = false

    /// The pane.
    var body: some View {
        Form {
            Section {
                ForEach(model.appData.items) { item in
                    AppDataRow(model: model, item: item)
                }
            } header: {
                Text("Saved on This Mac", comment: "Data settings: heading over the list of what the app has saved")
            } footer: {
                Text(
                    "Sizes are as on disk. The Keychain does not report a size.",
                    comment: "Data settings: footer under the list of saved data"
                )
            }

            if !model.appData.failures.isEmpty {
                Section {
                    ForEach(model.appData.failures) { failure in
                        LabeledContent {
                            EmptyView()
                        } label: {
                            Text(AppDataRow.name(of: failure.kind))
                            Text(failure.reason)
                        }
                    }
                } header: {
                    Text(
                        "Not Removed",
                        comment: "Data settings: heading over the kinds of data that could not be removed")
                } footer: {
                    Text(
                        "Tingra has stopped saving so nothing is written back. Quit Tingra, then remove what remains by hand.",
                        comment: "Data settings: footer under the kinds of data that could not be removed"
                    )
                }
            }

            Section {
                LabeledContent {
                    Button(role: .destructive) {
                        model.eventBus.tap("appDataRemove.button", domain: .platform)
                        isConfirmationPresented = true
                    } label: {
                        Text(
                            "Remove All Data…", comment: "Data settings: button that opens the remove-all confirmation")
                    }
                } label: {
                    Text("Start Over", comment: "Data settings: label of the remove-all row")
                    Text(
                        "Removes everything listed above except recordings, then quits Tingra so its next launch is a first run.",
                        comment: "Data settings: description under the remove-all row"
                    )
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Appearing is the moment the inventory is read: nothing else in
            // the app writes to disk while a settings pane is open that one
            // autosave would not cover, and a removal re-reads on its own.
            model.appData.refresh()
        }
        .alert(
            Text(
                "Remove all data and quit Tingra?",
                comment: "Confirmation alert title before removing everything the app has saved"),
            isPresented: $isConfirmationPresented
        ) {
            Button(role: .destructive) {
                model.eventBus.tap("appDataRemoveConfirm.button", domain: .platform)
                if model.removeAllData() {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Text("Remove and Quit", comment: "Confirmation alert button that removes all data and quits the app")
            }
            Button(role: .cancel) {
                model.eventBus.tap("appDataRemoveCancel.button", domain: .platform)
            } label: {
                Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    /// The confirmation's message: what will be removed, kind by kind with
    /// the counts of the moment, what is kept, and that it cannot be undone
    /// — the explicit list the operator confirms, not a summary of it.
    private var confirmationMessage: String {
        var lines: [String] = [
            String(
                localized: "This removes what Tingra has saved on this Mac, then quits. It cannot be undone.",
                comment: "Confirmation alert message before removing all data: the opening line")
        ]
        lines.append("")
        for item in model.appData.items where item.kind.isRemovable {
            let name = String(localized: AppDataRow.name(of: item.kind))
            let amount = AppDataRow.amount(of: item)
            if item.isEmpty {
                lines.append(
                    String(
                        localized: "• \(name): \(amount)",
                        comment:
                            "Confirmation alert message line for an empty kind of data: its name, then “None”"))
            } else {
                lines.append(
                    String(
                        localized: "• \(name): \(amount) — \(item.location)",
                        comment:
                            "Confirmation alert message line for a kind of data: its name, how much there is, and where"
                    ))
            }
        }
        if let recordings = model.appData.items.first(where: { $0.kind == .recordings }) {
            lines.append("")
            lines.append(
                String(
                    localized: "Recordings are kept: \(AppDataRow.amount(of: recordings)) in \(recordings.location).",
                    comment:
                        "Confirmation alert message closing line: the recordings are kept; the placeholders are how many there are and the folder"
                ))
        }
        return lines.joined(separator: "\n")
    }
}

/// One kind's row: its name and where it lives on the leading edge, how much
/// of it there is on the trailing edge. A location that is a folder on disk
/// is a link that opens it in the Finder.
struct AppDataRow: View {
    /// The engine model — for its event bus, so the folder link reports a
    /// `tap`.
    let model: EngineModel

    /// The item this row shows.
    let item: AppDataItem

    /// The row.
    var body: some View {
        LabeledContent {
            Text(Self.amount(of: item))
                .foregroundStyle(item.isEmpty ? .secondary : .primary)
        } label: {
            Text(Self.name(of: item.kind))
            location
        }
    }

    /// The location line: a link opening the folder when there is one to
    /// open, plain text otherwise (the Keychain, the preferences file, a
    /// folder not on disk).
    @ViewBuilder private var location: some View {
        if let folderURL = item.folderURL {
            Button {
                model.eventBus.tap(
                    "appDataFolder.button", domain: .platform, params: ["kind": .string(item.kind.rawValue)])
                NSWorkspace.shared.open(folderURL)
            } label: {
                Text(item.location)
                    .font(.caption.monospaced())
            }
            .buttonStyle(.link)
            .help(Text("Open this folder in the Finder", comment: "Tooltip on a Data settings folder link"))
        } else {
            Text(item.location)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    /// A kind's user-facing name.
    ///
    /// - Parameter kind: The kind to name.
    /// - Returns: Its localized name.
    static func name(of kind: AppDataKind) -> LocalizedStringResource {
        switch kind {
        case .project:
            LocalizedStringResource("Project Document", comment: "Data settings: the project document's name")
        case .destinations:
            LocalizedStringResource("Destinations", comment: "Data settings: the saved destinations' name")
        case .streamKeys:
            LocalizedStringResource("Stream Keys", comment: "Data settings: the stream keys' name")
        case .preferences:
            LocalizedStringResource("Preferences", comment: "Data settings: the preferences' name")
        case .logSession:
            LocalizedStringResource("Log Session Counter", comment: "Data settings: the log session counter's name")
        case .recordings:
            LocalizedStringResource("Recordings", comment: "Data settings: the recordings' name")
        }
    }

    /// How much of a kind there is, as one phrase: the count in the kind's
    /// own unit — files, keys, or entries — with the size on disk when there
    /// is one, or “None”.
    ///
    /// - Parameter item: The item to describe.
    /// - Returns: The localized phrase.
    static func amount(of item: AppDataItem) -> String {
        guard !item.isEmpty else {
            return String(localized: "None", comment: "Data settings: the amount shown for a kind with nothing saved")
        }
        let count =
            switch item.kind {
            case .streamKeys:
                String(localized: "\(item.count) keys", comment: "Data settings: a count of stream keys")
            case .preferences:
                String(localized: "\(item.count) entries", comment: "Data settings: a count of preference entries")
            case .project, .destinations, .logSession, .recordings:
                String(localized: "\(item.count) files", comment: "Data settings: a count of files")
            }
        guard let byteCount = item.byteCount else { return count }
        let size = byteCount.formatted(.byteCount(style: .file))
        return String(
            localized: "\(count), \(size)",
            comment: "Data settings: a count of files or entries, then their size on disk")
    }
}
