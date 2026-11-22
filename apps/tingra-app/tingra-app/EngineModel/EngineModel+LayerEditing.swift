//
//  EngineModel+LayerEditing.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// Layer editing: the followed shot's layers, their frames, effects, clipboard, and undo.
extension EngineModel {
    /// The frame a new layer bound to the given input takes: the whole
    /// program, except a media input whose picture size the app read when
    /// the file was added, which is fitted, never stretched (ARCHITECTURE.md,
    /// "Media inputs and the Library's Media tab"). A camera's shape is
    /// unknown until it delivers, so Match Input is its way back.
    ///
    /// - Parameter id: The input the layer binds to.
    /// - Returns: The layer's normalized frame.
    func newLayerFrame(forInput id: InputID) -> CGRect {
        // A window's shape is known from the picker, the same way.
        if let size = windowSizes[id], size.height > 0 {
            return LayerPlacement.fitting(inputAspect: size.width / size.height, in: programAspectRatio)
        }
        guard let item = mediaItem(forInput: id), let size = mediaSizes[item.id], size.height > 0 else {
            return LayerPlacement.fullFrame
        }
        return LayerPlacement.fitting(inputAspect: size.width / size.height, in: programAspectRatio)
    }

    /// The selected layer with its index, or nil when nothing valid is
    /// selected.
    var selectedLayer: (index: Int, layer: Layer)? {
        guard let index = selectedLayerIndex, let layers = editedShot?.shot.layers, layers.indices.contains(index)
        else { return nil }
        return (index, layers[index])
    }

    /// An input's aspect ratio, width over height in pixels, from its latest
    /// frame, or nil before it delivers one. Match Input undoes a stretch with
    /// it (``LayerFrameGesture/matchingAspect(_:inputAspect:programAspect:)``).
    ///
    /// - Parameter id: The input to read.
    /// - Returns: The aspect ratio, or nil.
    func inputAspectRatio(for id: InputID) -> CGFloat? {
        if let extent = inputExtent(for: id) {
            return extent.width / extent.height
        }
        // A window's shape is known from the picker before it captures.
        if let size = windowSizes[id], size.height > 0 {
            return size.width / size.height
        }
        // A media file's shape is known from the file before it plays.
        guard let item = mediaItem(forInput: id), let size = mediaSizes[item.id], size.height > 0 else { return nil }
        return size.width / size.height
    }

    /// A layer's picture aspect ratio, width over height in pixels: the
    /// input's latest frame through the layer's effect chain, so a cropped
    /// layer answers with the crop's proportion (ARCHITECTURE.md, "The Crop
    /// effect"). Nil before the input's first frame, or when the chain leaves
    /// no picture.
    ///
    /// - Parameter layer: The layer to measure.
    /// - Returns: The aspect ratio, or nil.
    func layerPictureAspectRatio(for layer: Layer) -> CGFloat? {
        guard let extent = inputExtent(for: layer.input) else { return nil }
        let picture = LayerFrameGesture.pictureExtent(extent, through: liveEffects(of: layer))
        guard picture.width > 0, picture.height > 0 else { return nil }
        return picture.width / picture.height
    }

    /// A layer's persisted chain as live video effects in signal order. A
    /// slot with no provider is left out, since it renders as pass-through.
    ///
    /// - Parameter layer: The layer whose chain to resolve.
    /// - Returns: The live effects.
    private func liveEffects(of layer: Layer) -> [any VideoEffect] {
        (layer.effects ?? []).compactMap(makeVideoEffect(for:))
    }

    /// One persisted chain slot as a live video effect at its settings, or
    /// nil when this build has no provider for it. Reads the provider
    /// snapshot the renderer's factory reads, so Match Input and the layer
    /// monitor see the chain the program does.
    ///
    /// - Parameter configuration: The chain slot.
    /// - Returns: The live effect, or nil.
    func makeVideoEffect(for configuration: EffectConfiguration) -> (any VideoEffect)? {
        videoEffectProviders.provider(for: configuration.effect)?.makeEffect(parameters: configuration.parameters)
    }

    /// An input's latest frame as a pixel extent at the origin, or nil
    /// while it has not delivered one (or the frame has no height).
    ///
    /// - Parameter id: The input to read.
    private func inputExtent(for id: InputID) -> CGRect? {
        guard let buffer = latestFrame(forInput: id) else { return nil }
        let height = CVPixelBufferGetHeight(buffer)
        guard height > 0 else { return nil }
        return CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: height)
    }

    /// The program's aspect ratio, width over height.
    var programAspectRatio: CGFloat {
        CGFloat(format.width) / CGFloat(format.height)
    }

    /// Marks the start of a gesture-rate edit (a slider or handle drag),
    /// snapshotting the followed shot so the drag undoes as one step.
    func beginLayerGesture() {
        layerGestureSnapshot = editedShot?.shot
    }

    /// Marks the end of a gesture-rate edit, registering the snapshot taken
    /// at its start as the one undo step for the whole drag — or nothing,
    /// when the drag changed nothing.
    ///
    /// - Parameter action: What the gesture did, for the Undo item's name.
    func endLayerGesture(_ action: LayerUndoAction) {
        defer { layerGestureSnapshot = nil }
        guard let before = layerGestureSnapshot, let after = shots.first(where: { $0.id == before.id }), after != before
        else { return }
        registerLayerUndo(restoring: before, action)
    }

    /// Registers one undo step that puts a shot back as it was.
    ///
    /// - Parameters:
    ///   - shot: The shot as it was before the edit.
    ///   - action: What the edit did, for the Undo item's name.
    private func registerLayerUndo(restoring shot: Shot, _ action: LayerUndoAction) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreShot(shot, action) }
        }
        undoManager.setActionName(action.title)
    }

    /// Puts a shot back as it was: the undo of a layer-tree edit, and its
    /// redo, since a restore registers its own inverse. Restored by id,
    /// followed or not, so an undo stays correct after the operator stages
    /// something else; a shot no longer in the pool is left alone. Takes the
    /// edit path, and reconfigures when the set of bound inputs changes.
    ///
    /// - Parameters:
    ///   - shot: The shot to put back.
    ///   - action: What the original edit did, kept for the Redo item.
    private func restoreShot(_ shot: Shot, _ action: LayerUndoAction) {
        guard let index = shots.firstIndex(where: { $0.id == shot.id }) else { return }
        let current = shots[index]
        guard current != shot else { return }
        registerLayerUndo(restoring: current, action)
        eventBus.tap(
            "layerEdit.undo",
            domain: .composition,
            params: ["shot": .string(shot.id.rawValue), "action": .string(action.rawValue)]
        )
        shots[index] = shot
        compositor.updateShot(shot)
        syncTally()
        scheduleAutosave()
        if Set(shot.layers.map(\.input)) != Set(current.layers.map(\.input)) {
            Task { await reconfigure() }
        }
    }

    /// Adds a layer bound to the given input on top of the edited shot's
    /// layer tree, then reconfigures so the input is running: a layer bound
    /// to an input not yet started contributes nothing until its first frame.
    ///
    /// - Parameter input: The input the new layer binds to.
    func addLayer(boundTo input: InputID) async {
        let frame = newLayerFrame(forInput: input)
        applyShotEdit(.addLayer) { LayerTreeEdit.addingLayer(boundTo: input, to: $0, frame: frame) }
        addStripForMediaSound(input)
        await reconfigure()
    }

    /// Removes the layer at the given bottom-to-top index from the edited
    /// shot, then reconfigures so an input no shot references anymore (and
    /// that is not the selected camera or display) is stopped.
    ///
    /// - Parameter index: The layer's index in the shot's `layers` array.
    func removeLayer(at index: Int) async {
        applyShotEdit(.removeLayer) { LayerTreeEdit.removingLayer(at: index, from: $0) }
        await reconfigure()
    }

    /// Moves the layer at the given bottom-to-top index one step through the
    /// edited shot's stack.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - direction: Which way it moves through the stack.
    func moveLayer(at index: Int, _ direction: LayerTreeEdit.StackDirection) {
        applyShotEdit(.reorderLayer) { LayerTreeEdit.movingLayer(at: index, direction, in: $0) }
    }

    /// Moves the layer at the given bottom-to-top index to another position
    /// in the edited shot's stack — the Layer menu's four arrange moves.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - destination: The index it lands at, clamped to the stack.
    func moveLayer(at index: Int, to destination: Int) {
        applyShotEdit(.reorderLayer) { LayerTreeEdit.movingLayer(at: index, to: destination, in: $0) }
    }

    /// Applies a drag-to-reorder from the editor's topmost-first list
    /// (``LayerTreeEdit/movingLayers(fromDisplayed:toDisplayed:in:)``).
    ///
    /// - Parameters:
    ///   - source: The displayed positions of the rows being dragged.
    ///   - destination: The displayed position they are dropped at.
    func moveLayers(fromDisplayed source: IndexSet, toDisplayed destination: Int) {
        applyShotEdit(.reorderLayer) {
            LayerTreeEdit.movingLayers(fromDisplayed: source, toDisplayed: destination, in: $0)
        }
    }

    /// Rebinds the layer at the given bottom-to-top index to another input —
    /// the inspector's Input popup — then reconfigures so the new input runs
    /// and one no shot references anymore stops. One undo step, named
    /// Change Input; the popup's `tap` carries the observability.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - input: The input the layer binds to from now on.
    func rebindLayer(at index: Int, to input: InputID) async {
        applyShotEdit(.changeInput) { LayerTreeEdit.rebindingLayer(at: index, to: input, in: $0) }
        addStripForMediaSound(input)
        // Choosing an input is the operator asking for it now, so a silent
        // one gets another attempt (``silentInputs``).
        silentInputs.remove(input)
        await reconfigure()
    }

    /// Duplicates the layer at the given bottom-to-top index, the copy
    /// directly above it. No reconfigure: the copy binds the input the
    /// original already runs.
    ///
    /// - Parameter index: The layer's index in the shot's `layers` array.
    func duplicateLayer(at index: Int) {
        applyShotEdit(.duplicateLayer) { LayerTreeEdit.duplicatingLayer(at: index, in: $0) }
    }

    /// Whether Edit > Copy and Edit > Cut have a layer to act on: one is
    /// selected in the shot the editor follows.
    var canCopyLayer: Bool {
        selectedLayer != nil
    }

    /// Whether Paste has somewhere to put a layer and a layer to put there:
    /// a shot is followed and the pasteboard holds one. Reads
    /// ``layerPasteboardChangeCount`` so a view drawing a Paste item is
    /// redrawn when the app copies a layer; the pasteboard is not observable.
    ///
    /// - Parameter pasteboard: The pasteboard to look at.
    func canPasteLayer(from pasteboard: NSPasteboard = .general) -> Bool {
        _ = layerPasteboardChangeCount
        return editedShot != nil && LayerPasteboard.containsLayer(pasteboard)
    }

    /// Copies the selected layer to the pasteboard (Edit > Copy). The shot is
    /// untouched, so there is nothing to undo; the `tap` records the
    /// operator's action, since the Edit menu's items are the system's.
    ///
    /// - Parameter pasteboard: The pasteboard to write.
    /// - Returns: Whether a layer was copied.
    @discardableResult
    func copySelectedLayer(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let selection = selectedLayer else { return false }
        return copyLayer(at: selection.index, to: pasteboard, reporting: "layerEdit.copy")
    }

    /// Copies the layer at the given bottom-to-top index of the followed
    /// shot to the pasteboard, selected or not — the layer row's context
    /// menu copies the row it was opened on.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - pasteboard: The pasteboard to write.
    ///   - tapName: The `tap` recording which control asked.
    /// - Returns: Whether a layer was copied.
    @discardableResult
    func copyLayer(at index: Int, to pasteboard: NSPasteboard = .general, reporting tapName: String) -> Bool {
        guard let layers = editedShot?.shot.layers, layers.indices.contains(index) else { return false }
        eventBus.tap(tapName, domain: .composition, params: ["index": .int(index)])
        return writeLayer(layers[index], to: pasteboard)
    }

    /// Cuts the selected layer (Edit > Cut): copies it, removes it from the
    /// followed shot as one undo step, and reconfigures so an input no shot
    /// references anymore stops. A layer that could not be copied stays.
    ///
    /// - Parameter pasteboard: The pasteboard to write.
    func cutSelectedLayer(to pasteboard: NSPasteboard = .general) async {
        guard let selection = selectedLayer else { return }
        eventBus.tap("layerEdit.cut", domain: .composition, params: ["index": .int(selection.index)])
        guard writeLayer(selection.layer, to: pasteboard) else { return }
        selectedLayerIndex = nil
        applyShotEdit(.cutLayer) { LayerTreeEdit.removingLayer(at: selection.index, from: $0) }
        await reconfigure()
    }

    /// Pastes the pasteboard's layer on top of the followed shot (Edit >
    /// Paste) and selects it, then reconfigures so its input is running. A
    /// layer bound to an input this project cannot see lands dormant.
    ///
    /// - Parameters:
    ///   - pasteboard: The pasteboard to read.
    ///   - tapName: The `tap` recording which control asked.
    func pasteLayer(from pasteboard: NSPasteboard = .general, reporting tapName: String = "layerEdit.paste") async {
        guard let followed = editedShot, let layer = LayerPasteboard.layer(on: pasteboard) else { return }
        eventBus.tap(
            tapName,
            domain: .composition,
            params: ["shot": .string(followed.shot.id.rawValue), "input": .string(layer.input.rawValue)]
        )
        applyShotEdit(.pasteLayer) { LayerTreeEdit.pastingLayer(layer, into: $0) }
        selectedLayerIndex = followed.shot.layers.count
        // Pasting a layer is the operator asking for its input now, so a
        // silent one gets another attempt (``silentInputs``).
        silentInputs.remove(layer.input)
        await reconfigure()
    }

    /// Writes a layer to a pasteboard, reporting a layer that could not be
    /// encoded as an `error` event rather than throwing at a menu item.
    ///
    /// - Parameters:
    ///   - layer: The layer to copy.
    ///   - pasteboard: The pasteboard to write.
    /// - Returns: Whether the layer was written.
    private func writeLayer(_ layer: Layer, to pasteboard: NSPasteboard) -> Bool {
        do {
            try LayerPasteboard.write(layer, to: pasteboard)
            layerPasteboardChangeCount = pasteboard.changeCount
            return true
        } catch {
            eventBus.error(
                "layerEdit.copy",
                domain: .composition,
                params: ["error": .string(String(describing: error))]
            )
            return false
        }
    }

    /// Nudges the layer at the given bottom-to-top index one step (an arrow
    /// key on the monitor). Each press is its own undo step.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - direction: The arrow pressed.
    ///   - step: The distance, ``LayerFrameGesture/nudgeStep`` or
    ///     ``LayerFrameGesture/largeNudgeStep``.
    func nudgeLayer(at index: Int, _ direction: LayerFrameGesture.NudgeDirection, by step: CGFloat) {
        applyShotEdit(.moveLayer) { shot in
            guard shot.layers.indices.contains(index) else { return shot }
            let frame = LayerFrameGesture.nudging(shot.layers[index].frame, direction, by: step)
            return LayerTreeEdit.settingFrame(frame, ofLayerAt: index, in: shot)
        }
    }

    /// Sets the frame of the edited shot's layer at the given bottom-to-top
    /// index, in normalized, top-left-origin program coordinates. Applied
    /// live, so a slider drag is visible on program tick by tick.
    ///
    /// - Parameters:
    ///   - frame: The new normalized destination rect.
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - action: What the edit did, for the Undo item's name: a resize by
    ///     default; a position field or a placement anchor says move.
    func setLayerFrame(_ frame: CGRect, at index: Int, as action: LayerUndoAction = .resizeLayer) {
        applyShotEdit(action) { LayerTreeEdit.settingFrame(frame, ofLayerAt: index, in: $0) }
    }

    /// Sets the opacity of the edited shot's layer at the given bottom-to-top
    /// index. Applied live, like ``setLayerFrame(_:at:)``.
    ///
    /// - Parameters:
    ///   - opacity: The new opacity, `0`...`1`.
    ///   - index: The layer's index in the shot's `layers` array.
    func setLayerOpacity(_ opacity: Double, at index: Int) {
        applyShotEdit(.changeOpacity) { LayerTreeEdit.settingOpacity(opacity, ofLayerAt: index, in: $0) }
    }

    /// Appends a video effect to the edited shot's layer at the given index,
    /// at its neutral settings. The Add Effect menu's `tap` carries the
    /// observability (EVENTS.md). Every chain edit, this and the three below,
    /// trims the layer's frame to follow the picture's extent
    /// (``followingPictureExtent(ofLayerAt:from:to:)``).
    ///
    /// - Parameters:
    ///   - effect: The effect to append.
    ///   - index: The layer's index in the shot's `layers` array.
    func addLayerEffect(_ effect: EffectID, toLayerAt index: Int) {
        applyShotEdit(.addEffect) {
            followingPictureExtent(
                ofLayerAt: index, from: $0, to: LayerTreeEdit.addingEffect(effect, toLayerAt: index, in: $0))
        }
    }

    /// Removes one slot from the edited shot's layer's effect chain.
    ///
    /// - Parameters:
    ///   - effectIndex: The chain slot to remove.
    ///   - index: The layer's index in the shot's `layers` array.
    func removeLayerEffect(at effectIndex: Int, fromLayerAt index: Int) {
        applyShotEdit(.removeEffect) {
            followingPictureExtent(
                ofLayerAt: index, from: $0,
                to: LayerTreeEdit.removingEffect(at: effectIndex, fromLayerAt: index, in: $0))
        }
    }

    /// Moves one slot of the edited shot's layer's effect chain — order is
    /// signal order, so a move is a visible processing change.
    ///
    /// - Parameters:
    ///   - effectIndex: The chain slot to move.
    ///   - destination: The destination position in the chain.
    ///   - index: The layer's index in the shot's `layers` array.
    func moveLayerEffect(at effectIndex: Int, to destination: Int, ofLayerAt index: Int) {
        applyShotEdit(.moveEffect) {
            followingPictureExtent(
                ofLayerAt: index, from: $0,
                to: LayerTreeEdit.movingEffect(at: effectIndex, to: destination, ofLayerAt: index, in: $0))
        }
    }

    /// Sets one parameter of one slot in the edited shot's layer's effect
    /// chain, applied live tick by tick. Gesture-rate, so it reports nothing
    /// itself: the slider's drag-end `tap` carries the observability
    /// (EVENTS.md). A crop inset trims the frame with it, so the kept picture
    /// never stretches (``followingPictureExtent(ofLayerAt:from:to:)``).
    ///
    /// - Parameters:
    ///   - value: The parameter's new value.
    ///   - key: The parameter's persisted key.
    ///   - effectIndex: The chain slot whose parameter changes.
    ///   - index: The layer's index in the shot's `layers` array.
    func setLayerEffectParameter(_ value: Double, forKey key: String, ofEffectAt effectIndex: Int, atLayer index: Int) {
        setLayerEffectParameter(.double(value), forKey: key, ofEffectAt: effectIndex, atLayer: index)
    }

    /// Sets one parameter of one slot in the edited shot's layer's effect
    /// chain to any payload value — a color well's color object as well as
    /// a slider's number — under the same gesture-rate rules.
    ///
    /// - Parameters:
    ///   - value: The parameter's new payload value.
    ///   - key: The parameter's persisted key.
    ///   - effectIndex: The chain slot whose parameter changes.
    ///   - index: The layer's index in the shot's `layers` array.
    func setLayerEffectParameter(
        _ value: JSONValue, forKey key: String, ofEffectAt effectIndex: Int, atLayer index: Int
    ) {
        applyShotEdit(.adjustEffect) {
            followingPictureExtent(
                ofLayerAt: index, from: $0,
                to: LayerTreeEdit.settingEffectParameter(
                    value, forKey: key, ofEffectAt: effectIndex, ofLayerAt: index, in: $0))
        }
    }

    /// The edited shot with one layer's frame trimmed to follow its chain:
    /// when a chain edit moves the picture's extent, the frame follows by the
    /// same mapping, so what stays visible keeps its place and scale
    /// (``LayerFrameGesture/following(_:from:to:)``; ARCHITECTURE.md, "A
    /// crop trims the frame"). Measured against the input's latest frame, or
    /// the program's size before one arrives, equivalent for insets that are
    /// fractions of the picture. Runs inside the one edit, so chain and frame
    /// are one undo step.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - before: The shot before the chain edit.
    ///   - after: The shot with the chain edited.
    /// - Returns: `after`, its frame trimmed if the picture's extent moved.
    private func followingPictureExtent(ofLayerAt index: Int, from before: Shot, to after: Shot) -> Shot {
        guard before.layers.indices.contains(index), after.layers.indices.contains(index) else { return after }
        let layer = after.layers[index]
        let extent =
            inputExtent(for: layer.input)
            ?? CGRect(x: 0, y: 0, width: Int(format.width), height: Int(format.height))
        let oldPicture = LayerFrameGesture.pictureExtent(extent, through: liveEffects(of: before.layers[index]))
        let newPicture = LayerFrameGesture.pictureExtent(extent, through: liveEffects(of: layer))
        let frame = LayerFrameGesture.following(layer.frame, from: oldPicture, to: newPicture)
        guard frame != layer.frame else { return after }
        return LayerTreeEdit.settingFrame(frame, ofLayerAt: index, in: after)
    }

    /// The user-facing name of a registered video effect, or the raw
    /// identifier for an effect this build has no provider for.
    ///
    /// - Parameter id: The effect's stable identifier.
    func videoEffectName(for id: EffectID) -> String {
        videoEffectChoices.first { $0.id == id }?.name ?? id.rawValue
    }

    /// The declared parameters of a registered video effect, for the layer
    /// chain editor's sliders — empty for an effect with no provider.
    ///
    /// - Parameter id: The effect's stable identifier.
    func videoEffectParameters(for id: EffectID) -> [Parameter] {
        videoEffectChoices.first { $0.id == id }?.parameters ?? []
    }

    /// Applies one layer-tree edit to the shot the editor follows
    /// (``editedShot``: staged on preview, else on program): stores the
    /// edited shot in the session preset so it survives shot switches
    /// (GLOSSARY.md, "Preset"), pushes it through the compositor, and
    /// schedules the autosave. A no-op edit touches nothing. A real edit
    /// promotes a transient shot, since composing in it is authorship
    /// (ARCHITECTURE.md, "The shot bank"), and registers the shot it replaced
    /// as one undo step, unless a gesture is in progress: its end registers
    /// the whole drag (``endLayerGesture(_:)``).
    ///
    /// - Parameters:
    ///   - action: What the edit does, for the Undo item's name.
    ///   - edit: The pure operation over the followed shot.
    private func applyShotEdit(_ action: LayerUndoAction, _ edit: (Shot) -> Shot) {
        guard let followed = editedShot, let index = shots.firstIndex(where: { $0.id == followed.shot.id })
        else { return }
        var edited = edit(shots[index])
        guard edited != shots[index] else { return }
        if layerGestureSnapshot == nil {
            registerLayerUndo(restoring: shots[index], action)
        }
        edited = ShotEdit.claiming(edited)
        shots[index] = edited
        compositor.updateShot(edited)
        // A layer edit can add, remove, or rebind a layer's input, which is
        // exactly what the tally reads.
        syncTally()
        scheduleAutosave()
    }
}
