//
//  ProjectCommands.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraEventBus
import UniformTypeIdentifiers

/// The **File** menu's project items — the document commands of an app
/// that keeps one project open at a time and autosaves it (ARCHITECTURE.md,
/// "Projects as documents"): **New Project…** (⌘N) and **Open…** (⌘O),
/// with an **Open Recent** submenu fed by the system's recent-documents
/// list and ending in Clear Menu; then **Save As…** (⇧⌘S), which writes
/// the show to a new file and continues there, and **Reveal in Finder**.
/// There is no Save and no Close: the document is always saved, and the
/// window is the show.
///
/// Not SwiftUI's `DocumentGroup`: that scene assumes N windows over N
/// documents, each with its own model and a dirty state, and Tingra has one
/// engine, one program, and one set of TCC-granted inputs — a project is
/// the show the single engine is running, not a window. So the items are
/// plain commands over ``EngineModel``, and the open and save panels are
/// AppKit's (``ProjectFilePanel``), where SwiftUI has no save panel that
/// does not require a `FileDocument`.
///
/// **New, Open, and Open Recent are disabled while streaming or
/// recording.** A switch tears down the shot pool, the media inputs, and
/// the destination list while the sinks are delivering them; the model
/// refuses then too (``EngineModel/openProject(at:)``), so the disabled
/// items are the courtesy and the refusal is the rule — the program format
/// menu's own posture. Save As stays enabled: it changes nothing on air.
/// Each item reports its `tap` where the user action executes.
struct ProjectCommands: Commands {
    /// The engine model the items open and save projects through, and
    /// report their `tap` to.
    let model: EngineModel

    /// The menu.
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                model.eventBus.tap("projectNew.menuItem", domain: .composition)
                Task {
                    guard let url = await ProjectFilePanel.chooseNewLocation() else { return }
                    await model.newProject(at: url)
                }
            } label: {
                Text("New Project…", comment: "File menu item making a new project at a chosen location")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.canReplaceProject)

            Button {
                model.eventBus.tap("projectOpen.menuItem", domain: .composition)
                Task {
                    guard let url = await ProjectFilePanel.chooseExisting() else { return }
                    await model.openProject(at: url)
                }
            } label: {
                Text("Open…", comment: "File menu item opening a project file")
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!model.canReplaceProject)

            Menu {
                ForEach(model.recentProjectURLs, id: \.self) { url in
                    Button {
                        model.eventBus.tap(
                            "projectOpenRecent.menuItem",
                            domain: .composition,
                            params: ["path": .string(url.path(percentEncoded: false))]
                        )
                        Task { await model.openProject(at: url) }
                    } label: {
                        // The full file name, extension included: the row
                        // names a file, and two shows can share a name in
                        // different folders (Larry, 2026-09-13).
                        Text(url.lastPathComponent)
                    }
                }
                if !model.recentProjectURLs.isEmpty {
                    Divider()
                    Button {
                        model.eventBus.tap("projectClearRecent.menuItem", domain: .composition)
                        model.clearRecentProjects()
                    } label: {
                        Text("Clear Menu", comment: "Open Recent submenu item emptying the list of recent projects")
                    }
                }
            } label: {
                Text("Open Recent", comment: "File menu submenu listing recently opened projects")
            }
            .disabled(!model.canReplaceProject)
        }

        CommandGroup(replacing: .saveItem) {
            Button {
                model.eventBus.tap("projectSaveAs.menuItem", domain: .composition)
                Task {
                    guard let url = await ProjectFilePanel.chooseNewLocation(suggestedName: model.projectName) else {
                        return
                    }
                    model.saveProjectAs(to: url)
                }
            } label: {
                Text("Save As…", comment: "File menu item writing the open project to a new file and continuing there")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                model.eventBus.tap("projectReveal.menuItem", domain: .composition)
                NSWorkspace.shared.activateFileViewerSelecting([model.projectURL])
            } label: {
                Text("Reveal in Finder", comment: "Menu item showing a file in the Finder")
            }
        }
    }
}

/// The open and save panels the File menu's project items run — AppKit's,
/// since SwiftUI's `fileExporter` wants a `FileDocument` the engine does not
/// model. Filtered to the project document's type (`UTType.tingraProject`).
/// The operator chooses the location through the panel, which is also what
/// lets a folder macOS protects (Desktop, Documents) be used without a
/// permission prompt: a path chosen in a panel is user consent.
@MainActor
enum ProjectFilePanel {
    /// Runs the open panel over project documents.
    ///
    /// - Returns: The chosen project file, or nil when the panel was
    ///   cancelled.
    static func chooseExisting() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tingraProject]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }

    /// Runs the save panel for a new project file's location.
    ///
    /// - Parameter suggestedName: The name the panel's field starts with
    ///   (the localized "Untitled" by default; the open project's name for
    ///   Save As).
    /// - Returns: The chosen location, or nil when the panel was cancelled.
    static func chooseNewLocation(
        suggestedName: String = String(localized: "Untitled", comment: "Default name of a new project file")
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tingraProject]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}

/// The rule behind the File menu's disabled items and the model's refusal:
/// when the open project can be replaced, and why not.
enum ProjectSwitch {
    /// Why replacing the open project is refused right now, or `nil` when
    /// it is allowed. The program format's own rule (``ProgramFormatChoice``
    /// `refusal`), for the larger reason: a switch tears down the shot
    /// pool, the media inputs, and the destination list while the sinks are
    /// delivering them.
    ///
    /// - Parameters:
    ///   - isStreaming: Whether a stream session is starting, live, or
    ///     reconnecting.
    ///   - isRecording: Whether a recording is starting or writing.
    /// - Returns: `"streaming"` or `"recording"` — the `reason` the refusal's
    ///   error event carries — or `nil`.
    static func refusal(isStreaming: Bool, isRecording: Bool) -> String? {
        ProgramFormatChoice.refusal(isStreaming: isStreaming, isRecording: isRecording)
    }
}
