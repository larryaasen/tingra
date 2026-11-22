//
//  EngineModel+Presets.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// Presets: switching, adding, duplicating, renaming, removing, and
/// reordering them, and keeping the active preset in step with the session.
extension EngineModel {
    /// Switches to a preset: its shots become the compositor's pool, and the
    /// shot switcher and layer editor work within it. Never interrupts the
    /// program (GLOSSARY.md, "Preset"): the on-program shot stays when the
    /// target holds its id, and otherwise keeps rendering as a held snapshot
    /// until the operator takes a shot (``Compositor/loadPreset(_:)``). The
    /// mixer adopts the target's authored audio channels, or keeps the
    /// session strips when it has none (ARCHITECTURE.md, "Per-strip
    /// routing"). The active preset is session state, so a switch alone
    /// saves nothing.
    ///
    /// - Parameter presetID: The preset to switch to.
    func switchPreset(to presetID: PresetID) async {
        guard presetID != activePresetID, let target = presets.first(where: { $0.id == presetID }) else { return }
        syncActivePreset()
        activePresetID = presetID
        shots = target.shots
        compositor.loadPreset(target)
        activeShotID = compositor.activeShotID
        // Preview follows the program's by-id rule: it survives only when
        // the incoming preset holds the shot, and is refilled otherwise.
        previewShotID = compositor.previewShotID
        ensurePreviewStaged()
        syncTally()
        await reconfigure()
        await adoptAudioChannels(of: target)
    }

    /// Adds an empty preset (``PresetEdit/newPreset()``) at the end of the
    /// switcher order and autosaves. Adding is not switching.
    func addPreset() {
        guard hasSessionPreset else { return }
        let preset = PresetEdit.newPreset()
        presets.append(preset)
        eventBus.event(
            "preset.added",
            domain: .composition,
            params: ["preset": .string(preset.id.rawValue), "name": .string(preset.name)]
        )
        scheduleAutosave()
    }

    /// Inserts a copy of a preset right after it, under a fresh id and a
    /// "<name> copy" name. Shot ids are kept, so switching between the two
    /// holds the on-program shot. Duplicating is not switching.
    ///
    /// - Parameter presetID: The preset to duplicate.
    func duplicatePreset(_ presetID: PresetID) {
        guard let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        syncActivePreset()
        let copy = PresetEdit.duplicate(of: presets[index])
        presets.insert(copy, at: index + 1)
        eventBus.event(
            "preset.added",
            domain: .composition,
            params: ["preset": .string(copy.id.rawValue), "name": .string(copy.name)]
        )
        scheduleAutosave()
    }

    /// Renames a preset, keeping its identity and shots. An empty or
    /// whitespace-only name is ignored (``PresetEdit/renaming(_:to:)``). The
    /// compositor needs no reload: the name reaches it on the next switch.
    ///
    /// - Parameters:
    ///   - presetID: The preset to rename.
    ///   - name: The new user-facing name.
    func renamePreset(_ presetID: PresetID, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        syncActivePreset()
        let renamed = PresetEdit.renaming(presets[index], to: name)
        guard renamed != presets[index] else { return }
        presets[index] = renamed
        eventBus.event(
            "preset.renamed",
            domain: .composition,
            params: ["preset": .string(renamed.id.rawValue), "name": .string(renamed.name)]
        )
        scheduleAutosave()
    }

    /// Removes a preset; the last one cannot be removed. Removing the active
    /// preset switches to the adjacent one and cuts to its first shot, unless
    /// a matching shot id holds the program, and the mixer adopts the
    /// adjacent preset's audio channels as a switch does. Removing an
    /// inactive preset touches nothing on program.
    ///
    /// - Parameter presetID: The preset to remove.
    func removePreset(_ presetID: PresetID) async {
        guard presets.count > 1, let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        let removed = presets.remove(at: index)
        let removedActivePreset = presetID == activePresetID
        if removedActivePreset {
            let adjacent = presets[min(index, presets.count - 1)]
            activePresetID = adjacent.id
            shots = adjacent.shots
            compositor.loadPreset(adjacent)
            if compositor.activeShotID == nil {
                // No id match held the program, so the removed preset's shot
                // leaves the air: cut to the adjacent preset's first shot, or
                // to the background-only canvas when it has none.
                if let first = adjacent.shots.first {
                    compositor.take(shotID: first.id)
                } else {
                    compositor.setShot(Shot())
                }
            }
            activeShotID = compositor.activeShotID
            // The removed preset's staged shot left with it; refill from the
            // adjacent pool.
            previewShotID = compositor.previewShotID
            ensurePreviewStaged()
            syncTally()
        }
        eventBus.event(
            "preset.removed",
            domain: .composition,
            params: ["preset": .string(removed.id.rawValue), "name": .string(removed.name)]
        )
        scheduleAutosave()
        await reconfigure()
        if removedActivePreset, let adopted = presets.first(where: { $0.id == activePresetID }) {
            await adoptAudioChannels(of: adopted)
        }
    }

    /// Moves a preset in the switcher order (ARCHITECTURE.md, "Shot and
    /// preset reordering"). Document state only: the compositor holds just
    /// the loaded preset, so the program is untouched. Order matters, because
    /// the app adopts the first preset at launch. Syncs the session's edits
    /// into the active preset first, reports `preset.moved`, and autosaves.
    /// The destination is clamped; a move to the same position, or of an
    /// unknown preset, does nothing.
    ///
    /// - Parameters:
    ///   - presetID: The preset to move.
    ///   - index: The destination position in the switcher order.
    func movePreset(_ presetID: PresetID, to index: Int) {
        guard let from = presets.firstIndex(where: { $0.id == presetID }) else { return }
        let to = min(max(index, 0), presets.count - 1)
        guard to != from else { return }
        syncActivePreset()
        let preset = presets.remove(at: from)
        presets.insert(preset, at: to)
        eventBus.event(
            "preset.moved",
            domain: .composition,
            params: [
                "preset": .string(preset.id.rawValue),
                "name": .string(preset.name),
                "from": .int(from),
                "to": .int(to),
            ]
        )
        scheduleAutosave()
    }

    /// Writes the session's ``shots`` and ``mixerStrips`` back into the
    /// active preset's slot in ``presets``, so a save, switch, or duplicate
    /// works on the operator's current edits. The session mix is the active
    /// preset's audio configuration, so the first sync authors it, which is
    /// how a document saved before routing gains its channels
    /// (ARCHITECTURE.md, "Per-strip routing").
    func syncActivePreset() {
        guard let index = presets.firstIndex(where: { $0.id == activePresetID }) else { return }
        let active = presets[index]
        let channels = mixerStrips.map(\.audioChannel)
        // A transient shot is session state: the document gets the authored
        // shots only (ARCHITECTURE.md, "The shot bank").
        let persisted = ShotEdit.persistedShots(of: shots)
        guard active.shots != persisted || active.audioChannels != channels else { return }
        presets[index] = Preset(id: active.id, name: active.name, shots: persisted, audioChannels: channels)
    }

    /// Adopts a newly active preset's authored audio channels as the session
    /// strips, named from live discovery
    /// (``MixerStrip/strips(channels:discovered:preferring:)``), and
    /// reconfigures audio so they apply from the next mix tick. A preset with
    /// no authored audio changes nothing: the session mix carries across
    /// (ARCHITECTURE.md, "Per-strip routing").
    ///
    /// - Parameter preset: The preset whose audio channels to adopt.
    private func adoptAudioChannels(of preset: Preset) async {
        guard let channels = preset.audioChannels else { return }
        let strips = MixerStrip.strips(channels: channels, discovered: audioInputs)
        guard strips != mixerStrips else { return }
        mixerStrips = strips
        await reconfigureAudio()
    }
}
