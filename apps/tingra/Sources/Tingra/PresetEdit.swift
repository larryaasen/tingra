//
//  PresetEdit.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition

/// The pure preset-management operations the preset switcher applies to the
/// project's presets: create a new preset, duplicate one, and rename one
/// (removal needs no transform — the preset simply leaves the array). Each
/// operation returns a plain `Preset` value, so preset management is
/// unit-testable without the compositor, any UI, or hardware — ``ShotEdit``'s
/// design, one level up the `project > preset > shot` hierarchy (see
/// ARCHITECTURE.md, "Multiple presets in the UI").
enum PresetEdit {
    /// A new, empty user-authored preset: a fresh UUID, the localized default
    /// name, no shots — the switcher's Add Shot button populates it, so the
    /// operator composes the preset rather than inheriting an arrangement to
    /// undo (the "new shot starts empty" rule, one level up).
    ///
    /// - Returns: The new preset.
    static func newPreset() -> Preset {
        Preset(
            name: String(localized: "New Preset", bundle: .module, comment: "Default name of a newly added preset"))
    }

    /// A duplicate of a preset: the source's shots copied **verbatim — shot
    /// ids included** — under a fresh `PresetID` and a "<name> copy" name.
    /// Preserving the shot ids is deliberate: switching between a preset and
    /// its copy holds the on-program shot by id match, so the copy is a safe
    /// place to rework a live preset seamlessly (see
    /// ``Compositor/loadPreset(_:)``).
    ///
    /// - Parameter preset: The preset to duplicate.
    /// - Returns: The duplicate.
    static func duplicate(of preset: Preset) -> Preset {
        Preset(
            id: PresetID(),
            name: String(
                localized: "\(preset.name) copy",
                bundle: .module,
                comment: "Name of a duplicated shot or preset; the placeholder is the source's name"
            ),
            shots: preset.shots
        )
    }

    /// Renames a preset, preserving its identity and shots. The name is
    /// trimmed of surrounding whitespace; a rename to an empty (or
    /// whitespace-only) name returns the preset unchanged — a switcher button
    /// needs a label, the same rule as ``ShotEdit/renaming(_:to:)``.
    ///
    /// - Parameters:
    ///   - preset: The preset to rename.
    ///   - name: The new user-facing name.
    /// - Returns: The renamed preset, or the preset unchanged when the
    ///   trimmed name is empty.
    static func renaming(_ preset: Preset, to name: String) -> Preset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return preset }
        return Preset(id: preset.id, name: trimmed, shots: preset.shots)
    }
}
