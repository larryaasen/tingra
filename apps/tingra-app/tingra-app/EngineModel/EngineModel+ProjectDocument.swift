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
    /// Loads the project document at boot: the project the app last had open
    /// when its file is still readable, else the default project, adopting
    /// the recorded preset (or the document's first) as the active preset.
    /// With no file, or one holding no presets, ``establishSessionPreset()``
    /// seeds them on the first configuration pass. A last project that is
    /// missing or unreadable is reported as `project.reopen` and left alone,
    /// being the operator's file (ARCHITECTURE.md, "Project save/load" and
    /// "Projects as documents").
    func loadProject() {
        // Read before anything below assigns a preset or a shot, since each
        // assignment records the new position over the old. The armed
        // transition is global across projects, so it is always restored.
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
        // first; the recorded shots wait for ``establishSessionPreset()``.
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

    /// Reads the default project's document. An unreadable file is reported
    /// and set aside, never silently overwritten (ARCHITECTURE.md, "Project
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

    /// Takes a document's content as the app's (presets, destination
    /// references, program format, media list, identity) from the store
    /// already installed as ``store``: the one path the boot load and a
    /// File-menu switch share (ARCHITECTURE.md, "Projects as documents"). A
    /// document written before projects had ids is read under the flat
    /// position keys, then assigned an id and autosaved with it.
    ///
    /// - Parameter project: The document to adopt.
    /// - Returns: The position recorded for that project, so the caller can
    ///   choose the preset and shots to put back.
    func adoptDocument(_ project: Project) -> SessionPosition {
        let file = store.fileURL.lastPathComponent
        // A document from before transient shots carries the automatic shots
        // made to stage clicked inputs. They were never the operator's, so
        // they are dropped here (ARCHITECTURE.md, "The shot bank").
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
        // Held until ``loadDestinations()`` merges them with the operator's
        // store into the panel rows; each key stays in secure storage.
        projectDestinationReferences = project.destinations
        // The program's format is the project's; an absent key is the
        // 1080p30 default, and a hand-edited file's broken format loads as
        // the default and is reported. The compositor may already exist (a
        // monitor's relay creates it), so it is told too.
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

    /// Saves the project document now, every preset in switcher order with
    /// the active one refreshed first, cancelling any pending autosave. A
    /// save that cannot write is reported on the bus and the session
    /// continues, its edits live on program but unsaved.
    func saveProject() {
        guard hasSessionPreset, !isRemovingData else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        writeProject(to: store)
    }

    /// Writes the open show to a store: every preset in switcher order, the
    /// active one refreshed with its live edits first, under the project's
    /// id. ``saveProject()`` and ``saveProjectAs(to:)`` both write through it.
    ///
    /// - Parameter target: The store to write through.
    /// - Returns: Whether the write landed; one that could not is reported as
    ///   `project.save` on the bus.
    @discardableResult
    func writeProject(to target: ProjectStore) -> Bool {
        syncActivePreset()
        // The document records only which destinations this show streams to
        // and whether each is enabled; names and URLs belong to the
        // operator's store, and keys to secure storage (DESTINATIONS.md). The
        // default format is an absent key, so an unchanged one round-trips.
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
    /// last edit, so a slider drag's many edits coalesce into a single save
    /// (ARCHITECTURE.md, "Project save/load").
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
