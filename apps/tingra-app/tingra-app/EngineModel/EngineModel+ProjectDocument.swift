//
//  EngineModel+ProjectDocument.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// The project document: loading it, adopting it into the session, and saving it.
extension EngineModel {
    /// Loads the project document at boot — the project the app last had
    /// open when the file is still there and readable, else the default
    /// project — adopting the recorded preset (or the document's first) as
    /// the active preset; with no file (or a file holding no presets), it
    /// leaves the presets unseeded — ``establishSessionPreset()`` seeds them
    /// from the built-in arrangement on the first configuration pass, around
    /// the first discovered display and camera.
    ///
    /// A last project that is missing or unreadable is reported as
    /// `project.reopen` and left alone — it is the operator's file, moved or
    /// edited by hand — and the launch falls back to the default project,
    /// whose own unreadable file is set aside rather than silently
    /// overwritten (see ARCHITECTURE.md, "Project save/load" and "Projects
    /// as documents").
    func loadProject() {
        // Read before anything below assigns a preset or a shot: each
        // assignment records the new position over the old. The armed
        // transition needs no document to come back: it is the switcher's
        // own setting, global across projects, restored whatever the
        // project holds.
        let armed = sessionPreferences.position
        if let kind = armed.transitionKind { takeTransitionKind = kind }
        if let edge = armed.wipeEdge { wipeEdge = edge }
        if let shader = armed.shaderName { shaderName = shader }
        if let duration = armed.transitionDuration { setTakeTransitionDuration(duration) }

        recentProjectURLs = NSDocumentController.shared.recentDocumentURLs
        var loaded: Project?
        if let last = sessionPreferences.lastProjectURL,
            last.standardizedFileURL != defaultStore.fileURL.standardizedFileURL
        {
            let lastStore = ProjectStore(fileURL: last)
            let lastFile = last.lastPathComponent
            do {
                if let project = try lastStore.load() {
                    store = lastStore
                    loaded = project
                } else {
                    eventBus.event(
                        "project.reopen",
                        domain: .composition,
                        params: ["file": .string(lastFile), "reason": .string("missing")]
                    )
                }
            } catch {
                eventBus.error(
                    "project.reopen",
                    domain: .composition,
                    params: ["file": .string(lastFile), "error": .string(ProjectStore.eventDescription(of: error))]
                )
            }
        }
        if loaded == nil {
            store = defaultStore
            loaded = loadDefaultProject()
        }
        projectURL = store.fileURL

        // A fresh project: the first configuration pass seeds the built-in
        // arrangement from whichever of the first discovered devices start.
        guard let project = loaded else { return }
        let recorded = adoptDocument(project)

        // The recorded preset when the document still holds it, else the
        // first — and the recorded shots wait for the compositor to have the
        // pool (``establishSessionPreset()``).
        guard let loadedPreset = recorded.launchPreset(in: presets) else { return }

        restoredPosition = recorded
        activePresetID = loadedPreset.id
        shots = loadedPreset.shots
        noteRecentProject(store.fileURL)
        eventBus.event(
            "project.loaded",
            domain: .composition,
            params: [
                "file": .string(store.fileURL.lastPathComponent),
                "presets": .int(presets.count),
                "shots": .int(shots.count),
            ]
        )
    }

    /// Reads the default project's document, or returns nil when there is
    /// none yet (a fresh install). An unreadable file is reported and set
    /// aside, never silently overwritten (see ARCHITECTURE.md, "Project
    /// save/load").
    ///
    /// - Returns: The default project, or nil when there is no readable one.
    private func loadDefaultProject() -> Project? {
        let file = defaultStore.fileURL.lastPathComponent
        do {
            return try defaultStore.load()
        } catch {
            eventBus.error(
                "project.load",
                domain: .composition,
                params: ["file": .string(file), "error": .string(ProjectStore.eventDescription(of: error))]
            )
            do {
                let setAside = try defaultStore.setAsideUnreadableFile()
                eventBus.event(
                    "project.setAside",
                    domain: .composition,
                    params: ["file": .string(setAside.lastPathComponent)]
                )
            } catch {
                eventBus.error(
                    "project.setAside",
                    domain: .composition,
                    params: ["file": .string(file), "error": .string(ProjectStore.eventDescription(of: error))]
                )
            }
            return nil
        }
    }

    /// Takes a document's content as the app's — the presets, the
    /// destination references, the program format, the media list, and the
    /// document's identity — from the store already installed as ``store``,
    /// and returns the position recorded for that project so the caller can
    /// choose the preset and shots to put back. The one path both the boot
    /// load and a File-menu switch go through (ARCHITECTURE.md, "Projects as
    /// documents").
    ///
    /// A document written before projects had ids is read under the
    /// one-project era's flat position keys, then assigned an id and
    /// autosaved with it, so its position carries across the launch that
    /// names it.
    ///
    /// - Parameter project: The document to adopt.
    /// - Returns: The recorded position for that project.
    func adoptDocument(_ project: Project) -> SessionPosition {
        let file = store.fileURL.lastPathComponent
        // A document written before transient shots existed carries the
        // automatic shots the app made to stage clicked inputs; under the
        // rule they were never the operator's, so they are dropped rather
        // than promoted, and the next save writes them out
        // (ARCHITECTURE.md, "The shot bank").
        presets = project.presets.map { preset in
            Preset(
                id: preset.id,
                name: preset.name,
                shots: ShotEdit.persistedShots(of: preset.shots),
                audioChannels: preset.audioChannels
            )
        }
        let dropped = zip(project.presets, presets).reduce(0) { $0 + $1.0.shots.count - $1.1.shots.count }
        if dropped > 0 {
            eventBus.event(
                "project.transientShotsDropped",
                domain: .composition,
                params: ["file": .string(file), "count": .int(dropped)]
            )
            scheduleAutosave()
        }
        // Hold this project's references; ``loadDestinations()`` merges
        // them with the operator's store to build the panel rows (each key
        // stays in secure storage, read lazily when the panel prefills that
        // row's field).
        projectDestinationReferences = project.destinations
        // The program's format is the project's; an absent key is the
        // 1080p30 default. The compositor may already exist (a monitor's
        // relay creates it), so it is told too — a no-op when the format is
        // the one it was built with. A hand-edited file's broken format
        // (odd, too small, or a rate outside 1…240) loads as the default and
        // is reported rather than reaching the compositor.
        let loaded = ProgramFormatChoice.loadedFormat(project.programFormat)
        if let problem = loaded.problem, let stored = project.programFormat {
            eventBus.error(
                "program.format",
                domain: .composition,
                params: [
                    "resolution": .string("\(stored.width)x\(stored.height)"),
                    "fps": .int(stored.frameRate),
                    "reason": .string("invalid"),
                    "problem": .string(problem.identifier),
                ]
            )
        }
        format = loaded.format
        compositor.setFormat(format)
        // The media list is the document's; its inputs register once the
        // load returns (``registerProjectMedia()``).
        media = project.media ?? []
        mediaDurations = [:]
        mediaSizes = [:]
        // The window list is the document's too, registered the same way
        // (``registerProjectWindows()``).
        windows = project.windows ?? []
        windowSizes = [:]
        // The application list too (``registerProjectApplications()``).
        applications = project.applications ?? []
        // Plug-in data is the document's, opaque to the app.
        plugInData = project.plugInData ?? [:]
        // So are the monitors' overlays; absent means the defaults.
        monitorOverlaySettings = project.monitorOverlays
        // The inputs' settings are the document's too; they reach the
        // inputs with the next device-list rebuild.
        inputParameters = Dictionary(
            uniqueKeysWithValues: (project.inputParameters ?? [:]).map { (InputID(rawValue: $0.key), $0.value) })

        let recorded: SessionPosition
        if let id = project.id {
            projectID = id
            sessionPreferences = sessionPreferences.scoped(to: id)
            recorded = sessionPreferences.position
        } else {
            recorded = sessionPreferences.scoped(to: nil).position
            let id = ProjectID()
            projectID = id
            sessionPreferences = sessionPreferences.scoped(to: id)
            scheduleAutosave()
        }
        sessionPreferences.lastProjectURL = store.fileURL
        return recorded
    }

    func saveProject() {
        guard hasSessionPreset, !isRemovingData else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        writeProject(to: store)
    }

    /// Writes the open show to a store — the document ``saveProject()``
    /// autosaves and ``saveProjectAs(to:)`` copies: every preset in switcher
    /// order, the active one refreshed with its live layer-tree edits first,
    /// under the project's id.
    ///
    /// - Parameter target: The store to write through.
    /// - Returns: Whether the write landed; a write that could not is
    ///   reported as `project.save` on the bus.
    @discardableResult
    func writeProject(to target: ProjectStore) -> Bool {
        syncActivePreset()
        // The document records only which destinations this show streams to
        // and whether each is enabled; the names and URLs belong to the
        // operator's store, and the keys to secure storage (DESTINATIONS.md).
        // The default format is written as an absent key, so a project that
        // never changed it round-trips to the document it had before the
        // setting existed.
        let project = Project(
            id: projectID,
            presets: presets,
            destinations: DestinationEdit.references(from: destinations),
            programFormat: format == ProgramFormat() ? nil : format,
            media: media.isEmpty ? nil : media,
            windows: windows.isEmpty ? nil : windows,
            applications: applications.isEmpty ? nil : applications,
            plugInData: plugInData.isEmpty ? nil : plugInData,
            inputParameters: inputParameters.isEmpty
                ? nil : Dictionary(uniqueKeysWithValues: inputParameters.map { ($0.key.rawValue, $0.value) }),
            monitorOverlays: monitorOverlaySettings
        )
        do {
            try target.save(project)
            eventBus.event(
                "project.saved",
                domain: .composition,
                params: ["file": .string(target.fileURL.lastPathComponent)]
            )
            return true
        } catch {
            eventBus.error(
                "project.save",
                domain: .composition,
                params: [
                    "file": .string(target.fileURL.lastPathComponent),
                    "error": .string(ProjectStore.eventDescription(of: error)),
                ]
            )
            return false
        }
    }

    /// Schedules the debounced autosave: the write lands one second after the
    /// last edit, so a slider drag's many per-gesture edits coalesce into a
    /// single save (the same reasoning that keeps successful `updateShot`
    /// calls off the event bus; see ARCHITECTURE.md, "Project save/load").
    func scheduleAutosave() {
        guard !isRemovingData else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return  // Cancelled: a newer edit rescheduled, or a save flushed it.
            }
            self?.saveProject()
        }
    }
}
