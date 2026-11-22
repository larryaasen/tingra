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
    /// ``takeTransitionDurationRange``, so the field shows what was kept.
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

    /// Takes the whole program off air, or brings it back, over `duration`,
    /// and latches there (GLOSSARY.md, "Fade to black"). One control drives
    /// both engine surfaces from here, because `TingraComposition` and
    /// `TingraAudio` depend on each other in neither direction: the picture
    /// fades on the compositor's program tick and the master on the mixer's
    /// block cadence, landing within a tick of each other (ARCHITECTURE.md,
    /// "Fade to black"). Video and audio are coupled because a black picture
    /// over live room audio is dead air. Everything fed from program inherits
    /// the fade; preview, multiview, and the strip meters stay live.
    ///
    /// - Parameters:
    ///   - faded: `true` to take the program down, `false` to bring it up.
    ///   - duration: The ramp length in seconds (default: half a second).
    func setFadeToBlack(_ faded: Bool, duration: TimeInterval = Transition.defaultDissolveDuration) {
        isFadedToBlack = faded
        compositor.setFadeToBlack(faded, duration: duration)
        mixer.setMasterFade(faded, duration: duration)
    }

    /// Takes the shot with the given id to program with the transition the
    /// switcher selects: ``takeTransitionKind``, plus ``wipeEdge`` for a
    /// wipe; on Default, the shot's own ``Shot/defaultTransition``
    /// (GLOSSARY.md, "Transition"). Reports no `tap` itself: the switcher
    /// button's action closure does (EVENTS.md, "The `tap` convention"), and
    /// the compositor's `program.take` event carries the resolved transition.
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

    /// Stages a shot on preview, the bus where the next shot is composed and
    /// checked before it is taken (GLOSSARY.md, "Preview"). Staging is not
    /// taking: the program is untouched. Staging the shot already staged
    /// leaves it staged, since a preview bus is a radio row (ARCHITECTURE.md,
    /// "The preview bus"). Nothing to autosave or start: the whole pool's
    /// inputs already run (``applyConfiguration()``), and what is staged is
    /// session state. The one engine change is a transient shot that was
    /// staged being discarded (``reconcileTransientShots()``); a reconfigure
    /// then stops an input only it referenced. The tile's or row's action
    /// closure reports the `tap` (EVENTS.md, "The `tap` convention").
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
    /// pick, the first shot not on program, else the program shot itself, so
    /// the operator is never a click further from the next take than needed.
    /// Only an empty pool leaves preview empty. Called after every path that
    /// mirrors ``previewShotID`` from the compositor, before the tally is
    /// synced, so the lamps show the refill.
    func ensurePreviewStaged() {
        guard previewShotID == nil, let refill = ShotEdit.previewRefill(in: shots, activeShotID: activeShotID)
        else { return }
        compositor.setPreview(shotID: refill)
        previewShotID = compositor.previewShotID
    }

    /// Takes the staged shot to program, swapping the buses: what was on
    /// program lands on preview, ready to be taken back (ARCHITECTURE.md,
    /// "The preview bus"). Uses the transition a direct take does
    /// (``takeTransitionKind``, Default resolving to the shot's own
    /// ``Shot/defaultTransition``). Does nothing while nothing is staged.
    /// Reports no `tap` itself: the Take button's action closure does, and
    /// the compositor's `program.take` event records it as taken from preview.
    func takePreview() {
        guard let staged = previewShotID else { return }
        performTakePreview(transition: resolvedTransition(for: staged))
    }

    /// Takes the staged shot to program with a hard cut, whatever the
    /// transition picker selects: the one take an operator can reach without
    /// checking which transition is armed (⇧⌘↩, see ``ProductionShortcut``).
    /// Otherwise identical to ``takePreview()``. Reports no `tap` itself: the
    /// Cut button's action closure does (EVENTS.md, "The `tap` convention").
    func cutPreview() {
        guard previewShotID != nil else { return }
        performTakePreview(transition: .cut)
    }

    /// The body both preview takes share, so ``takePreview()`` and
    /// ``cutPreview()`` differ only in the transition: swaps the buses, then
    /// brings tally and the held-snapshot bookkeeping back in line.
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

    /// Sets, or clears when passed nil, a shot's default transition: the one
    /// it is taken with while the transition picker is on Default
    /// (ARCHITECTURE.md, "Per-shot default transitions"). A document edit
    /// like a rename; the context menu's `tap` carries the observability
    /// (EVENTS.md).
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

    /// Adds a new, empty user-authored shot (``ShotEdit/newShot()``) at the
    /// end of the switcher order and autosaves. Adding is not taking
    /// (ARCHITECTURE.md, "Shot management").
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

    /// Stages an input on the preview bus: what clicking a camera, display,
    /// or video generator row in the sidebar does. Preview stages a shot,
    /// never an input (GLOSSARY.md), so the click resolves to the shot that
    /// shows that input full frame and nothing else: the operator picked a
    /// camera, not a composition, so a shot that merely contains the input
    /// does not match. When nothing matches, a transient shot is made: in the
    /// session pool and the compositor, never saved, promoted when the
    /// operator keeps, edits, or airs it, and discarded once it is no longer
    /// staged (``reconcileTransientShots()``; ARCHITECTURE.md, "The shot
    /// bank"), so a preset does not fill with shots nobody asked for. Reports
    /// no `tap` itself: the sidebar row's action closure does (EVENTS.md,
    /// "The `tap` convention").
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
        // The new shot may name an input nothing runs yet, so the pass that
        // starts it has to run before its layer can contribute.
        await reconfigure()
    }

    /// Adds an authored shot showing one input full frame, named after it:
    /// what dropping a sidebar input on the shot bank, the Add Shot menu, or
    /// its row's "Add Shot Showing …" does (ARCHITECTURE.md, "The shot
    /// bank"). The operator asked for it, so unlike the transient shot
    /// ``stagePreview(showing:)`` makes, it persists. Adding is not taking.
    /// Autosaves, and reconfigures so the input starts.
    ///
    /// - Parameters:
    ///   - input: The input the shot's one layer binds to.
    ///   - index: Where in the switcher order to insert, clamped to the pool;
    ///     nil appends after the last authored shot, ahead of a transient one.
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
    /// stays in the bank when the operator stages something else: the Keep
    /// button on a dashed tile (ARCHITECTURE.md, "The shot bank").
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

    /// Brings the transient shots in line with the buses after every change
    /// to what is staged or on program. One on program is promoted: it aired,
    /// so it is part of the show however it got there. One on neither bus is
    /// discarded from the pool and the compositor, since it existed only to
    /// show a clicked input on preview. One still staged is left alone.
    ///
    /// - Returns: Whether a shot was discarded, so the caller reconfigures to
    ///   stop an input that may now be unreferenced.
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

    /// Inserts a copy of a shot right after it, under a fresh id and a
    /// "<name> copy" name. No reconfigure: the copy references inputs the
    /// original already keeps running.
    ///
    /// - Parameter shotID: The id of the shot to duplicate.
    func duplicateShot(_ shotID: ShotID) {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let copy = ShotEdit.duplicate(of: shots[index])
        shots.insert(copy, at: index + 1)
        compositor.addShot(copy, at: index + 1)
        scheduleAutosave()
    }

    /// Renames a shot, keeping its identity and layer tree. An empty or
    /// whitespace-only name is ignored (``ShotEdit/renaming(_:to:)``). The
    /// switcher and any on-program shot reflect it at the next tick.
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

    /// Removes a shot from the active preset. When it is on program, the
    /// compositor cuts to the adjacent shot, never a dead program
    /// (ARCHITECTURE.md, "Shot management"), so the model re-reads
    /// ``Compositor/activeShotID``. Then reconfigures, so an input only the
    /// removed shot referenced (and not the pickers) is stopped.
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

    /// Moves a shot in the active preset's switcher order (ARCHITECTURE.md,
    /// "Shot and preset reordering"). Reordering is not taking: the program
    /// is untouched and no reconfigure is needed. The move mirrors into the
    /// compositor's pool, which reports `shot.moved`, and autosaves. The
    /// destination is clamped; a move to the same position, or of an unknown
    /// shot, does nothing.
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

    /// The concrete transition ``take(_:)`` passes to the compositor: the
    /// switcher's selected kind (with the edge for a wipe or the shader for a
    /// shader transition), or on Default the shot's own
    /// ``Shot/defaultTransition``, else a cut, every timed kind at
    /// ``takeTransitionDuration``. Resolved here, not in the compositor: the
    /// override is switcher session state, and `take(shotID:transition:)`
    /// keeps its caller-states-the-transition contract (ARCHITECTURE.md,
    /// "Per-shot default transitions").
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
    /// is unit-tested without an engine.
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
