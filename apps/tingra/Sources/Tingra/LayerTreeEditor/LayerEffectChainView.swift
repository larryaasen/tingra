//
//  LayerEffectChainView.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// The selected layer's video effect chain, inside the layer-tree editor's
/// inspector (GLOSSARY.md, "Effect", "Effect chain"; ARCHITECTURE.md,
/// "Per-layer video effects").
///
/// The audio chain editor's shape, one service over: a list in **signal
/// order** with per-slot Move Up / Move Down and Remove commands, an Add
/// Effect menu over every registered video effect, and a slider per
/// parameter the effect declares — drawn generically from its
/// `EffectParameter` descriptors, so a third-party effect gets parameter UI
/// without the app knowing it exists.
///
/// Parameter edits apply live, tick by tick, like the frame and opacity
/// sliders; each control reports its own `tap` right where it executes
/// (EVENTS.md, "The `tap` convention").
struct LayerEffectChainView: View {
    /// The engine model whose layer chain this edits.
    @Bindable var model: EngineModel

    /// The selected layer's bottom-to-top index in the shot.
    let layerIndex: Int

    /// The layer's chain, in signal order.
    let effects: [EffectConfiguration]

    /// The chain's body: the heading and slots, then the Add Effect menu.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Effects", comment: "Heading of a channel strip's audio effect chain popover")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(effects.enumerated()), id: \.offset) { index, configuration in
                slotRow(configuration, at: index)
            }

            addEffectMenu
        }
    }

    /// One chain slot: its name, its stack commands, and a slider per
    /// declared parameter.
    private func slotRow(_ configuration: EffectConfiguration, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(model.videoEffectName(for: configuration.effect))
                    .font(.caption)
                Spacer()
                Button {
                    reportSlotTap("layerEffectMoveUp.button", at: index)
                    model.moveLayerEffect(at: index, to: index - 1, ofLayerAt: layerIndex)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .help(Text("Move Up", comment: "Button moving the selected layer toward the top of the stack"))

                Button {
                    reportSlotTap("layerEffectMoveDown.button", at: index)
                    model.moveLayerEffect(at: index, to: index + 1, ofLayerAt: layerIndex)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == effects.count - 1)
                .help(Text("Move Down", comment: "Button moving the selected layer toward the bottom of the stack"))

                Button(role: .destructive) {
                    reportSlotTap("layerEffectRemove.button", at: index)
                    model.removeLayerEffect(at: index, fromLayerAt: layerIndex)
                } label: {
                    Image(systemName: "trash")
                }
                .help(Text("Remove Effect", comment: "Button removing an effect from a channel strip's chain"))
            }

            let parameters = model.videoEffectParameters(for: configuration.effect)
            if parameters.isEmpty {
                // An effect this build has no provider for: its settings
                // persist and its slot holds, but there is nothing to draw.
                Text("Effect not available", comment: "Note on a chain slot whose effect plug-in is not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(parameters, id: \.key) { parameter in
                    parameterSlider(parameter, at: index, in: configuration)
                }
            }
        }
    }

    /// One declared parameter's slider, drawn generically from its
    /// descriptor: the effect's own name for it, its range, and its unit.
    private func parameterSlider(
        _ parameter: EffectParameter,
        at index: Int,
        in configuration: EffectConfiguration
    ) -> some View {
        let value = configuration.parameters[parameter.key]?.doubleValue ?? parameter.defaultValue
        return HStack(spacing: 4) {
            Text(parameter.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Slider(
                value: Binding {
                    value
                } set: { newValue in
                    model.setLayerEffectParameter(
                        newValue, forKey: parameter.key, ofEffectAt: index, atLayer: layerIndex)
                },
                in: parameter.range
            ) { editing in
                guard !editing else { return }
                model.eventBus.tap(
                    "layerEffectParameter.slider",
                    domain: .composition,
                    params: [
                        "layer": .int(layerIndex),
                        "effect": .string(configuration.effect.rawValue),
                        "index": .int(index),
                        "key": .string(parameter.key),
                    ]
                )
            }
        }
    }

    /// The Add Effect menu over every registered video effect, in the
    /// registry's listing order. A new effect appends at its neutral
    /// settings, so adding one never changes the picture until it is
    /// adjusted.
    private var addEffectMenu: some View {
        Menu {
            ForEach(model.videoEffectChoices) { choice in
                Button(choice.name) {
                    model.eventBus.tap(
                        "layerEffectAdd.menu",
                        domain: .composition,
                        params: ["layer": .int(layerIndex), "effect": .string(choice.id.rawValue)]
                    )
                    model.addLayerEffect(choice.id, toLayerAt: layerIndex)
                }
            }
        } label: {
            Text("Add Effect", comment: "Menu adding an effect to a channel strip's chain")
        }
        .disabled(model.videoEffectChoices.isEmpty)
        .fixedSize()
    }

    /// Reports a chain-slot command's `tap` before the model applies it.
    private func reportSlotTap(_ name: String, at index: Int) {
        model.eventBus.tap(
            name,
            domain: .composition,
            params: ["layer": .int(layerIndex), "index": .int(index)]
        )
    }
}
