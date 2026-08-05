//
//  ShotEdit.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition
import TingraPlugInKit

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
        Shot(name: String(localized: "New Shot", comment: "Default name of a newly added shot"))
    }

    /// A new shot showing one input full frame, named after it.
    ///
    /// What clicking a tile in the main window's input rows needs when no
    /// authored shot shows that input yet: preview stages a **shot**, never an
    /// input (GLOSSARY.md, "Preview", "Shot"), so an input the operator clicks
    /// has to be resolved to one. A single full-frame layer over the default
    /// opaque-black background is the shot that shows exactly that input and
    /// nothing else.
    ///
    /// - Parameters:
    ///   - input: The input the shot's one layer binds to.
    ///   - name: The shot's user-facing name — the input's own name, so the
    ///     switcher button reads as the thing the operator clicked.
    /// - Returns: The new shot.
    static func shot(showing input: InputID, named name: String) -> Shot {
        LayerTreeEdit.addingLayer(boundTo: input, to: Shot(name: name))
    }

    /// A duplicate of a shot: the source's layer tree, background, and
    /// default transition under a fresh UUID and a "<name> copy" name.
    ///
    /// - Parameter shot: The shot to duplicate.
    /// - Returns: The duplicate.
    static func duplicate(of shot: Shot) -> Shot {
        Shot(
            id: ShotID(),
            name: String(
                localized: "\(shot.name) copy",
                comment: "Name of a duplicated shot or preset; the placeholder is the source's name"
            ),
            layers: shot.layers,
            background: shot.background,
            defaultTransition: shot.defaultTransition
        )
    }

    /// Renames a shot, preserving its identity, layer tree, background, and
    /// default transition. The name is trimmed of surrounding whitespace; a
    /// rename to an empty (or whitespace-only) name returns the shot
    /// unchanged — a switcher button needs a label, so the UI never produces
    /// an unnamed shot.
    ///
    /// - Parameters:
    ///   - shot: The shot to rename.
    ///   - name: The new user-facing name.
    /// - Returns: The renamed shot, or the shot unchanged when the trimmed
    ///   name is empty.
    static func renaming(_ shot: Shot, to name: String) -> Shot {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return shot }
        return Shot(
            id: shot.id,
            name: trimmed,
            layers: shot.layers,
            background: shot.background,
            defaultTransition: shot.defaultTransition
        )
    }

    /// Sets — or, passed nil, clears — a shot's default transition,
    /// preserving everything else: the transition the shot is taken with
    /// while the switcher's transition picker is on Default
    /// (ARCHITECTURE.md, "Per-shot default transitions").
    ///
    /// - Parameters:
    ///   - transition: The new default transition, or nil for none (an
    ///     unresolved take is a cut).
    ///   - shot: The shot to edit.
    /// - Returns: The shot with its default transition replaced.
    static func settingDefaultTransition(_ transition: Transition?, of shot: Shot) -> Shot {
        Shot(
            id: shot.id,
            name: shot.name,
            layers: shot.layers,
            background: shot.background,
            defaultTransition: transition
        )
    }
}
