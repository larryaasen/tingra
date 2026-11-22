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
    /// Whether the open project can be replaced right now — the File menu's
    /// New, Open, and Open Recent items are enabled while it can
    /// (``ProjectSwitch``).
    var canReplaceProject: Bool {
        ProjectSwitch.refusal(isStreaming: isStreaming, isRecording: isRecording) == nil
    }

    /// Opens a project file the operator chose, replacing the open show
    /// with it — File ▸ Open…, Open Recent, or a document double-clicked in
    /// the Finder (ARCHITECTURE.md, "Projects as documents").
    ///
    /// **Refused while streaming or recording**, as a program format change
    /// is, and for the larger reason: a switch tears down the shot pool, the
    /// media inputs, and the destination list, and the sinks are delivering
    /// them. The File menu's items are disabled then; this refusal — a
    /// `project.open` error event carrying the `reason` — is the rule. A
    /// file that is missing or not a project document is reported the same
    /// way and the open show stays exactly as it was; nothing is set aside,
    /// since the file is the operator's. Opening the project already open
    /// changes nothing.
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

    /// Opens a project the Finder handed the app, whenever the engine is
    /// ready for it: a document double-clicked while the app runs opens at
    /// once; one that launched the app becomes the project the boot loads,
    /// and one arriving mid-boot waits for ``start(launch:)`` to finish.
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

    /// Makes a new project at a location the operator chose — the built-in
    /// arrangement around the cast devices that are running, as a fresh
    /// install is seeded — writes it at once so the file exists from the
    /// moment it is made, and opens it. Refused while streaming or recording
    /// like ``openProject(at:)``, as a `project.new` error.
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
    /// project — Save As… on an autosaving document: from here on the edits
    /// land there, and the previous file keeps what it had. Allowed while
    /// live, since nothing on air changes. A write that cannot land is
    /// reported as `project.save` and the open project stays where it was.
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

    /// Replaces the open show with a document — the runtime counterpart of
    /// the boot load, against an engine that already has a show on air.
    ///
    /// The outgoing show's last edits are flushed to its file first, so the
    /// file cannot change under a pending autosave. Its media and window
    /// inputs are unregistered — they were the document's, and the sidebar
    /// and the layer editor must stop listing them — and its transient shots
    /// go with the pool, since they were session state of a show that is no
    /// longer open. Then the document is adopted, its media and windows
    /// registered, its destinations merged with the operator's store, and its preset put on
    /// the buses (``activatePreset(recorded:)``).
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
    /// when the document holds it, else its first — seeding the built-in
    /// arrangement into a document that has none, since a show cannot have
    /// no preset — with the recorded program and staged shots restored where
    /// they still exist (``restoreSessionPosition(in:)``). When nothing is
    /// recorded, the compositor's by-id rule holds a shot the new pool also
    /// has — a copy made by Save As switches seamlessly — and otherwise the
    /// outgoing show leaves the air with a cut to the first shot, the
    /// preset-removal rule. Then the inputs reconfigure around the new
    /// show, and the mixer takes the preset's authored audio channels as a
    /// boot does, the seed policy as its fallback.
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
    /// and camera are running, as a preset — a fresh install's first show,
    /// and a new project's (``ProgramLayout``). The bars generator is
    /// discovered rather than started: a generator needs no authorization, so
    /// the seed can reference it before it runs.
    private struct SeededShow {
        /// The seeded preset, named Main.
        let preset: Preset

        /// Whether the seed references the bars generator, which then needs
        /// a configuration pass to start it.
        let referencesBars: Bool
    }

    /// Seeds the built-in arrangement around the first discovered display
    /// and camera that are running.
    ///
    /// The preset is named **Main** (2026-09-27; it was "Default", which read
    /// as the project's name once both sat in the window's title bar — the
    /// default project's file was `Default.tingraproject` — and as "the
    /// fallback" rather than the show's first preset).
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

    /// Completes the first configuration pass: when no project file supplied
    /// a preset, seeds one from the built-in ``ProgramLayout`` arrangement
    /// (the first discovered display and camera, where they actually
    /// started, plus a bars shot when the
    /// bars generator is registered — which requests one more reconfigure
    /// pass to start it) and saves the fresh
    /// project immediately so the file exists from first launch; then loads
    /// the active preset into the compositor, which cuts to its first shot —
    /// nothing is on program yet, the one case where loading cuts (the active
    /// shot, like the active preset, is session state, never part of the
    /// document).
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
    /// load of a document's preset — the position ``loadProject()`` read
    /// (ARCHITECTURE.md, "Restoring the operator's position").
    ///
    /// The program shot is taken with a cut: nothing is on air yet, so there
    /// is nothing to transition from, and the compositor's own first load
    /// cut the same way. Each shot is restored only while it still exists in
    /// the pool (``SessionPosition/shots(validIn:)``); a missing one leaves
    /// the established rule for that bus — the first shot on program,
    /// ``ensurePreviewStaged()``'s pick on preview. A seeded fresh project
    /// never has a position to restore.
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

    /// Records the operator's position for the next launch — called from the
    /// observers of ``activePresetID``, ``activeShotID``, ``previewShotID``,
    /// ``takeTransitionKind``, ``wipeEdge``, ``shaderName``, and
    /// ``takeTransitionDuration``, so no path that moves a bus or arms a
    /// transition can forget to. Silent while data
    /// is being removed, so the preferences the operator just cleared are not
    /// written back by the quit that follows. Silent too while a recorded
    /// position is waiting to be restored (``restoredPosition``): until
    /// ``restoreSessionPosition(in:)`` runs, the buses hold placeholders, and
    /// recording them would overwrite the position the launch is about to put
    /// back — for good, if the process ends in that window (a kill mid-boot,
    /// a crash, a test host torn down).
    func recordSessionPosition() {
        guard !isRemovingData, restoredPosition == nil else { return }
        sessionPreferences.position = SessionPosition(
            presetID: activePresetID,
            activeShotID: activeShotID,
            previewShotID: previewShotID,
            transitionKind: takeTransitionKind,
            wipeEdge: wipeEdge,
            shaderName: shaderName,
            transitionDuration: takeTransitionDuration
        )
    }

    /// Saves the project document now — every preset in switcher order, the
    /// active one refreshed with its live layer-tree edits first — cancelling
    /// any pending autosave. A save that cannot write is reported on the bus
    /// and the session continues: the edits are still live on program, only
    /// unsaved.
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
