//
//  LoggingSettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import CoreTransferable
import SwiftUI
import TingraEventBus
import TingraHost
import UniformTypeIdentifiers

/// The Logging settings pane: where the log file is and how big it is, and
/// the three things an operator does with it — share a dated snapshot,
/// reveal it in the Finder, and clear it (ARCHITECTURE.md, "The log file and
/// the Logging settings pane").
///
/// On the Data pane's shape: a grouped form of labeled rows with the control
/// on the trailing edge. The feedback for a clear is the size row emptying
/// and the `log.cleared` event — the app has no toasts, and does not gain one
/// for this. The size is read when the pane appears and after each action
/// (``LogFileModel``), never polled.
///
/// **Share is a `ShareLink` over a snapshot taken at share time**
/// (``LogSnapshot``), not over the live file a sink is still appending to:
/// the picker receives a text file named for today, the Auto Care Plus rule.
/// A `ShareLink` has no action closure, so its `tap` rides a simultaneous
/// gesture — the one control in the app that reports its tap that way, and
/// only because the link offers nowhere else to say it.
struct LoggingSettingsView: View {
    /// The engine model — for its event bus (every control reports a `tap`)
    /// and its log file model.
    let model: EngineModel

    /// Whether the clear confirmation is showing.
    @State private var isClearConfirmationPresented = false

    /// Opens the Log window.
    @Environment(\.openWindow) private var openWindow

    /// The pane.
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button {
                        model.eventBus.tap("logReveal.button", domain: .platform)
                        NSWorkspace.shared.activateFileViewerSelecting([model.logFileModel.logFile.url])
                        model.logFileModel.refresh()
                    } label: {
                        Text(
                            "Reveal in Finder",
                            comment: "Logging settings: button that shows the log file in the Finder")
                    }
                    .disabled(!model.logFileModel.exists)
                    .help(
                        Text(
                            "Show the log file in the Finder",
                            comment: "Tooltip on the Logging settings Reveal in Finder button"))
                } label: {
                    Text("Location", comment: "Logging settings: label of the row naming where the log file is")
                    Text(AppDataStore.abbreviatedPath(of: model.logFileModel.logFile.url))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                LabeledContent {
                    Text(sizeText)
                        .foregroundStyle(model.logFileModel.isEmpty ? .secondary : .primary)
                } label: {
                    Text("Size", comment: "Logging settings: label of the row showing the log file's size")
                }
            } header: {
                Text("Log File", comment: "Logging settings: heading over the log file's location and size")
            } footer: {
                Text(
                    "Tingra records what it does — every event on its event bus — to this file, in the format the command line's --log-file option writes. Console.app carries the same events in the system log.",
                    comment: "Logging settings: footer explaining what the log file is"
                )
            }

            Section {
                LabeledContent {
                    Button {
                        model.eventBus.tap("logShow.button", domain: .platform)
                        openWindow(id: TingraApp.logWindowID)
                    } label: {
                        Text("Show Log", comment: "Logging settings: button that opens the Log window")
                    }
                } label: {
                    Text("Log Window", comment: "Logging settings: label of the row that opens the Log window")
                    Text(
                        "Shows the log as it is written, with filters and search.",
                        comment: "Logging settings: description under the Log Window row")
                }

                LabeledContent {
                    ShareLink(
                        item: LogSnapshot(logFile: model.logFileModel.logFile),
                        preview: SharePreview(
                            Text(
                                "Tingra Log",
                                comment: "Logging settings: the shared log file's title in the share picker"),
                            image: Image(systemName: "doc.text"))
                    ) {
                        Text("Share…", comment: "Logging settings: button that opens the share picker for the log file")
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            model.eventBus.tap("logShare.button", domain: .platform)
                            model.logFileModel.refresh()
                        }
                    )
                    .disabled(model.logFileModel.isEmpty)
                } label: {
                    Text("Share Log File", comment: "Logging settings: label of the share row")
                    Text(
                        "Sends a copy of the log as a text file named for today.",
                        comment: "Logging settings: description under the share row")
                }

                LabeledContent {
                    Button(role: .destructive) {
                        model.eventBus.tap("logClear.button", domain: .platform)
                        model.logFileModel.refresh()
                        isClearConfirmationPresented = true
                    } label: {
                        Text("Clear…", comment: "Logging settings: button that opens the clear confirmation")
                    }
                    .disabled(model.logFileModel.isEmpty)
                } label: {
                    Text(
                        "Clear Log File",
                        comment: "Logging settings: label of the clear row, and the confirmation's button")
                    Text(
                        "Empties the log so the next one you share covers only the problem you are reporting.",
                        comment: "Logging settings: description under the clear row")
                }
            } footer: {
                if let failure = model.logFileModel.clearFailure {
                    Text(failure)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Appearing is the moment the size is read; each action re-reads.
            model.logFileModel.refresh()
        }
        .alert(
            Text("Clear the log file?", comment: "Confirmation alert title before emptying the log file"),
            isPresented: $isClearConfirmationPresented
        ) {
            Button(role: .destructive) {
                model.eventBus.tap("logClearConfirm.button", domain: .platform)
                model.logFileModel.clear()
            } label: {
                Text(
                    "Clear Log File", comment: "Logging settings: label of the clear row, and the confirmation's button"
                )
            }
            Button(role: .cancel) {
                model.eventBus.tap("logClearCancel.button", domain: .platform)
            } label: {
                Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
            }
        } message: {
            Text(
                "This empties the \(sizeText) Tingra has recorded so far. New activity is still logged, so the next log you share covers only the problem you are reporting. This cannot be undone.",
                comment: "Confirmation alert message before emptying the log file; the placeholder is its size"
            )
        }
    }

    /// The size row's text: the bytes on disk, “Empty” for a file with
    /// nothing in it, “Not created yet” before the first event lands.
    private var sizeText: String {
        guard let byteCount = model.logFileModel.byteCount else {
            return String(
                localized: "Not created yet", comment: "Logging settings: the size shown before the log file exists")
        }
        guard byteCount > 0 else {
            return String(localized: "Empty", comment: "Logging settings: the size shown for an empty log file")
        }
        return byteCount.formatted(.byteCount(style: .file))
    }
}

/// The log as the share picker receives it: a text file copied from the log
/// **when the share happens**, named for the day (`Tingra Log 2026-09-08.txt`).
///
/// A `Transferable` with a file representation rather than the log's URL,
/// because the URL would hand the picker the live file a sink is still
/// appending to, and because the export closure running at share time is
/// what makes the snapshot current — a link over a snapshot taken when the
/// pane appeared would share a stale copy.
struct LogSnapshot: Transferable, Sendable {
    /// The file to snapshot.
    let logFile: LogFile

    /// The file representation: the snapshot, exported as plain text.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { snapshot in
            SentTransferredFile(try snapshot.logFile.snapshot())
        }
    }
}
