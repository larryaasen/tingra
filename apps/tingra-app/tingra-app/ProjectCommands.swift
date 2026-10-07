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
/// window is the show. (The windows beside it do close, under ⌘W:
/// ``WindowCloseCommands``.)
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
                    guard let url = await ProjectFilePanel.chooseNewProjectLocation() else { return }
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
                            params: ["file": .string(url.lastPathComponent)]
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

    /// Runs the save panel for a new project's location — New Project… —
    /// with the name field suggesting the next free numbered name in the
    /// folder the panel shows, Project 1, Project 2, … (``NewProjectName``),
    /// renumbered as the operator moves between folders until they type a
    /// name of their own (``NewProjectNameSuggester``).
    ///
    /// - Returns: The chosen location, or nil when the panel was cancelled.
    static func chooseNewProjectLocation() async -> URL? {
        let panel = makeSavePanel()
        let suggester = NewProjectNameSuggester()
        // The panel holds its delegate weakly, so the suggester is kept
        // alive here for as long as the panel is up.
        defer { withExtendedLifetime(suggester) {} }
        suggester.attach(to: panel)
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }

    /// Runs the save panel for a copy of the open project's location —
    /// Save As….
    ///
    /// - Parameter suggestedName: The name the panel's field starts with —
    ///   the open project's name.
    /// - Returns: The chosen location, or nil when the panel was cancelled.
    static func chooseNewLocation(suggestedName: String) async -> URL? {
        let panel = makeSavePanel()
        panel.nameFieldStringValue = suggestedName
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }

    /// A save panel for a project document: filtered to the project type,
    /// able to make a folder, and showing the extension.
    ///
    /// - Returns: The panel, not yet shown.
    private static func makeSavePanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tingraProject]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel
    }
}

/// Keeps a New Project save panel's name field on the next free numbered
/// name for the folder the panel is showing (``NewProjectName``): Project 3
/// in a folder holding Project 1 and Project 2, Project 1 again in an empty
/// one — renumbered each time the operator moves to another folder, the way
/// the Finder names a new folder for the folder it lands in.
///
/// **A name the operator typed is theirs.** The field is renumbered only
/// while it still shows the suggestion last put there
/// (``NewProjectName/fieldShows(_:fieldValue:)``); once the operator types
/// over it, moving between folders leaves their name alone.
///
/// The panel holds its delegate weakly, so the caller keeps the suggester
/// alive while the panel is up (``ProjectFilePanel/chooseNewProjectLocation()``).
final class NewProjectNameSuggester: NSObject, NSOpenSavePanelDelegate {
    /// The name last put in the panel's field — the one the suggester may
    /// still replace.
    private var suggestion = ""

    /// Becomes the panel's delegate and fills its name field with the next
    /// free name in the folder it opens on.
    ///
    /// - Parameter panel: The New Project save panel, not yet shown.
    func attach(to panel: NSSavePanel) {
        panel.delegate = self
        suggest(in: panel, for: panel.directoryURL)
    }

    /// Renumbers the name field for the folder the operator moved to, unless
    /// they have typed a name of their own.
    ///
    /// - Parameters:
    ///   - sender: The save panel.
    ///   - url: The folder the panel now shows.
    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        guard let panel = sender as? NSSavePanel,
            NewProjectName.fieldShows(suggestion, fieldValue: panel.nameFieldStringValue)
        else { return }
        suggest(in: panel, for: url)
    }

    /// Puts the next free name in a folder into the panel's field and
    /// remembers it as the suggestion.
    ///
    /// - Parameters:
    ///   - panel: The save panel.
    ///   - directory: The folder to number within.
    private func suggest(in panel: NSSavePanel, for directory: URL?) {
        suggestion = NewProjectName.next(in: directory)
        panel.nameFieldStringValue = suggestion
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
