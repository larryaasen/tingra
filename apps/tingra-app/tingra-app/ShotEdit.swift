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
    /// The shot is **automatic** (``ShotOrigin/automatic``): the app made it,
    /// and it carries a device's name rather than one the operator chose, so
    /// surfaces listing the operator's own shots leave it out. It is a shot in
    /// every other respect — it persists, it is in the switcher, it can be
    /// taken, and renaming it makes it the operator's.
    ///
    /// - Parameters:
    ///   - input: The input the shot's one layer binds to.
    ///   - name: The shot's user-facing name — the input's own name, so the
    ///     switcher button reads as the thing the operator clicked.
    /// - Returns: The new shot.
    static func shot(showing input: InputID, named name: String) -> Shot {
        LayerTreeEdit.addingLayer(boundTo: input, to: Shot(name: name, origin: .automatic))
    }

    /// The existing shot that shows exactly one input and nothing else — what
    /// staging that input reuses instead of appending a near-duplicate.
    ///
    /// The match is on the **layer tree** being the one ``shot(showing:named:)``
    /// builds: a single layer bound to the input, full frame, fully opaque,
    /// with no effect chain. The name, the id, and the background are
    /// deliberately not compared — a fresh id differs by construction, an
    /// operator may have renamed the shot, and a background cannot be seen
    /// behind a full-frame opaque layer.
    ///
    /// **A shot that merely *contains* the input does not match**, and that is
    /// the rule rather than an oversight (Larry, 2026-08-08): clicking a
    /// camera previews *that camera*, so a shot carrying the camera cropped
    /// under an overlay is a composition the operator did not ask for. Such a
    /// shot is still one click away in the sidebar's shot section and on the
    /// switcher's preview row, which is where a shot is chosen as a shot.
    ///
    /// - Parameters:
    ///   - shots: The shots to search, in switcher order.
    ///   - input: The input the shot must show alone.
    /// - Returns: The first matching shot, or nil when none does.
    static func shot(in shots: [Shot], showingOnly input: InputID) -> Shot? {
        let layers = shot(showing: input, named: "").layers
        return shots.first { $0.layers == layers }
    }

    /// A duplicate of a shot: the source's layer tree, background, and
    /// default transition under a fresh UUID and a "<name> copy" name.
    ///
    /// The copy is **authored** even when its source was automatic: choosing
    /// Duplicate is the operator making a shot, whatever they made it from.
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
            defaultTransition: shot.defaultTransition,
            origin: .authored
        )
    }

    /// Renames a shot, preserving its identity, layer tree, background, and
    /// default transition. The name is trimmed of surrounding whitespace; a
    /// rename to an empty (or whitespace-only) name returns the shot
    /// unchanged — a switcher button needs a label, so the UI never produces
    /// an unnamed shot.
    ///
    /// **A rename makes an automatic shot authored**, and this is the only
    /// promotion there is. An automatic shot carries a device's name because
    /// the app had to call it something; giving it a name of your own is the
    /// operator claiming it, and it is also the only edit that changes what a
    /// list of the operator's shots would read. A rejected rename promotes
    /// nothing — an unchanged shot is unchanged in every respect.
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
            defaultTransition: shot.defaultTransition,
            origin: .authored
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
            defaultTransition: transition,
            origin: shot.origin
        )
    }
}
