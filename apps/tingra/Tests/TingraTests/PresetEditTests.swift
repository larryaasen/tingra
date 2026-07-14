//
//  PresetEditTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraComposition
import TingraPlugInKit

@testable import Tingra

/// The pure preset-management operations behind the preset switcher's add,
/// duplicate, and rename commands (see ARCHITECTURE.md, "Multiple presets in
/// the UI").
@Suite("PresetEdit")
struct PresetEditTests {
    /// A preset holding two named shots, standing in for an operator-authored
    /// preset.
    private func makePreset(id: String = "live", name: String = "Live") -> Preset {
        Preset(
            id: PresetID(rawValue: id),
            name: name,
            shots: [
                Shot(id: ShotID(rawValue: "wide"), name: "Wide", layers: [Layer(input: InputID(rawValue: "cam-1"))]),
                Shot(id: ShotID(rawValue: "tight"), name: "Tight", layers: [Layer(input: InputID(rawValue: "cam-2"))]),
            ]
        )
    }

    @Test("a new preset is empty with a fresh id and a non-empty name")
    func newPresetIsEmpty() {
        let preset = PresetEdit.newPreset()

        #expect(preset.shots.isEmpty)
        #expect(!preset.name.isEmpty)
    }

    @Test("every new preset gets its own fresh id")
    func newPresetsHaveDistinctIDs() {
        #expect(PresetEdit.newPreset().id != PresetEdit.newPreset().id)
    }

    @Test("a duplicate copies the source's shots verbatim — shot ids included — under a fresh preset id")
    func duplicateCopiesShotsUnderFreshID() {
        let source = makePreset()

        let copy = PresetEdit.duplicate(of: source)

        #expect(copy.id != source.id)
        // Shot ids are preserved deliberately: switching between a preset and
        // its copy holds the on-program shot by id match (see
        // Compositor.loadPreset).
        #expect(copy.shots == source.shots)
        // The copy is named after its source, and never collides with it.
        #expect(copy.name.contains(source.name))
        #expect(copy != source)
    }

    @Test("every duplicate gets its own fresh id")
    func duplicatesHaveDistinctIDs() {
        let source = makePreset()
        #expect(PresetEdit.duplicate(of: source).id != PresetEdit.duplicate(of: source).id)
    }

    @Test("renaming replaces the name and preserves the preset's identity and shots")
    func renamingPreservesIdentity() {
        let preset = makePreset()

        let renamed = PresetEdit.renaming(preset, to: "Rehearsal")

        #expect(renamed.name == "Rehearsal")
        #expect(renamed.id == preset.id)
        #expect(renamed.shots == preset.shots)
        #expect(renamed != preset)
    }

    @Test("a rename trims surrounding whitespace")
    func renamingTrimsWhitespace() {
        let renamed = PresetEdit.renaming(makePreset(), to: "  Rehearsal \n")
        #expect(renamed.name == "Rehearsal")
    }

    @Test("a rename to an empty or whitespace-only name returns the preset unchanged")
    func renamingToEmptyNameIsIgnored() {
        let preset = makePreset()

        #expect(PresetEdit.renaming(preset, to: "") == preset)
        #expect(PresetEdit.renaming(preset, to: "   \n") == preset)
    }

    @Test("a rename to the same name returns an equal preset")
    func renamingToSameNameIsEqual() {
        let preset = makePreset()
        #expect(PresetEdit.renaming(preset, to: preset.name) == preset)
    }
}
