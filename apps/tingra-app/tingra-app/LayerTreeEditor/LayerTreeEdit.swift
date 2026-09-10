//
//  LayerTreeEdit.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Foundation
import TingraComposition
import TingraPlugInKit

/// The pure layer-tree edit operations the editor applies to a shot: add,
/// remove, and reorder layers, and adjust a layer's frame and opacity
/// (GLOSSARY.md, "Layer tree"). Each operation returns a new `Shot` with the
/// same identity (id, name, background) and the edited layers — `Shot` and
/// `Layer` stay plain value types, so the editor is unit-testable without the
/// compositor, any UI, or hardware (like ``ProgramLayout``).
///
/// Layers are addressed by their index in the shot's bottom-to-top `layers`
/// array — a `Layer` is a plain `Codable` value with no identity of its own
/// (GLOSSARY.md: "Layers stack in a defined order"; the order *is* the
/// identity). An out-of-range index returns the shot unchanged (never a
/// crash — a stale editor selection is recoverable).
enum LayerTreeEdit {
    /// Which way a layer moves through the stack.
    enum StackDirection {
        /// Toward the top of the stack (drawn later, in front).
        case up

        /// Toward the bottom of the stack (drawn earlier, behind).
        case down
    }

    /// Adds a layer bound to the given input on **top** of the shot's stack,
    /// full-frame and fully opaque — you add a layer to see it, so it lands
    /// in front with the default placement.
    ///
    /// - Parameters:
    ///   - input: The input whose latest frame fills the new layer.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with the new layer appended on top.
    static func addingLayer(boundTo input: InputID, to shot: Shot) -> Shot {
        replacingLayers(of: shot, with: shot.layers + [Layer(input: input)])
    }

    /// Removes the layer at the given bottom-to-top index.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - shot: The shot to edit.
    /// - Returns: The shot without that layer, or unchanged if the index is
    ///   out of range.
    static func removingLayer(at index: Int, from shot: Shot) -> Shot {
        guard shot.layers.indices.contains(index) else { return shot }
        var layers = shot.layers
        layers.remove(at: index)
        return replacingLayers(of: shot, with: layers)
    }

    /// Moves the layer at the given bottom-to-top index one step through the
    /// stack.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - direction: Which way it moves — ``StackDirection/up`` swaps it
    ///     with the layer above, ``StackDirection/down`` with the one below.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with the two layers swapped, or unchanged if the
    ///   index is out of range or already at that end of the stack.
    static func movingLayer(at index: Int, _ direction: StackDirection, in shot: Shot) -> Shot {
        let destination = direction == .up ? index + 1 : index - 1
        guard shot.layers.indices.contains(index), shot.layers.indices.contains(destination) else { return shot }
        var layers = shot.layers
        layers.swapAt(index, destination)
        return replacingLayers(of: shot, with: layers)
    }

    /// Replaces the frame of the layer at the given bottom-to-top index —
    /// the layer's position and size in normalized, top-left-origin program
    /// coordinates (see `Layer.frame`).
    ///
    /// - Parameters:
    ///   - frame: The new normalized destination rect.
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with that layer's frame replaced, or unchanged if
    ///   the index is out of range.
    static func settingFrame(_ frame: CGRect, ofLayerAt index: Int, in shot: Shot) -> Shot {
        guard shot.layers.indices.contains(index) else { return shot }
        var layers = shot.layers
        layers[index] = Layer(
            input: layers[index].input, frame: frame, opacity: layers[index].opacity,
            effects: layers[index].effects)
        return replacingLayers(of: shot, with: layers)
    }

    /// Replaces the opacity of the layer at the given bottom-to-top index.
    ///
    /// - Parameters:
    ///   - opacity: The new opacity, `0`...`1` (the renderer clamps).
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with that layer's opacity replaced, or unchanged
    ///   if the index is out of range.
    static func settingOpacity(_ opacity: Double, ofLayerAt index: Int, in shot: Shot) -> Shot {
        guard shot.layers.indices.contains(index) else { return shot }
        var layers = shot.layers
        layers[index] = Layer(
            input: layers[index].input, frame: layers[index].frame, opacity: opacity,
            effects: layers[index].effects)
        return replacingLayers(of: shot, with: layers)
    }

    /// Rebinds every layer bound to one input to another, keeping each
    /// layer's frame and opacity — how a picker's selection change recasts
    /// which device plays a role across the persisted shots without
    /// discarding layer edits (see ARCHITECTURE.md, "Project save/load").
    ///
    /// - Parameters:
    ///   - previous: The input the layers are currently bound to.
    ///   - input: The input they rebind to.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with every matching layer rebound, or unchanged
    ///   when no layer is bound to `previous`.
    static func rebindingLayers(boundTo previous: InputID, to input: InputID, in shot: Shot) -> Shot {
        let layers = shot.layers.map { layer in
            layer.input == previous
                ? Layer(input: input, frame: layer.frame, opacity: layer.opacity, effects: layer.effects) : layer
        }
        return replacingLayers(of: shot, with: layers)
    }

    /// Appends an effect to a layer's chain at its neutral settings (an
    /// empty payload — every parameter at its declared default), so a
    /// freshly added effect never changes the picture until it is
    /// adjusted (ARCHITECTURE.md, "Per-layer video effects").
    ///
    /// - Parameters:
    ///   - effect: The effect to append.
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with the effect appended to that layer's chain,
    ///   or unchanged if the index is out of range.
    static func addingEffect(_ effect: EffectID, toLayerAt index: Int, in shot: Shot) -> Shot {
        guard shot.layers.indices.contains(index) else { return shot }
        var layers = shot.layers
        var chain = layers[index].effects ?? []
        chain.append(EffectConfiguration(effect: effect))
        layers[index] = replacingChain(of: layers[index], with: chain)
        return replacingLayers(of: shot, with: layers)
    }

    /// Removes one slot from a layer's chain. A chain emptied this way
    /// stays authored-empty rather than reverting to unauthored — the
    /// operator removed the effects, which is not the same as never
    /// having had any.
    ///
    /// - Parameters:
    ///   - effectIndex: The chain slot to remove.
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with that slot removed, or unchanged if either
    ///   index is out of range.
    static func removingEffect(at effectIndex: Int, fromLayerAt index: Int, in shot: Shot) -> Shot {
        guard shot.layers.indices.contains(index) else { return shot }
        var chain = shot.layers[index].effects ?? []
        guard chain.indices.contains(effectIndex) else { return shot }
        chain.remove(at: effectIndex)
        var layers = shot.layers
        layers[index] = replacingChain(of: layers[index], with: chain)
        return replacingLayers(of: shot, with: layers)
    }

    /// Moves one slot of a layer's chain. Order is signal order, so a move
    /// is a visible processing change. The destination is clamped to the
    /// chain's bounds; a move to the slot's current position is a no-op.
    ///
    /// - Parameters:
    ///   - effectIndex: The chain slot to move.
    ///   - destination: The destination position in the chain.
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with that slot moved, or unchanged if either
    ///   index is out of range or the move is a no-op.
    static func movingEffect(at effectIndex: Int, to destination: Int, ofLayerAt index: Int, in shot: Shot) -> Shot {
        guard shot.layers.indices.contains(index) else { return shot }
        var chain = shot.layers[index].effects ?? []
        guard chain.indices.contains(effectIndex) else { return shot }
        let to = min(max(destination, 0), chain.count - 1)
        guard to != effectIndex else { return shot }
        let configuration = chain.remove(at: effectIndex)
        chain.insert(configuration, at: to)
        var layers = shot.layers
        layers[index] = replacingChain(of: layers[index], with: chain)
        return replacingLayers(of: shot, with: layers)
    }

    /// Sets one numeric parameter of one slot in a layer's chain, keeping
    /// the slot's other parameters — the gesture-rate edit a chain slider
    /// makes.
    ///
    /// - Parameters:
    ///   - value: The parameter's new value.
    ///   - key: The parameter's persisted key.
    ///   - effectIndex: The chain slot whose parameter changes.
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with that parameter set, or unchanged if either
    ///   index is out of range.
    static func settingEffectParameter(
        _ value: Double,
        forKey key: String,
        ofEffectAt effectIndex: Int,
        ofLayerAt index: Int,
        in shot: Shot
    ) -> Shot {
        settingEffectParameter(.double(value), forKey: key, ofEffectAt: effectIndex, ofLayerAt: index, in: shot)
    }

    /// Sets one parameter of one slot in a layer's chain to any payload
    /// value — a number from a slider or a color object from a color well
    /// — keeping the slot's other parameters.
    ///
    /// - Parameters:
    ///   - value: The parameter's new payload value.
    ///   - key: The parameter's persisted key.
    ///   - effectIndex: The chain slot whose parameter changes.
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with that parameter set, or unchanged if either
    ///   index is out of range.
    static func settingEffectParameter(
        _ value: JSONValue,
        forKey key: String,
        ofEffectAt effectIndex: Int,
        ofLayerAt index: Int,
        in shot: Shot
    ) -> Shot {
        guard shot.layers.indices.contains(index) else { return shot }
        var chain = shot.layers[index].effects ?? []
        guard chain.indices.contains(effectIndex) else { return shot }
        var parameters = chain[effectIndex].parameters
        parameters[key] = value
        chain[effectIndex] = EffectConfiguration(effect: chain[effectIndex].effect, parameters: parameters)
        var layers = shot.layers
        layers[index] = replacingChain(of: layers[index], with: chain)
        return replacingLayers(of: shot, with: layers)
    }

    /// Rebuilds a layer with an edited effect chain, preserving its input,
    /// frame, and opacity.
    /// Moves the layer at the given bottom-to-top index to another position
    /// in the stack — the Layer menu's Bring to Front / Send to Back, and any
    /// other jump longer than one step (``movingLayer(at:_:in:)`` is the
    /// one-step form the chevrons used).
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - destination: The index it lands at, clamped to the stack.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with the layer moved, or unchanged if the index is
    ///   out of range or the destination is where it already is.
    static func movingLayer(at index: Int, to destination: Int, in shot: Shot) -> Shot {
        guard shot.layers.indices.contains(index) else { return shot }
        let to = min(max(destination, 0), shot.layers.count - 1)
        guard to != index else { return shot }
        var layers = shot.layers
        let layer = layers.remove(at: index)
        layers.insert(layer, at: to)
        return replacingLayers(of: shot, with: layers)
    }

    /// Applies a drag-to-reorder from the editor's list, which shows the
    /// stack **topmost first**: the offsets are the list's displayed
    /// positions, in the shape `onMove` hands over (`fromOffsets` /
    /// `toOffset`), and the move is made on the reversed array so the
    /// list's own semantics hold exactly — then reversed back into the
    /// bottom-to-top order the shot stores.
    ///
    /// - Parameters:
    ///   - source: The displayed positions of the rows being dragged.
    ///   - destination: The displayed position they are dropped at
    ///     (`0...count`, the gap before that row).
    ///   - shot: The shot to edit.
    /// - Returns: The shot with the rows moved, or unchanged if any offset is
    ///   out of range.
    static func movingLayers(fromDisplayed source: IndexSet, toDisplayed destination: Int, in shot: Shot) -> Shot {
        var displayed = Array(shot.layers.reversed())
        guard source.allSatisfy(displayed.indices.contains), (0...displayed.count).contains(destination) else {
            return shot
        }
        // `onMove`'s semantics by hand, so this file stays framework-free:
        // the dragged rows land before the row that was at `destination`.
        let moving = source.map { displayed[$0] }
        let removedBefore = source.count { $0 < destination }
        for offset in source.reversed() {
            displayed.remove(at: offset)
        }
        displayed.insert(contentsOf: moving, at: destination - removedBefore)
        return replacingLayers(of: shot, with: displayed.reversed())
    }

    /// Rebinds the layer at the given bottom-to-top index to another input,
    /// keeping its frame, opacity, and effect chain — the inspector's Input
    /// popup (ARCHITECTURE.md, "The layer inspector"). Unlike
    /// ``rebindingLayers(boundTo:to:in:)``, which recasts every layer of a
    /// device across the preset, this touches one layer of one shot.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - input: The input the layer binds to from now on.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with the layer rebound, or unchanged if the index
    ///   is out of range or the input is the one it already has.
    static func rebindingLayer(at index: Int, to input: InputID, in shot: Shot) -> Shot {
        guard shot.layers.indices.contains(index), shot.layers[index].input != input else { return shot }
        var layers = shot.layers
        let layer = layers[index]
        layers[index] = Layer(input: input, frame: layer.frame, opacity: layer.opacity, effects: layer.effects)
        return replacingLayers(of: shot, with: layers)
    }

    /// Duplicates the layer at the given bottom-to-top index, placing the
    /// copy **directly above** it — the same input, frame, opacity, and
    /// effect chain, which is what Keynote's Duplicate does with an object:
    /// the copy is where the original is, ready to be dragged aside.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - shot: The shot to edit.
    /// - Returns: The shot with the copy inserted, or unchanged if the index
    ///   is out of range.
    static func duplicatingLayer(at index: Int, in shot: Shot) -> Shot {
        guard shot.layers.indices.contains(index) else { return shot }
        var layers = shot.layers
        layers.insert(layers[index], at: index + 1)
        return replacingLayers(of: shot, with: layers)
    }

    private static func replacingChain(of layer: Layer, with chain: [EffectConfiguration]) -> Layer {
        Layer(input: layer.input, frame: layer.frame, opacity: layer.opacity, effects: chain)
    }

    /// Rebuilds the shot with an edited layer tree, preserving its identity —
    /// the id, name, background, default transition, and origin never change
    /// under a layer-tree edit.
    ///
    /// **Origin is carried explicitly rather than left to the initializer's
    /// default**, which would quietly promote every automatic shot to authored
    /// the first time anything touched its layers — including the camera
    /// picker's rebind, which is not an act of authorship at all.
    private static func replacingLayers(of shot: Shot, with layers: [Layer]) -> Shot {
        Shot(
            id: shot.id,
            name: shot.name,
            layers: layers,
            background: shot.background,
            defaultTransition: shot.defaultTransition,
            origin: shot.origin
        )
    }
}
