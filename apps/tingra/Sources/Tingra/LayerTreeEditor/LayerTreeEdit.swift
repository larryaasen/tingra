//
//  LayerTreeEdit.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
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
        layers[index] = Layer(input: layers[index].input, frame: frame, opacity: layers[index].opacity)
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
        layers[index] = Layer(input: layers[index].input, frame: layers[index].frame, opacity: opacity)
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
            layer.input == previous ? Layer(input: input, frame: layer.frame, opacity: layer.opacity) : layer
        }
        return replacingLayers(of: shot, with: layers)
    }

    /// Rebuilds the shot with an edited layer tree, preserving its identity —
    /// the id, name, and background never change under a layer-tree edit.
    private static func replacingLayers(of shot: Shot, with layers: [Layer]) -> Shot {
        Shot(id: shot.id, name: shot.name, layers: layers, background: shot.background)
    }
}
