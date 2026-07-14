//
//  ShotEdit.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition

/// The pure shot-management operations the switcher applies to the session
/// preset: create a new shot, duplicate one, and rename one (removal needs no
/// transform — the shot simply leaves the array). Each operation returns a
/// plain `Shot` value, so shot management is unit-testable without the
/// compositor, any UI, or hardware — the same design as ``LayerTreeEdit``
/// (see ARCHITECTURE.md, "Shot management").
///
/// User-authored shots get **fresh UUIDs** (the recorded decision from
/// ARCHITECTURE.md, "Presets and shots"); only ``ProgramLayout``'s seeded
/// shots carry fixed id tokens, and once seeded they are just shots —
/// renameable and removable like any other.
enum ShotEdit {
    /// A new, empty user-authored shot: a fresh UUID, the localized default
    /// name, no layers over the default opaque-black background — the
    /// layer-tree editor adds layers, so the operator composes on a live
    /// canvas rather than inheriting an arrangement to undo.
    ///
    /// - Returns: The new shot.
    static func newShot() -> Shot {
        Shot(name: String(localized: "New Shot", bundle: .module, comment: "Default name of a newly added shot"))
    }

    /// A duplicate of a shot: the source's layer tree and background under a
    /// fresh UUID and a "<name> copy" name.
    ///
    /// - Parameter shot: The shot to duplicate.
    /// - Returns: The duplicate.
    static func duplicate(of shot: Shot) -> Shot {
        Shot(
            id: ShotID(),
            name: String(
                localized: "\(shot.name) copy",
                bundle: .module,
                comment: "Name of a duplicated shot or preset; the placeholder is the source's name"
            ),
            layers: shot.layers,
            background: shot.background
        )
    }

    /// Renames a shot, preserving its identity, layer tree, and background.
    /// The name is trimmed of surrounding whitespace; a rename to an empty
    /// (or whitespace-only) name returns the shot unchanged — a switcher
    /// button needs a label, so the UI never produces an unnamed shot.
    ///
    /// - Parameters:
    ///   - shot: The shot to rename.
    ///   - name: The new user-facing name.
    /// - Returns: The renamed shot, or the shot unchanged when the trimmed
    ///   name is empty.
    static func renaming(_ shot: Shot, to name: String) -> Shot {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return shot }
        return Shot(id: shot.id, name: trimmed, layers: shot.layers, background: shot.background)
    }
}
