//
//  LayerTreeEditTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Testing
import TingraComposition
import TingraPlugInKit

@testable import Tingra

@Suite("LayerTreeEdit")
struct LayerTreeEditTests {
    private let display = InputID(rawValue: "display-1")
    private let camera = InputID(rawValue: "camera-1")
    private let extra = InputID(rawValue: "camera-2")

    /// A two-layer shot (display on the bottom, camera inset on top) the
    /// edits operate on.
    private var shot: Shot {
        Shot(
            id: ShotID(rawValue: "pip"),
            name: "Picture in Picture",
            layers: ProgramLayout.layers(displayID: display, cameraID: camera),
            background: BackgroundColor(red: 0.1, green: 0.2, blue: 0.3),
            defaultTransition: .dissolve
        )
    }

    @Test("adding a layer puts it on top of the stack, full-frame and opaque")
    func addingLayerLandsOnTop() {
        let edited = LayerTreeEdit.addingLayer(boundTo: extra, to: shot)
        #expect(edited.layers.count == 3)
        #expect(edited.layers.last == Layer(input: extra))
        // The existing layers are untouched beneath it.
        #expect(Array(edited.layers.prefix(2)) == shot.layers)
    }

    @Test("removing a layer drops exactly that layer")
    func removingLayer() {
        let edited = LayerTreeEdit.removingLayer(at: 0, from: shot)
        #expect(edited.layers == [shot.layers[1]])
    }

    @Test("removing at an out-of-range index returns the shot unchanged")
    func removingOutOfRange() {
        #expect(LayerTreeEdit.removingLayer(at: 2, from: shot) == shot)
        #expect(LayerTreeEdit.removingLayer(at: -1, from: shot) == shot)
    }

    @Test("moving a layer up swaps it with the layer above")
    func movingLayerUp() {
        let edited = LayerTreeEdit.movingLayer(at: 0, .up, in: shot)
        #expect(edited.layers == [shot.layers[1], shot.layers[0]])
    }

    @Test("moving a layer down swaps it with the layer below")
    func movingLayerDown() {
        let edited = LayerTreeEdit.movingLayer(at: 1, .down, in: shot)
        #expect(edited.layers == [shot.layers[1], shot.layers[0]])
    }

    @Test("moving past either end of the stack returns the shot unchanged")
    func movingPastEnds() {
        #expect(LayerTreeEdit.movingLayer(at: 1, .up, in: shot) == shot)
        #expect(LayerTreeEdit.movingLayer(at: 0, .down, in: shot) == shot)
        #expect(LayerTreeEdit.movingLayer(at: 5, .up, in: shot) == shot)
    }

    @Test("setting a layer's frame replaces only that layer's placement")
    func settingFrame() {
        let frame = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let edited = LayerTreeEdit.settingFrame(frame, ofLayerAt: 0, in: shot)
        #expect(edited.layers[0] == Layer(input: display, frame: frame))
        #expect(edited.layers[1] == shot.layers[1])
    }

    @Test("setting a layer's opacity replaces only that layer's opacity")
    func settingOpacity() {
        let edited = LayerTreeEdit.settingOpacity(0.4, ofLayerAt: 1, in: shot)
        #expect(edited.layers[1] == Layer(input: camera, frame: shot.layers[1].frame, opacity: 0.4))
        #expect(edited.layers[0] == shot.layers[0])
    }

    @Test("setting frame or opacity at an out-of-range index returns the shot unchanged")
    func settingOutOfRange() {
        #expect(LayerTreeEdit.settingFrame(.zero, ofLayerAt: 9, in: shot) == shot)
        #expect(LayerTreeEdit.settingOpacity(0, ofLayerAt: 9, in: shot) == shot)
    }

    @Test("rebinding layers moves every matching layer to the new input, keeping frame and opacity")
    func rebindingLayers() {
        let edited = LayerTreeEdit.rebindingLayers(boundTo: camera, to: extra, in: shot)
        #expect(edited.layers[0] == shot.layers[0])
        #expect(edited.layers[1].input == extra)
        #expect(edited.layers[1].frame == shot.layers[1].frame)
        #expect(edited.layers[1].opacity == shot.layers[1].opacity)
    }

    @Test("rebinding rebinds every layer bound to the input, not just the first")
    func rebindingAllMatchingLayers() {
        let doubled = LayerTreeEdit.addingLayer(boundTo: camera, to: shot)
        let edited = LayerTreeEdit.rebindingLayers(boundTo: camera, to: extra, in: doubled)
        #expect(edited.layers.map(\.input) == [display, extra, extra])
    }

    @Test("rebinding an input no layer is bound to returns the shot unchanged")
    func rebindingUnboundInput() {
        #expect(LayerTreeEdit.rebindingLayers(boundTo: extra, to: camera, in: shot) == shot)
    }

    @Test("every edit preserves the shot's identity — id, name, background, and default transition never change")
    func editsPreserveShotIdentity() {
        let edits: [Shot] = [
            LayerTreeEdit.addingLayer(boundTo: extra, to: shot),
            LayerTreeEdit.removingLayer(at: 0, from: shot),
            LayerTreeEdit.movingLayer(at: 0, .up, in: shot),
            LayerTreeEdit.settingFrame(.zero, ofLayerAt: 0, in: shot),
            LayerTreeEdit.settingOpacity(0.5, ofLayerAt: 0, in: shot),
            LayerTreeEdit.rebindingLayers(boundTo: camera, to: extra, in: shot),
        ]
        for edited in edits {
            #expect(edited.id == shot.id)
            #expect(edited.name == shot.name)
            #expect(edited.background == shot.background)
            #expect(edited.defaultTransition == shot.defaultTransition)
        }
    }
}

@Suite("LayerTreeEdit effect chains")
struct LayerTreeEditEffectTests {
    /// A shot with one layer, for chain edits.
    private var shot: Shot {
        Shot(id: ShotID(rawValue: "shot"), name: "Shot", layers: [Layer(input: InputID(rawValue: "camera"))])
    }

    /// A chained configuration for the given effect id.
    private func configuration(_ id: String) -> EffectConfiguration {
        EffectConfiguration(effect: EffectID(rawValue: id))
    }

    @Test("adding an effect appends it at its neutral settings, so the picture is unchanged until adjusted")
    func addingEffectAppendsNeutral() {
        let edited = LayerTreeEdit.addingEffect(EffectID(rawValue: "blur"), toLayerAt: 0, in: shot)
        #expect(edited.layers[0].effects?.count == 1)
        #expect(edited.layers[0].effects?.first?.effect == EffectID(rawValue: "blur"))
        #expect(edited.layers[0].effects?.first?.parameters.isEmpty == true)
    }

    @Test("adding an effect appends after the existing chain — order is signal order")
    func addingEffectAppendsInSignalOrder() {
        var edited = LayerTreeEdit.addingEffect(EffectID(rawValue: "colorAdjust"), toLayerAt: 0, in: shot)
        edited = LayerTreeEdit.addingEffect(EffectID(rawValue: "blur"), toLayerAt: 0, in: edited)
        #expect(edited.layers[0].effects?.map(\.effect.rawValue) == ["colorAdjust", "blur"])
    }

    @Test("adding to an out-of-range layer leaves the shot unchanged")
    func addingEffectToUnknownLayerIsANoOp() {
        let original = shot
        #expect(LayerTreeEdit.addingEffect(EffectID(rawValue: "blur"), toLayerAt: 5, in: original) == original)
    }

    @Test("removing an effect drops just that slot")
    func removingEffectDropsTheSlot() {
        let chained = Shot(
            id: ShotID(rawValue: "shot"),
            layers: [
                Layer(
                    input: InputID(rawValue: "camera"),
                    effects: [configuration("colorAdjust"), configuration("blur")])
            ]
        )
        let edited = LayerTreeEdit.removingEffect(at: 0, fromLayerAt: 0, in: chained)
        #expect(edited.layers[0].effects?.map(\.effect.rawValue) == ["blur"])
    }

    @Test("removing the last effect leaves an authored-empty chain, not an unauthored one")
    func removingLastEffectLeavesAuthoredEmpty() {
        let chained = Shot(
            id: ShotID(rawValue: "shot"),
            layers: [Layer(input: InputID(rawValue: "camera"), effects: [configuration("blur")])]
        )
        let edited = LayerTreeEdit.removingEffect(at: 0, fromLayerAt: 0, in: chained)
        #expect(edited.layers[0].effects?.isEmpty == true)
    }

    @Test("removing an out-of-range slot leaves the shot unchanged")
    func removingUnknownEffectIsANoOp() {
        let chained = Shot(
            id: ShotID(rawValue: "shot"),
            layers: [Layer(input: InputID(rawValue: "camera"), effects: [configuration("blur")])]
        )
        #expect(LayerTreeEdit.removingEffect(at: 4, fromLayerAt: 0, in: chained) == chained)
    }

    @Test("moving an effect reorders the chain, and a move to its own position is a no-op")
    func movingEffectReorders() {
        let chained = Shot(
            id: ShotID(rawValue: "shot"),
            layers: [
                Layer(
                    input: InputID(rawValue: "camera"),
                    effects: [configuration("colorAdjust"), configuration("blur")])
            ]
        )
        let moved = LayerTreeEdit.movingEffect(at: 1, to: 0, ofLayerAt: 0, in: chained)
        #expect(moved.layers[0].effects?.map(\.effect.rawValue) == ["blur", "colorAdjust"])
        #expect(LayerTreeEdit.movingEffect(at: 0, to: 0, ofLayerAt: 0, in: chained) == chained)
    }

    @Test("a move destination beyond the chain is clamped to its bounds")
    func movingEffectClampsDestination() {
        let chained = Shot(
            id: ShotID(rawValue: "shot"),
            layers: [
                Layer(
                    input: InputID(rawValue: "camera"),
                    effects: [configuration("colorAdjust"), configuration("blur")])
            ]
        )
        let moved = LayerTreeEdit.movingEffect(at: 0, to: 99, ofLayerAt: 0, in: chained)
        #expect(moved.layers[0].effects?.map(\.effect.rawValue) == ["blur", "colorAdjust"])
    }

    @Test("setting a parameter keeps the slot's other parameters and the chain's order")
    func settingParameterKeepsTheRest() {
        let chained = Shot(
            id: ShotID(rawValue: "shot"),
            layers: [
                Layer(
                    input: InputID(rawValue: "camera"),
                    effects: [
                        EffectConfiguration(
                            effect: EffectID(rawValue: "colorAdjust"),
                            parameters: ["brightness": .double(0.2)]),
                        configuration("blur"),
                    ])
            ]
        )
        let edited = LayerTreeEdit.settingEffectParameter(
            0.5, forKey: "saturation", ofEffectAt: 0, ofLayerAt: 0, in: chained)
        let parameters = edited.layers[0].effects?[0].parameters
        #expect(parameters?["brightness"]?.doubleValue == 0.2)
        #expect(parameters?["saturation"]?.doubleValue == 0.5)
        #expect(edited.layers[0].effects?.map(\.effect.rawValue) == ["colorAdjust", "blur"])
    }

    @Test("setting a parameter on an out-of-range slot or layer leaves the shot unchanged")
    func settingParameterOutOfRangeIsANoOp() {
        let original = shot
        #expect(
            LayerTreeEdit.settingEffectParameter(1, forKey: "k", ofEffectAt: 0, ofLayerAt: 0, in: original)
                == original)
        #expect(
            LayerTreeEdit.settingEffectParameter(1, forKey: "k", ofEffectAt: 0, ofLayerAt: 9, in: original)
                == original)
    }

    @Test("the frame, opacity, and rebind edits all preserve a layer's effect chain")
    func otherEditsPreserveTheChain() {
        let chain = [configuration("blur")]
        let chained = Shot(
            id: ShotID(rawValue: "shot"),
            layers: [Layer(input: InputID(rawValue: "camera"), effects: chain)]
        )

        let framed = LayerTreeEdit.settingFrame(
            CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), ofLayerAt: 0, in: chained)
        #expect(framed.layers[0].effects == chain)

        let faded = LayerTreeEdit.settingOpacity(0.4, ofLayerAt: 0, in: chained)
        #expect(faded.layers[0].effects == chain)

        let rebound = LayerTreeEdit.rebindingLayers(
            boundTo: InputID(rawValue: "camera"), to: InputID(rawValue: "camera-2"), in: chained)
        #expect(rebound.layers[0].effects == chain)
        #expect(rebound.layers[0].input == InputID(rawValue: "camera-2"))
    }
}
