//
//  EngineModel+Projects.swift
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
import TingraGeneratorPlugIns
import TingraHost
import TingraPlugInKit

/// Projects: opening, creating, and saving them, recent projects, and the session they restore.
extension EngineModel {
    /// Whether the open project can be replaced right now, which enables the
    /// File menu's New, Open, and Open Recent items (``ProjectSwitch``).
    var canReplaceProject: Bool {
        ProjectSwitch.refusal(isStreaming: isStreaming, isRecording: isRecording) == nil
    }

    /// Opens a project file the operator chose from the File menu or the
    /// Finder, replacing the open show (ARCHITECTURE.md, "Projects as
    /// documents"). Refused while streaming or recording, since a switch
    /// tears down the shot pool, the media inputs, and the destination list
    /// the sinks are delivering: a `project.open` error carries the `reason`.
    /// A file that is missing or not a project document is reported the same
    /// way and the open show stays as it was.
    ///
    /// - Parameter url: The project document to open.
    func openProject(at url: URL) async {
        guard hasSessionPreset, !isRemovingData else { return }
        let file = url.lastPathComponent
        if let reason = ProjectSwitch.refusal(isStreaming: isStreaming, isRecording: isRecording) {
            eventBus.error(
                "project.open",
                domain: .composition,
                params: ["file": .string(file), "reason": .string(reason)]
            )
            return
        }
        guard url.standardizedFileURL != store.fileURL.standardizedFileURL else { return }
        let target = ProjectStore(fileURL: url)
        let project: Project
        do {
            guard let loaded = try target.load() else {
                eventBus.error(
                    "project.open",
                    domain: .composition,
                    params: ["file": .string(file), "reason": .string("missing")]
                )
                return
            }
            project = loaded
        } catch {
            eventBus.error(
                "project.open",
                domain: .composition,
                params: ["file": .string(file), "error": .string(ProjectStore.eventDescription(of: error))]
            )
            return
        }
        await replaceShow(with: project, store: target)
        eventBus.event(
            "project.opened",
            domain: .composition,
            params: [
                "file": .string(file),
                "presets": .int(presets.count),
                "shots": .int(shots.count),
            ]
        )
    }

    /// Opens a project the Finder handed the app once the engine is ready:
    /// at once while the app runs, as the project the boot loads when it
    /// launched the app, or after ``start(launch:)`` when it arrives mid-boot.
    ///
    /// - Parameter url: The project document to open.
    func openProjectWhenReady(_ url: URL) async {
        if !started {
            sessionPreferences.lastProjectURL = url
        } else if hasSessionPreset {
            await openProject(at: url)
        } else {
            pendingProjectURL = url
        }
    }

    /// Makes a new project at a location the operator chose, seeded as a
    /// fresh install is, writes it at once so the file exists, and opens it.
    /// Refused like ``openProject(at:)``, as a `project.new` error.
    ///
    /// - Parameter url: Where the new project document goes.
    func newProject(at url: URL) async {
        guard hasSessionPreset, !isRemovingData else { return }
        let file = url.lastPathComponent
        if let reason = ProjectSwitch.refusal(isStreaming: isStreaming, isRecording: isRecording) {
            eventBus.error(
                "project.new",
                domain: .composition,
                params: ["file": .string(file), "reason": .string(reason)]
            )
            return
        }
        let project = Project(id: ProjectID(), presets: [seededShow().preset])
        await replaceShow(with: project, store: ProjectStore(fileURL: url))
        saveProject()
        eventBus.event("project.created", domain: .composition, params: ["file": .string(file)])
    }

    /// Writes the open show to a new file and makes that file the open
    /// project: later edits land there, and the previous file keeps what it
    /// had. Allowed while live, since nothing on air changes. A write that
    /// cannot land is reported as `project.save` and the project stays put.
    ///
    /// - Parameter url: The new project document's location.
    func saveProjectAs(to url: URL) {
        guard hasSessionPreset, !isRemovingData else { return }
        let target = ProjectStore(fileURL: url)
        guard url.standardizedFileURL != store.fileURL.standardizedFileURL else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        let previous = store.fileURL
        guard writeProject(to: target) else { return }
        store = target
        projectURL = url
        sessionPreferences.lastProjectURL = url
        noteRecentProject(url)
        eventBus.event(
            "project.savedAs",
            domain: .composition,
            params: [
                "from": .string(previous.lastPathComponent),
                "file": .string(url.lastPathComponent),
            ]
        )
    }

    /// Empties the Open Recent submenu — its Clear Menu item.
    func clearRecentProjects() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentProjectURLs = []
    }

    /// Records a project as recently opened, in the system's list — so it
    /// shows in Open Recent, the Apple menu's Recent Items, and the Dock.
    ///
    /// - Parameter url: The project document.
    func noteRecentProject(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentProjectURLs = NSDocumentController.shared.recentDocumentURLs
    }

    /// Replaces the open show with a document: the runtime counterpart of
    /// the boot load, against an engine that already has a show on air. The
    /// outgoing show's last edits are flushed first, so its file cannot
    /// change under a pending autosave, and its inputs are unregistered so
    /// the sidebar and the layer editor stop listing them. Then the document
    /// is adopted and its preset put on the buses
    /// (``activatePreset(recorded:)``).
    ///
    /// - Parameters:
    ///   - project: The document to open.
    ///   - target: Its store, which becomes ``store``.
    private func replaceShow(with project: Project, store target: ProjectStore) async {
        if autosaveTask != nil { saveProject() }
        for item in media {
            await registry.unregister(item.id.inputID)
        }
        for record in windows {
            await registry.unregister(record.id)
        }
        for record in applications {
            await registry.unregister(record.id)
        }
        store = target
        projectURL = target.fileURL
        let recorded = adoptDocument(project)
        if !media.isEmpty {
            await registerProjectMedia()
        }
        if !windows.isEmpty {
            await registerProjectWindows()
        }
        if !applications.isEmpty {
            await registerProjectApplications()
        }
        await readDeviceLists()
        await loadDestinations()
        await activatePreset(recorded: recorded)
        noteRecentProject(store.fileURL)
    }

    /// Puts an adopted document's preset on the buses: the recorded preset
    /// when the document holds it, else its first, seeding the built-in
    /// arrangement when it has none. Recorded program and staged shots are
    /// restored where they still exist (``restoreSessionPosition(in:)``);
    /// otherwise the compositor's by-id rule holds a shot the new pool also
    /// has, or the program cuts to the first shot. The mixer takes the
    /// preset's authored audio channels, the seed policy as its fallback.
    ///
    /// - Parameter recorded: The position recorded for the adopted project.
    private func activatePreset(recorded: SessionPosition) async {
        if presets.isEmpty {
            presets = [seededShow().preset]
            scheduleAutosave()
        }
        guard let preset = recorded.launchPreset(in: presets) else { return }
        // Held before the first assignment, so the placeholders below are not
        // recorded over the position being restored (``recordSessionPosition()``).
        restoredPosition = recorded
        activePresetID = preset.id
        shots = preset.shots
        compositor.loadPreset(preset)
        restoreSessionPosition(in: preset)
        if compositor.activeShotID == nil {
            if let first = preset.shots.first {
                compositor.take(shotID: first.id)
            } else {
                compositor.setShot(Shot())
            }
        }
        activeShotID = compositor.activeShotID
        previewShotID = compositor.previewShotID
        ensurePreviewStaged()
        syncTally()
        await reconfigure()
        mixerStrips = MixerStrip.strips(
            channels: preset.audioChannels, discovered: audioInputs, preferring: defaultMicrophoneID())
        await reconfigureAudio()
    }

    /// The built-in arrangement seeded around whichever discovered display
    /// and camera are running, as a preset (``ProgramLayout``). A generator
    /// needs no authorization, so the seed can reference bars before it runs.
    private struct SeededShow {
        /// The seeded preset, named Main.
        let preset: Preset

        /// Whether the seed references the bars generator, which then needs
        /// a configuration pass to start it.
        let referencesBars: Bool
    }

    /// Seeds the built-in arrangement around the first discovered display
    /// and camera that are running. The preset is named Main, which reads as
    /// the show's first preset, not as a fallback or the project's name.
    ///
    /// - Returns: The seeded preset.
    private func seededShow() -> SeededShow {
        let displayID = displays.first { activeInputs[$0.id] != nil }?.id
        let cameraID = cameras.first { activeInputs[$0.id] != nil }?.id
        let barsID = videoInputs.first { $0.id == BarsGenerator.inputID }?.id
        let preset = Preset(
            id: PresetID(rawValue: "main"),
            name: String(localized: "Main", comment: "Name of a fresh project's seeded preset"),
            shots: ProgramLayout.shots(displayID: displayID, cameraID: cameraID, barsID: barsID)
        )
        return SeededShow(preset: preset, referencesBars: barsID != nil)
    }

    /// Completes the first configuration pass. When no project file supplied
    /// a preset, seeds one from the built-in ``ProgramLayout`` arrangement
    /// and saves the fresh project at once, so the file exists from first
    /// launch. Then loads the active preset into the compositor, which cuts
    /// to its first shot: nothing is on program yet, the one case where
    /// loading cuts.
    func establishSessionPreset() {
        if !hasSessionPreset {
            let seeded = seededShow()
            shots = seeded.preset.shots
            if seeded.referencesBars { reconfigureRequested = true }
            presets = [seeded.preset]
            // A fresh project is named before its position is first
            // recorded, so the record lands under its own scope.
            let id = ProjectID()
            projectID = id
            sessionPreferences = sessionPreferences.scoped(to: id)
            sessionPreferences.lastProjectURL = store.fileURL
            noteRecentProject(store.fileURL)
            activePresetID = seeded.preset.id
            eventBus.event(
                "project.seeded",
                domain: .composition,
                params: ["file": .string(store.fileURL.lastPathComponent)]
            )
            saveProject()
        }
        if let active = presets.first(where: { $0.id == activePresetID }) {
            let loaded = Preset(id: active.id, name: active.name, shots: shots)
            compositor.loadPreset(loaded)
            restoreSessionPosition(in: loaded)
        }
        activeShotID = compositor.activeShotID
        // Preview starts lit like program does: the restored shot, else the
        // first shot not on program, is staged from boot, ready to take.
        ensurePreviewStaged()
        syncTally()
    }

    /// Puts the last run's program and staged shots back, once, on the first
    /// load of a document's preset: the position ``loadProject()`` read
    /// (ARCHITECTURE.md, "Restoring the operator's position"). The program
    /// shot is taken with a cut, since nothing is on air to transition from.
    /// A shot is restored only while it still exists in the pool
    /// (``SessionPosition/shots(validIn:)``); a missing one leaves that bus
    /// its usual pick.
    ///
    /// - Parameter preset: The preset the compositor just loaded.
    private func restoreSessionPosition(in preset: Preset) {
        guard let recorded = restoredPosition else { return }
        restoredPosition = nil
        let restored = recorded.shots(validIn: preset)
        if let program = restored.program, program != compositor.activeShotID {
            compositor.take(shotID: program, transition: .cut)
        }
        if let preview = restored.preview {
            compositor.setPreview(shotID: preview)
        }
        previewShotID = compositor.previewShotID
        eventBus.event(
            "session.restored",
            domain: .composition,
            params: [
                "preset": .string(preset.id.rawValue),
                "program": .string(restored.program?.rawValue ?? "none"),
                "preview": .string(restored.preview?.rawValue ?? "none"),
            ]
        )
    }

    /// Records the operator's position for the next launch. Called from the
    /// observers of ``activePresetID``, ``activeShotID``, ``previewShotID``,
    /// the transition settings, and ``switchingMode``, so no path that moves a
    /// bus, arms a transition, or changes the mode can forget to. Silent
    /// while data is being removed, so
    /// cleared preferences are not written back, and while a recorded
    /// position waits to be restored (``restoredPosition``): the buses hold
    /// placeholders until then, and recording them would overwrite it.
    func recordSessionPosition() {
        guard !isRemovingData, restoredPosition == nil else { return }
        sessionPreferences.position = SessionPosition(
            presetID: activePresetID,
            activeShotID: activeShotID,
            previewShotID: previewShotID,
            transitionKind: takeTransitionKind,
            wipeEdge: wipeEdge,
            shaderName: shaderName,
            transitionDuration: takeTransitionDuration,
            switchingMode: switchingMode
        )
    }

    /// The project-scoped value an app-tier plug-in has stored in the open
    /// project, or nil when it has none (PLUGINS.md, Decision 7).
    ///
    /// - Parameter plugIn: The plug-in's identifier.
    func plugInProjectData(for plugIn: PlugInID) -> JSONValue? {
        plugInData[plugIn.rawValue]
    }

    /// Replaces the project-scoped value an app-tier plug-in stores in the
    /// open project; nil removes it. An edit like a layer edit: the
    /// document is dirtied and autosaved, and the value travels with it.
    ///
    /// - Parameters:
    ///   - value: The value to store.
    ///   - plugIn: The plug-in's identifier.
    func setPlugInProjectData(_ value: JSONValue?, for plugIn: PlugInID) {
        guard plugInData[plugIn.rawValue] != value else { return }
        plugInData[plugIn.rawValue] = value
        eventBus.event(
            "project.plugInDataEdited", domain: .composition,
            params: ["plugIn": .string(plugIn.rawValue), "cleared": .bool(value == nil)])
        scheduleAutosave()
    }
}
