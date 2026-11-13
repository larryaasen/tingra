//
//  ApplicationPickerSheet.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraCapturePlugIns
import TingraEventBus

/// The **Add Application** sheet: the running applications that have audio,
/// one of which the operator picks to add to the project as an audio input
/// (ARCHITECTURE.md, "Application audio", A8).
///
/// The window picker's shape (``WindowPickerSheet``): applications are
/// chosen, not discovered, so the list is read when the sheet opens and again
/// whenever Tingra becomes active — the operator who leaves to launch the
/// application they meant comes back to a list that has it — never on a
/// timer. An application the project already holds is listed and marked, not
/// hidden.
///
/// Listing needs no permission. The caption says what adding does: the
/// application's sound moves off the speakers and into the mix once its strip
/// is unmuted, and macOS asks for System Audio Recording the first time.
///
/// Opened through ``EngineModel/isApplicationPickerPresented`` and presented
/// by ``ContentView``.
struct ApplicationPickerSheet: View {
    /// The engine model the application is added through.
    let model: EngineModel

    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss

    /// What the sheet has to show for a list.
    private enum Listing {
        /// The list is being read.
        case loading

        /// The running applications with audio, possibly none.
        case applications([CaptureApplication])

        /// The list could not be read, described.
        case unavailable(String)
    }

    /// The list, as last read.
    @State private var listing: Listing = .loading

    /// The selected application's bundle identifier, or nil for none.
    @State private var selection: CaptureApplication.ID?

    /// The selected application, when it is still listed and not yet added.
    private var selectedApplication: CaptureApplication? {
        guard case .applications(let applications) = listing,
            let application = applications.first(where: { $0.id == selection }),
            !model.isApplicationAdded(application)
        else { return nil }
        return application
    }

    /// The sheet: a title and caption, the list or what stands in for it,
    /// and the buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Application", comment: "Title of the sheet for adding an application as an audio input")
                .font(.headline)
            Text(
                "Choose an application to hear in the mix. When you unmute its channel strip, its sound moves from your speakers into the program. macOS asks for permission the first time.",
                comment: "Caption of the Add Application sheet"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            content
                .frame(height: 280)

            HStack {
                Spacer()
                Button {
                    model.eventBus.tap("applicationPickerCancel.button", domain: .capture)
                    dismiss()
                } label: {
                    Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    guard let application = selectedApplication else { return }
                    model.eventBus.tap(
                        "applicationPickerAdd.button",
                        domain: .capture,
                        params: [
                            "name": .string(application.name),
                            "application": .string(application.bundleIdentifier),
                        ]
                    )
                    Task { await model.addApplication(application) }
                    dismiss()
                } label: {
                    Text("Add", comment: "Add Application sheet: adds the selected application as an audio input")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedApplication == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            await load()
            // Read again each time Tingra becomes active: the operator who
            // left to launch an application returns to a list that has it.
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
                Text(
                    "Looking for applications…",
                    comment: "Add Application sheet: shown while the application list is read")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .applications(let applications) where applications.isEmpty:
            ContentUnavailableView {
                Label {
                    Text(
                        "No Applications With Sound",
                        comment: "Add Application sheet: title when no running application has audio")
                } icon: {
                    Image(systemName: "app.badge")
                }
            } description: {
                Text(
                    "Open the application you want to hear and start it playing, then return to Tingra.",
                    comment: "Add Application sheet: what to do when no running application has audio"
                )
            }
        case .applications(let applications):
            List(applications, selection: $selection) { application in
                row(application)
            }
            .listStyle(.inset)
            .clipShape(.rect(cornerRadius: 6))
        case .unavailable(let reason):
            ContentUnavailableView {
                Label {
                    Text(
                        "Applications Unavailable",
                        comment: "Add Application sheet: title when the application list could not be read"
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

    /// One application's row: its icon and name, and a mark when the project
    /// already holds it — in which case the row cannot be selected.
    ///
    /// - Parameter application: The application.
    /// - Returns: The row.
    private func row(_ application: CaptureApplication) -> some View {
        let isAdded = model.isApplicationAdded(application)
        return HStack {
            Label {
                // An application's name is runtime data, drawn verbatim.
                Text(verbatim: application.name)
                    .lineLimit(1)
            } icon: {
                ApplicationIcon(bundleIdentifier: application.bundleIdentifier)
            }
            Spacer(minLength: 8)
            if isAdded {
                Text("Added", comment: "Add Window sheet: marks a window the project already holds")
                    .foregroundStyle(.secondary)
            }
        }
        .tag(application.id)
        .selectionDisabled(isAdded)
    }

    /// Reads the application list into ``listing``, keeping the selection
    /// only while its application is still listed.
    private func load() async {
        do {
            let applications = try await model.availableApplications()
            listing = .applications(applications)
            if !applications.contains(where: { $0.id == selection }) { selection = nil }
        } catch {
            listing = .unavailable(String(describing: error))
            selection = nil
        }
    }
}

/// An application's Finder icon, found by its bundle identifier — the
/// picker's row icon, so an application is recognized at a glance. Falls
/// back to the generic application symbol when the application cannot be
/// found on disk.
struct ApplicationIcon: View {
    /// The application's bundle identifier.
    let bundleIdentifier: String

    /// The icon.
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app")
        }
    }
}
