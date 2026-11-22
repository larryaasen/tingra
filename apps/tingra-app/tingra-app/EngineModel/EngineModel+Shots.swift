//
//  EngineModel+Shots.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAudio
import TingraComposition
import TingraPlugInKit

/// Shots: taking, staging on preview, transitions, fade to black, and editing the shot bank.
extension EngineModel {
    /// Sets the length of the next timed take, clamped to
    /// ``takeTransitionDurationRange`` — so a typed "60" becomes ten seconds
    /// and a stepped-past-zero value stays zero, and the field shows what was
    /// kept.
    ///
    /// - Parameter seconds: The requested length in seconds.
    func setTakeTransitionDuration(_ seconds: TimeInterval) {
        takeTransitionDuration = Self.clampedTakeTransitionDuration(seconds)
    }

    /// The length a requested take duration is kept at: clamped to
    /// ``takeTransitionDurationRange``, and a non-finite value (a parsed
    /// "inf") falls back to the default so the compositor never converts one.
    ///
    /// - Parameter seconds: The requested length in seconds.
    /// - Returns: The length within range.
    static func clampedTakeTransitionDuration(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return Transition.defaultDissolveDuration }
        return min(max(seconds, takeTransitionDurationRange.lowerBound), takeTransitionDurationRange.upperBound)
    }

    /// Takes the whole program off air — or brings it back — over
    /// `duration`, and latches there (GLOSSARY.md, "Fade to black").
    ///
    /// **One control drives both engine surfaces**, and it lives here
    /// because it has to: `TingraComposition` and `TingraAudio` depend on
    /// each other in neither direction, so nothing in the engine can own a
    /// state that spans them. The picture fades on the compositor's program
    /// tick and the master on the mixer's block cadence — two ramps from one
    /// duration, landing within a tick of each other (ARCHITECTURE.md,
    /// "Fade to black").
    ///
    /// **Video and audio are coupled by default**, because Tingra's program
    /// is defined as picture *and* sound: a black picture over live room
    /// audio is dead air, which is the thing the operator reached for this
    /// control to avoid. A video-only fade would be this method without the
    /// mixer line.
    ///
    /// Everything fed from program inherits it by construction — every
    /// streaming destination, any recording, and the app's own program
    /// monitor. Preview, multiview, and the strip meters stay live, so the
    /// operator keeps working behind the fade.
    ///
    /// - Parameters:
    ///   - faded: `true` to take the program down, `false` to bring it up.
    ///   - duration: The ramp length in seconds (default: the
    ///     broadcast-typical half second both engine surfaces default to).
    func setFadeToBlack(_ faded: Bool, duration: TimeInterval = Transition.defaultDissolveDuration) {
        isFadedToBlack = faded
        compositor.setFadeToBlack(faded, duration: duration)
        mixer.setMasterFade(faded, duration: duration)
    }

    /// Takes the shot with the given id to program with the transition the
    /// switcher currently selects — ``takeTransitionKind``, plus ``wipeEdge``
    /// for a wipe; on Default, the taken shot's own ``Shot/defaultTransition``
    /// (GLOSSARY.md, "Transition"). Driven by the shot switcher button; the
    /// compositor renders it starting the next tick.
    ///
    /// Reports no `tap` event itself — the switcher button's action closure
    /// in `ContentView` reports the tap before calling this, right where the
    /// user action is executed (EVENTS.md, "The `tap` convention"); the
    /// compositor's `program.take` event carries the resolved transition.
    ///
    /// - Parameter shotID: The id of the shot to take to program.
    func take(_ shotID: ShotID) {
        // Whether the program was holding a preset switch's snapshot — a shot
        // outside the loaded pool (see ``switchPreset(to:)``) whose inputs
        // can stop once this take replaces it.
        let wasHoldingSnapshot = activeShotID == nil && hasSessionPreset
        let transition = resolvedTransition(for: shotID)
        compositor.take(shotID: shotID, transition: transition)
        activeShotID = compositor.activeShotID
        // A transient shot taken straight to air is the operator's now.
        let discarded = reconcileTransientShots()
        syncTally(changingProgramWith: transition)
        scheduleTallyRefresh(after: transition)
        if wasHoldingSnapshot || discarded {
            Task { await reconfigure() }
        }
    }

    /// Stages a shot on preview — the staging bus, where the next shot is
    /// composed and checked before being taken to program (GLOSSARY.md,
    /// "Preview"). Staging is **not** taking: the program is untouched.
    /// Staging the shot already staged leaves it staged: a desk's preview
    /// bus is a radio row, and pressing the lit button is not a way to turn
    /// preview off (the toggle this once had was dropped 2026-09-07 —
    /// ARCHITECTURE.md, "The preview bus").
    ///
    /// Nothing to autosave: every shot of the active preset already has its
    /// inputs running (``applyConfiguration()`` references the whole pool),
    /// and what is staged is session state that never enters the project
    /// document. The one thing staging can change in the engine is a
    /// **transient** shot losing its place — the shot that was staged, if the
    /// app made it to show a clicked input, is discarded now that the
    /// operator has looked away (``reconcileTransientShots()``), and a
    /// reconfigure stops an input only it referenced.
    ///
    /// Reports no `tap` event itself — the tile's or row's action closure
    /// reports it (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameter shotID: The id of the shot to stage.
    func setPreview(_ shotID: ShotID) {
        compositor.setPreview(shotID: shotID)
        previewShotID = compositor.previewShotID
        if reconcileTransientShots() {
            Task { await reconfigure() }
        }
        syncTally()
    }

    /// Keeps a shot staged whenever the pool has one: if preview is empty
    /// after a bus change, stages ``ShotEdit/previewRefill(in:activeShotID:)``'s
    /// pick — the first shot not on program, else the program shot itself.
    ///
    /// The compositor is honest about an empty preview (a take that replaced
    /// a held snapshot, a removed or preset-switched staged shot, a pool that
    /// was empty until now), and the app's answer is the same as at boot: a
    /// desk's preview bus always has a button lit, so the operator is never
    /// one click further from the next take than they need to be. Only an
    /// empty pool leaves preview empty, and then program is empty too. Called
    /// after every path that mirrors ``previewShotID`` from the compositor,
    /// before the tally is synced, so the lamps show the refill.
    func ensurePreviewStaged() {
        guard previewShotID == nil, let refill = ShotEdit.previewRefill(in: shots, activeShotID: activeShotID)
        else { return }
        compositor.setPreview(shotID: refill)
        previewShotID = compositor.previewShotID
    }

    /// Takes the staged shot to program, swapping the buses: what was on
    /// program lands on preview, ready to be taken back (ARCHITECTURE.md,
    /// "The preview bus"). Uses the same transition the switcher selects as a
    /// direct take does — ``takeTransitionKind``, resolving Default to the
    /// taken shot's own ``Shot/defaultTransition``.
    ///
    /// Does nothing while nothing is staged; the Take button is disabled
    /// then, and the compositor reports the miss as a recoverable error if it
    /// is called anyway.
    ///
    /// Reports no `tap` event itself — the Take button's action closure
    /// reports it; the compositor's `program.take` event carries the resolved
    /// transition and names preview as its source.
    func takePreview() {
        guard let staged = previewShotID else { return }
        performTakePreview(transition: resolvedTransition(for: staged))
    }

    /// Takes the staged shot to program with a **hard cut**, whatever the
    /// switcher's transition picker selects — the switcher's CUT beside its
    /// AUTO, and the one take an operator must be able to reach without first
    /// checking which transition is armed (⇧⌘↩, see ``ProductionShortcut``).
    ///
    /// Identical to ``takePreview()`` in every other respect: the buses swap,
    /// and nothing happens while nothing is staged.
    ///
    /// Reports no `tap` event itself — the Cut button's action closure
    /// reports it (EVENTS.md, "The `tap` convention").
    func cutPreview() {
        guard previewShotID != nil else { return }
        performTakePreview(transition: .cut)
    }

    /// The body both preview takes share: swap the buses over a stated
    /// transition, then bring tally and the held-snapshot bookkeeping back in
    /// line.
    ///
    /// Factored out so ``takePreview()`` and ``cutPreview()`` cannot drift on
    /// anything except the transition — which is the only thing they differ
    /// on.
    ///
    /// - Parameter transition: The transition to take the staged shot with.
    private func performTakePreview(transition: Transition) {
        // The same held-snapshot bookkeeping a direct take does: a snapshot
        // from outside the pool can stop its inputs once this take replaces it.
        let wasHoldingSnapshot = activeShotID == nil && hasSessionPreset
        compositor.takePreview(transition: transition)
        activeShotID = compositor.activeShotID
        // The swap leaves preview empty when program held a snapshot from
        // outside the pool; the refill stages the next shot instead.
        previewShotID = compositor.previewShotID
        ensurePreviewStaged()
        // A transient shot that just went to air is the operator's now.
        let discarded = reconcileTransientShots()
        syncTally(changingProgramWith: transition)
        scheduleTallyRefresh(after: transition)
        if wasHoldingSnapshot || discarded {
            Task { await reconfigure() }
        }
    }

    /// Sets — or, passed nil, clears — a shot's default transition: the
    /// transition the shot is taken with while the switcher's transition
    /// picker is on Default (ARCHITECTURE.md, "Per-shot default
    /// transitions"). A document edit like a rename: it flows through the
    /// compositor's `updateShot` path and autosaves through the
    /// project-document path; the context menu's `tap` event carries the
    /// observability (EVENTS.md).
    ///
    /// - Parameters:
    ///   - transition: The new default transition, or nil for none (an
    ///     unresolved take is a cut).
    ///   - shotID: The id of the shot to edit.
    func setShotDefaultTransition(_ transition: Transition?, for shotID: ShotID) {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        var edited = ShotEdit.settingDefaultTransition(transition, of: shots[index])
        guard edited != shots[index] else { return }
        // Choosing a transition for a transient shot is an act of authorship.
        edited = ShotEdit.claiming(edited)
        shots[index] = edited
        compositor.updateShot(edited)
        scheduleAutosave()
    }

    /// Adds a new, empty user-authored shot (fresh UUID, localized default
    /// name, no layers over black — see ``ShotEdit/newShot()``) at the end of
    /// the switcher order. Adding is not taking: the program is untouched
    /// until the operator takes the new shot (ARCHITECTURE.md, "Shot
    /// management"). The edit autosaves through the project-document path.
    func addShot() {
        guard hasSessionPreset else { return }
        let shot = ShotEdit.newShot()
        shots.append(shot)
        compositor.addShot(shot)
        // The first shot of an empty pool is the one preview was waiting for.
        ensurePreviewStaged()
        syncTally()
        scheduleAutosave()
    }

    /// Stages an **input** on the preview bus — what clicking a camera,
    /// display, or video generator row in the sidebar does.
    ///
    /// Preview stages a **shot**, never an input (GLOSSARY.md), so an input
    /// the operator clicks has to be resolved to one. The rule is that
    /// **clicking an input previews that input** — the shot staged shows the
    /// clicked input full frame and nothing else. The operator picked a
    /// camera, not a composition; a shot is what the shot bank and the
    /// sidebar's shot rows are for (Larry, 2026-08-08).
    ///
    /// So the shot reused is the one that *is* that input: a shot whose layer
    /// tree matches the one this method would create — a single full-frame
    /// layer bound to the input, no crop, no overlay, no effect chain. A shot
    /// that merely *contains* the input does not match: a camera shot
    /// carrying a PLUGE overlay and a cropped camera layer is a composition
    /// the operator did not ask for by clicking the camera. When nothing
    /// matches, a **transient** shot is made for the input — appended to the
    /// session pool and the compositor so preview can render it, shown in the
    /// bank as a dashed tile with a Keep button, and **never saved**: it is
    /// promoted to authored when the operator keeps, edits, or airs it, and
    /// discarded the moment it is no longer staged
    /// (``reconcileTransientShots()``; ARCHITECTURE.md, "The shot bank"). That
    /// is what keeps a preset from filling with shots nobody asked for while
    /// a clicked input is still one click from preview.
    ///
    /// Reports no `tap` event itself — the sidebar row's action closure
    /// reports it (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameter input: The input to stage.
    func stagePreview(showing input: InputID) async {
        guard hasSessionPreset else { return }
        // Clicking an input is the one signal that can retry a silent one
        // without a device event: the click says "try this now".
        let retrying = silentInputs.remove(input) != nil
        let frame = newLayerFrame(forInput: input)
        if let existing = ShotEdit.shot(in: shots, showingOnly: input, frame: frame) {
            setPreview(existing.id)
            if retrying { await reconfigure() }
            return
        }
        let shot = ShotEdit.shot(showing: input, named: inputName(for: input), frame: frame)
        shots.append(shot)
        compositor.addShot(shot)
        addStripForMediaSound(input)
        // Staging the new shot is also what discards the transient shot it
        // replaces, if the last click made one.
        setPreview(shot.id)
        // The new shot names an input nothing may be running yet — a camera
        // the show never referenced — so the pass that starts it has to run
        // before its layer can contribute.
        await reconfigure()
    }

    /// Adds an **authored** shot showing one input full frame, named after
    /// it — what dropping a sidebar input on the shot bank, choosing it from
    /// the Add Shot menu, or its row's "Add Shot Showing …" does
    /// (ARCHITECTURE.md, "The shot bank"). The operator asked for this shot
    /// by name, so unlike the transient shot ``stagePreview(showing:)`` makes
    /// it persists like any shot they made. Adding is not taking: the program
    /// is untouched. The edit autosaves through the project-document path and
    /// reconfigures so the input starts.
    ///
    /// - Parameters:
    ///   - input: The input the shot's one layer binds to.
    ///   - index: Where in the switcher order to insert, clamped to the pool;
    ///     nil (the default) appends after the last authored shot — ahead of
    ///     a transient one, which stays last as the bank's dashed tile.
    func addShot(showing input: InputID, at index: Int? = nil) async {
        guard hasSessionPreset else { return }
        let shot = ShotEdit.shot(
            showing: input, named: inputName(for: input), origin: .authored, frame: newLayerFrame(forInput: input))
        let end = shots.firstIndex { $0.origin == .automatic } ?? shots.count
        let position = min(max(index ?? end, 0), shots.count)
        shots.insert(shot, at: position)
        compositor.addShot(shot, at: position)
        addStripForMediaSound(input)
        // The first shot of an empty pool is the one preview was waiting for.
        ensurePreviewStaged()
        syncTally()
        scheduleAutosave()
        await reconfigure()
    }

    /// Keeps a transient shot: promotes it to authored, so it persists and
    /// stays in the bank when the operator stages something else — the Keep
    /// button on a dashed tile (ARCHITECTURE.md, "The shot bank"). A shot
    /// that is already the operator's is unchanged.
    ///
    /// - Parameter shotID: The id of the shot to keep.
    func keepShot(_ shotID: ShotID) {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let claimed = ShotEdit.claiming(shots[index])
        guard claimed != shots[index] else { return }
        shots[index] = claimed
        compositor.updateShot(claimed)
        scheduleAutosave()
    }

    /// Brings the transient shots in line with the buses, after every change
    /// to what is staged or on program: a transient shot **on program** is
    /// promoted — it aired, so it is part of the show whether it got there
    /// by Take, by Cut, or by the compositor cutting to it when the program
    /// shot was removed — and a transient shot on **neither bus** is
    /// discarded from the pool and the compositor, since it existed only to
    /// show a clicked input on preview and the operator has looked away.
    /// A transient shot still staged is left alone.
    ///
    /// - Returns: Whether a shot was discarded — its input may now be
    ///   unreferenced, so the caller reconfigures to stop it.
    @discardableResult
    private func reconcileTransientShots() -> Bool {
        var discarded = false
        for shot in shots where shot.origin == .automatic {
            if shot.id == activeShotID {
                keepShot(shot.id)
            } else if shot.id != previewShotID {
                shots.removeAll { $0.id == shot.id }
                compositor.removeShot(shotID: shot.id)
                discarded = true
            }
        }
        return discarded
    }

    /// Duplicates a shot — the source's layer tree and background under a
    /// fresh UUID and a "<name> copy" name — inserting the copy right after
    /// its source in the switcher order. The duplicate references the same
    /// inputs the source already keeps running, so no reconfigure is needed.
    ///
    /// - Parameter shotID: The id of the shot to duplicate.
    func duplicateShot(_ shotID: ShotID) {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let copy = ShotEdit.duplicate(of: shots[index])
        shots.insert(copy, at: index + 1)
        compositor.addShot(copy, at: index + 1)
        scheduleAutosave()
    }

    /// Renames a shot, preserving its identity and layer tree. A rename to an
    /// empty (or whitespace-only) name is ignored — a switcher button needs a
    /// label (see ``ShotEdit/renaming(_:to:)``). The rename flows through the
    /// compositor's existing `updateShot` path, so the switcher and any
    /// on-program shot reflect it at the next tick.
    ///
    /// - Parameters:
    ///   - shotID: The id of the shot to rename.
    ///   - name: The new user-facing name.
    func renameShot(_ shotID: ShotID, to name: String) {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let renamed = ShotEdit.renaming(shots[index], to: name)
        guard renamed != shots[index] else { return }
        shots[index] = renamed
        compositor.updateShot(renamed)
        scheduleAutosave()
    }

    /// Removes a shot from the active preset. When the removed shot is on
    /// program, the compositor cuts to the adjacent shot — never a dead
    /// program (ARCHITECTURE.md, "Shot management") — so the model re-reads
    /// ``Compositor/activeShotID`` rather than second-guessing which shot
    /// that is. Then reconfigures, so an input referenced only by the removed
    /// shot (and not by the pickers) is stopped.
    ///
    /// - Parameter shotID: The id of the shot to remove.
    func removeShot(_ shotID: ShotID) async {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        shots.remove(at: index)
        compositor.removeShot(shotID: shotID)
        activeShotID = compositor.activeShotID
        // A removed shot cannot stay staged — re-read rather than second-guess
        // which shot preview is left holding, then refill it from the pool.
        previewShotID = compositor.previewShotID
        ensurePreviewStaged()
        // The cut may have landed on a transient shot, which is then aired
        // and kept; one left on neither bus is discarded.
        reconcileTransientShots()
        syncTally()
        scheduleAutosave()
        await reconfigure()
    }

    /// Moves a shot to a new position in the active preset's switcher order —
    /// the shot-management reorder path (ARCHITECTURE.md, "Shot and preset
    /// reordering"). Reordering is **not** taking: the program is untouched,
    /// so no reconfigure is needed — every referenced input is already
    /// running, only the switcher order changes. The move mirrors into the
    /// compositor's pool (which reports the discrete `shot.moved` event) and
    /// autosaves through the project-document path. The destination is clamped
    /// to the switcher's bounds; a move to the shot's current position, or of
    /// an unknown shot, is a no-op.
    ///
    /// - Parameters:
    ///   - shotID: The id of the shot to move.
    ///   - index: The destination position in the switcher order.
    func moveShot(_ shotID: ShotID, to index: Int) {
        guard let from = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let to = min(max(index, 0), shots.count - 1)
        guard to != from else { return }
        let shot = shots.remove(at: from)
        shots.insert(shot, at: to)
        compositor.moveShot(shotID: shotID, to: to)
        // Placing a transient shot in the order is an act of authorship.
        keepShot(shotID)
        scheduleAutosave()
    }

    /// The concrete transition ``take(_:)`` passes to the compositor for the
    /// shot being taken: the switcher's explicitly selected kind (with the
    /// selected edge for a wipe or shader for a shader transition) — or, on
    /// Default, the taken shot's own ``Shot/defaultTransition``, falling back
    /// to a cut for a shot with no default (today's behavior for every shot
    /// that never set one) — every timed kind at the panel's
    /// ``takeTransitionDuration``. Resolution lives here in the app, not the
    /// compositor: the override source is switcher session state, and
    /// `take(shotID:transition:)` keeps its caller-states-the-transition
    /// contract (ARCHITECTURE.md, "Per-shot default transitions").
    ///
    /// - Parameter shotID: The id of the shot being taken.
    /// - Returns: The transition to take it with.
    private func resolvedTransition(for shotID: ShotID) -> Transition {
        Self.resolvedTransition(
            kind: takeTransitionKind,
            shotDefault: shots.first { $0.id == shotID }?.defaultTransition,
            wipeEdge: wipeEdge,
            shaderName: shaderName,
            duration: takeTransitionDuration
        )
    }

    /// The pure resolution behind ``resolvedTransition(for:)``, so the rule
    /// is unit-tested without an engine: the kind's transition, or the shot's
    /// default (a cut when it has none), then the panel's duration applied to
    /// whichever timed transition came out.
    ///
    /// - Parameters:
    ///   - kind: The kind armed on the panel.
    ///   - shotDefault: The taken shot's own default transition, if any.
    ///   - wipeEdge: The edge armed for a wipe.
    ///   - shaderName: The shader armed for a shader transition.
    ///   - duration: The panel's take duration in seconds.
    /// - Returns: The transition to take with.
    static func resolvedTransition(
        kind: TakeTransitionKind,
        shotDefault: Transition?,
        wipeEdge: WipeEdge,
        shaderName: TransitionShader,
        duration: TimeInterval
    ) -> Transition {
        let chosen: Transition =
            switch kind {
            case .default: shotDefault ?? .cut
            case .cut: .cut
            case .dissolve: .dissolve
            case .wipe: .wipe(edge: wipeEdge)
            case .shader: .shader(name: shaderName)
            }
        return chosen.withDuration(duration)
    }
}
