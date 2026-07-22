//
//  EffectChainView.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// One channel strip's audio effect chain, edited in a popover off the
/// strip's Effects button (GLOSSARY.md, "Channel strip"; ARCHITECTURE.md,
/// "Audio effect chains").
///
/// The chain is a list in **signal order** — top to bottom is first to
/// last, the layer editor's stack rotated to the audio axis — with an Add
/// Effect menu over every registered audio effect, per-slot Move Up / Move
/// Down and Remove commands, and a slider per parameter the effect
/// declares. The sliders are **generic**: they are drawn from the
/// provider's `EffectParameter` descriptors, so a third-party effect gets
/// parameter UI without the app knowing it exists.
///
/// Parameter edits apply live, tick by tick, like the level and pan
/// sliders; each control reports its own `tap` right where it executes —
/// the menu and buttons on action, the sliders at drag end (EVENTS.md,
/// "The `tap` convention").
struct EffectChainView: View {
    /// The engine model whose chain the popover edits.
    @Bindable var model: EngineModel

    /// The strip whose chain this is.
    let stripID: InputID

    /// The chain's body: the heading, the slots in signal order, then the
    /// Add Effect menu.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Effects", comment: "Heading of a channel strip's audio effect chain popover")
                .font(.headline)

            if chain.isEmpty {
                Text("No effects", comment: "Placeholder in an empty audio effect chain")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(chain.enumerated()), id: \.offset) { index, configuration in
                    slotRow(configuration, at: index)
                }
            }

            addEffectMenu
        }
        .padding()
        .frame(width: 320)
    }

    /// One chain slot: its name, its stack commands, and a slider per
    /// declared parameter.
    private func slotRow(_ configuration: EffectConfiguration, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(model.effectName(for: configuration.effect))
                    .lineLimit(1)
                Spacer()
                Button {
                    reportSlotTap("effectMoveUp.button", at: index)
                    Task { await model.moveEffect(at: index, to: index - 1, onStrip: stripID) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .help(Text("Move Up", comment: "Button moving the selected layer toward the top of the stack"))

                Button {
                    reportSlotTap("effectMoveDown.button", at: index)
                    Task { await model.moveEffect(at: index, to: index + 1, onStrip: stripID) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == chain.count - 1)
                .help(Text("Move Down", comment: "Button moving the selected layer toward the bottom of the stack"))

                Button(role: .destructive) {
                    reportSlotTap("effectRemove.button", at: index)
                    Task { await model.removeEffect(at: index, fromStrip: stripID) }
                } label: {
                    Image(systemName: "trash")
                }
                .help(Text("Remove Effect", comment: "Button removing an effect from a channel strip's chain"))
            }

            let parameters = model.effectParameters(for: configuration.effect)
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
        .padding(.vertical, 2)
    }

    /// One declared parameter's slider, drawn generically from its
    /// descriptor: the effect's own name for it, its range, and its unit.
    private func parameterSlider(
        _ parameter: EffectParameter,
        at index: Int,
        in configuration: EffectConfiguration
    ) -> some View {
        let value = configuration.parameters[parameter.key]?.doubleValue ?? parameter.defaultValue
        return HStack(spacing: 6) {
            Text(parameter.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Slider(
                value: Binding {
                    value
                } set: { newValue in
                    model.setEffectParameter(
                        newValue, forKey: parameter.key, ofEffectAt: index, onStrip: stripID)
                },
                in: parameter.range
            ) { editing in
                guard !editing else { return }
                model.eventBus.tap(
                    "effectParameter.slider",
                    domain: .audio,
                    params: [
                        "id": .string(stripID.rawValue),
                        "effect": .string(configuration.effect.rawValue),
                        "index": .int(index),
                        "key": .string(parameter.key),
                    ]
                )
            }
            .controlSize(.small)

            Text(formatted(value, unit: parameter.unit))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }

    /// The Add Effect menu over every registered audio effect, in the
    /// registry's listing order. A new effect appends at its neutral
    /// settings — added at the end of the chain, the signal-order default.
    private var addEffectMenu: some View {
        Menu {
            ForEach(model.audioEffectChoices) { choice in
                Button(choice.name) {
                    model.eventBus.tap(
                        "effectAdd.menu",
                        domain: .audio,
                        params: ["id": .string(stripID.rawValue), "effect": .string(choice.id.rawValue)]
                    )
                    Task { await model.addEffect(choice.id, toStrip: stripID) }
                }
            }
        } label: {
            Text("Add Effect", comment: "Menu adding an effect to a channel strip's chain")
        }
        .disabled(model.audioEffectChoices.isEmpty)
    }

    /// The strip's current chain, or empty when the strip is gone (a
    /// device removed while its popover was open).
    private var chain: [EffectConfiguration] {
        model.mixerStrips.first { $0.id == stripID }?.effects ?? []
    }

    /// Reports a chain-slot command's `tap` before the model applies it.
    private func reportSlotTap(_ name: String, at index: Int) {
        model.eventBus.tap(
            name,
            domain: .audio,
            params: ["id": .string(stripID.rawValue), "index": .int(index)]
        )
    }

    /// A parameter value with its unit, for the slider's value label — a
    /// whole number for a unit-carrying parameter (decibels and hertz read
    /// as integers on a console), one fraction digit otherwise.
    private func formatted(_ value: Double, unit: String?) -> String {
        guard let unit else { return value.formatted(.number.precision(.fractionLength(1))) }
        return "\(value.formatted(.number.precision(.fractionLength(0)))) \(unit)"
    }
}
