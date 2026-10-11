//
//  WindowPickerSheet.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraCapturePlugIns
import TingraEventBus
import TingraHost

/// The **Add Window** sheet: the windows on screen now, grouped by
/// application, one of which the operator picks to add to the project as a
/// window input (ARCHITECTURE.md, "Window capture").
///
/// A sheet rather than a sidebar list of every open window because windows
/// are chosen, not discovered: a Mac has dozens open, and the operator wants
/// one of them. The sheet reads the list when it opens and again whenever
/// Tingra becomes active — the operator who leaves to open the window they
/// meant comes back to a list that has it — and never on a timer.
///
/// Reading the list needs Screen Recording access, so the sheet is also
/// where a missing grant is explained, with the button that opens the
/// switch. A window the project already holds is listed and marked, not
/// hidden: a list missing the window the operator is looking at reads as
/// broken.
///
/// Opened through ``EngineModel/isWindowPickerPresented`` and presented by
/// ``ContentView``.
struct WindowPickerSheet: View {
    /// The engine model the window is added through.
    let model: EngineModel

    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss

    /// What the sheet has to show for a list.
    private enum Listing {
        /// The list is being read.
        case loading

        /// The windows on screen, possibly none.
        case windows([CaptureWindow])

        /// Screen Recording access has not been granted.
        case denied

        /// The list could not be read for another reason, described.
        case unavailable(String)
    }

    /// The list, as last read.
    @State private var listing: Listing = .loading

    /// The selected window's identifier, or nil for none.
    @State private var selection: CaptureWindow.ID?

    /// The selected window, when it is still listed and not yet added.
    private var selectedWindow: CaptureWindow? {
        guard case .windows(let windows) = listing, let window = windows.first(where: { $0.id == selection }),
            !model.isWindowAdded(window)
        else { return nil }
        return window
    }

    /// The sheet: a title and caption, the list or what stands in for it,
    /// and the buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Window", comment: "Title of the sheet for adding a window as an input")
                .font(.headline)
            Text(
                "Choose a window to capture on its own. It is captured even while other windows cover it.",
                comment: "Caption of the Add Window sheet"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            content
                .frame(height: 320)

            HStack {
                Spacer()
                Button {
                    model.eventBus.tap("windowPickerCancel.button", domain: .capture)
                    dismiss()
                } label: {
                    Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    guard let window = selectedWindow else { return }
                    model.eventBus.tap(
                        "windowPickerAdd.button",
                        domain: .capture,
                        params: [
                            "name": .string(window.target.name),
                            "application": .string(window.target.bundleIdentifier),
                        ]
                    )
                    Task { await model.addWindow(window) }
                    dismiss()
                } label: {
                    Text("Add", comment: "Add Window sheet: adds the selected window as an input")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedWindow == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            await load()
            // Read again each time Tingra becomes active: the operator who
            // left to open a window returns to a list that has it.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await load()
            }
        }
    }

    /// The list, or what stands in for it while it is loading, empty, or
    /// unreadable.
    @ViewBuilder private var content: some View {
        switch listing {
        case .loading:
            ProgressView {
                Text("Looking for windows…", comment: "Add Window sheet: shown while the window list is read")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .windows(let windows) where windows.isEmpty:
            ContentUnavailableView {
                Label {
                    Text("No Windows Open", comment: "Add Window sheet: title when no window is on screen")
                } icon: {
                    Image(systemName: "macwindow")
                }
            } description: {
                Text(
                    "Open the window you want to capture, then return to Tingra.",
                    comment: "Add Window sheet: what to do when no window is on screen"
                )
            }
        case .windows(let windows):
            List(selection: $selection) {
                ForEach(WindowChoice.groups(from: windows)) { group in
                    Section {
                        ForEach(group.windows) { window in
                            row(window)
                        }
                    } header: {
                        // An application's name is runtime data, drawn
                        // verbatim.
                        Text(verbatim: group.applicationName)
                    }
                }
            }
            .listStyle(.inset)
            .clipShape(.rect(cornerRadius: 6))
        case .denied:
            ContentUnavailableView {
                Label {
                    Text(
                        "Screen Recording Access Needed",
                        comment: "Add Window sheet: title when Screen Recording access is not granted"
                    )
                } icon: {
                    Image(systemName: "lock")
                }
            } description: {
                Text(
                    "macOS lists other applications’ windows only for an app allowed to record the screen. Allow Tingra in System Settings, then return here.",
                    comment: "Add Window sheet: why the list is empty without Screen Recording access, and the fix"
                )
            } actions: {
                Button {
                    model.eventBus.tap("windowPickerOpenSettings.button", domain: .capture)
                    if let url = AuthorizationPermission.screenRecording.systemSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(
                        "Open System Settings…",
                        comment: "Button that opens the System Settings pane for a permission"
                    )
                }
            }
        case .unavailable(let reason):
            ContentUnavailableView {
                Label {
                    Text(
                        "Windows Unavailable",
                        comment: "Add Window sheet: title when the window list could not be read"
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                // The system's own description of what went wrong: runtime
                // data, drawn verbatim.
                Text(verbatim: reason)
            }
        }
    }

    /// One window's row: its title, its size, and a mark when the project
    /// already holds it — in which case the row cannot be selected.
    ///
    /// - Parameter window: The window.
    /// - Returns: The row.
    private func row(_ window: CaptureWindow) -> some View {
        let isAdded = model.isWindowAdded(window)
        return HStack {
            Label {
                // A window's title is runtime data, drawn verbatim.
                Text(verbatim: window.target.title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "macwindow")
            }
            Spacer(minLength: 8)
            if isAdded {
                Text("Added", comment: "Add Window sheet: marks a window the project already holds")
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: WindowChoice.sizeText(for: window))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .tag(window.id)
        .selectionDisabled(isAdded)
        .help(Text(verbatim: window.target.name))
    }

    /// Reads the window list into ``listing``, keeping the selection only
    /// while its window is still listed.
    private func load() async {
        do {
            let windows = try await model.availableWindows()
            listing = .windows(windows)
            if !windows.contains(where: { $0.id == selection }) { selection = nil }
        } catch WindowListingError.screenRecordingDenied {
            listing = .denied
            selection = nil
        } catch {
            listing = .unavailable(String(describing: error))
            selection = nil
        }
    }
}
