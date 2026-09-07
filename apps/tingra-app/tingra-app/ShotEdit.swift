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
/// preset: create a new shot, duplicate one, rename one, claim a transient
/// one, and pick which shots a save writes (removal needs no transform — the
/// shot simply leaves the array). Each operation returns a
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
    /// Preview stages a **shot**, never an input (GLOSSARY.md, "Preview",
    /// "Shot"), so an input the operator clicks in the sidebar has to be
    /// resolved to one — and an input the operator drags onto the shot bank,
    /// or picks from the Add Shot menu, becomes one. A single full-frame
    /// layer over the default opaque-black background is the shot that shows
    /// exactly that input and nothing else.
    ///
    /// The origin says which of those it was. **Automatic** (the default):
    /// the app made it to stage a clicked input, and it is **transient** — it
    /// lives in the session pool while staged, is never written to the
    /// document, and is promoted by ``claiming(_:)`` when the operator keeps,
    /// edits, or airs it (ARCHITECTURE.md, "The shot bank"). **Authored**: the
    /// operator asked for it by name, through a drop or the menu, and it
    /// persists like any shot they made.
    ///
    /// - Parameters:
    ///   - input: The input the shot's one layer binds to.
    ///   - name: The shot's user-facing name — the input's own name, so the
    ///     tile reads as the thing the operator chose.
    ///   - origin: Who made the shot (default: the app, transient).
    /// - Returns: The new shot.
    static func shot(showing input: InputID, named name: String, origin: ShotOrigin = .automatic) -> Shot {
        LayerTreeEdit.addingLayer(boundTo: input, to: Shot(name: name, origin: origin))
    }

    /// The shot as the operator's own: an automatic shot becomes authored,
    /// preserving everything else; an authored shot comes back unchanged.
    ///
    /// The one promotion path for a transient shot — behind Keep, behind a
    /// take that puts it on air, and behind every edit that touches it
    /// (``EngineModel/keepShot(_:)``, ``EngineModel/reconcileTransientShots()``).
    /// A rename promotes through ``renaming(_:to:)`` on its own, since a name
    /// is what it changes.
    ///
    /// - Parameter shot: The shot to claim.
    /// - Returns: The shot, authored.
    static func claiming(_ shot: Shot) -> Shot {
        guard shot.origin != .authored else { return shot }
        return Shot(
            id: shot.id,
            name: shot.name,
            layers: shot.layers,
            background: shot.background,
            defaultTransition: shot.defaultTransition,
            origin: .authored
        )
    }

    /// The shots that belong in the project document: the authored ones, in
    /// their given order.
    ///
    /// A transient shot is session state — it exists to show a clicked input
    /// on preview and is gone when the operator looks away — so it is left
    /// out of every save, the way what is staged is (ARCHITECTURE.md, "The
    /// shot bank"). Applied on load too, so a document written before the
    /// rule loses the automatic shots it carried rather than promoting them.
    ///
    /// - Parameter shots: The session pool.
    /// - Returns: The authored shots.
    static func persistedShots(of shots: [Shot]) -> [Shot] {
        shots.filter { $0.origin == .authored }
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
    /// shot is still one click away in the sidebar's shot section and in the
    /// shot bank, which is where a shot is chosen as a shot.
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
    /// **A rename makes an automatic shot authored.** An automatic shot
    /// carries a device's name because the app had to call it something;
    /// giving it a name of your own is the operator claiming it. It was the
    /// only promotion until transient shots (ARCHITECTURE.md, "The shot
    /// bank"); now every edit claims through ``claiming(_:)``, and a rename
    /// still claims on its own. A rejected rename promotes nothing — an
    /// unchanged shot is unchanged in every respect.
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

    /// The shot to stage when preview would otherwise be empty — the rule
    /// behind "preview always holds a shot while the pool has one"
    /// (ARCHITECTURE.md, "The preview bus").
    ///
    /// A desk's preview bus always has a button lit, and the useful one is
    /// the **next** thing to take: so the first shot in switcher order that
    /// is not on program, falling back to the program shot itself when it is
    /// the only shot (a desk lets an operator line up what is already on
    /// air). Only an empty pool yields nothing, and then program is empty
    /// too.
    ///
    /// - Parameters:
    ///   - shots: The active preset's shots, in switcher order.
    ///   - activeShotID: The shot on program, if any.
    /// - Returns: The id to stage, or nil when there is no shot at all.
    static func previewRefill(in shots: [Shot], activeShotID: ShotID?) -> ShotID? {
        shots.first { $0.id != activeShotID }?.id ?? shots.first?.id
    }
}
