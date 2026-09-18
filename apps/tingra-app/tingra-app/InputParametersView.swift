//
//  InputParametersView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus
import TingraPlugInKit

/// One input's declared settings, edited in a popover off its channel
/// strip's Input Settings button (PLUGINS.md, Decision 15): a control per
/// `Parameter` the input declares — a slider paired with the shared
/// ``EffectParameterField`` for a number, the shared ``EffectColorWell``
/// for a color — drawn generically from the descriptors, so a host-only
/// plug-in's input gets a native settings pane with no app code of its own.
/// The 440 Hz tone is the first: its frequency and level.
///
/// Edits apply live through `Input.setParameters` and persist with the
/// project (`Project.inputParameters`); each control reports its own `tap`
/// right where it executes — the slider at drag end, the field on commit,
/// the well when its burst settles (EVENTS.md, "The `tap` convention").
struct InputParametersView: View {
    /// The engine model whose input settings the popover edits.
    @Bindable var model: EngineModel

    /// The input whose settings these are.
    let inputID: InputID

    /// The popover's body: the heading, the input's name, then a control
    /// per declared parameter in the input's own order.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Input Settings", comment: "Heading of an input's settings popover, over the parameters it declares")
                .font(.headline)
            Text(model.inputName(for: inputID))
                .foregroundStyle(.secondary)

            ForEach(parameters, id: \.key) { parameter in
                switch parameter.kind {
                case .number:
                    parameterSlider(parameter)
                case .color:
                    parameterColorWell(parameter)
                }
            }
        }
        .padding()
        .frame(width: 320)
    }

    /// The parameters the input declares, as the model snapshotted them.
    private var parameters: [Parameter] {
        model.declaredInputParameters[inputID] ?? []
    }

    /// The input's stored values, keyed by parameter.
    private var payload: [String: JSONValue] {
        model.inputParameters[inputID] ?? [:]
    }

    /// One number parameter's slider — its travel mapped through the scale
    /// the parameter declares (``ParameterScale``) — paired with the shared
    /// value field, so the value can be read and typed.
    private func parameterSlider(_ parameter: Parameter) -> some View {
        let value = parameter.value(in: payload)
        return HStack(spacing: 6) {
            Text(parameter.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Slider(
                value: Binding {
                    ParameterScale.position(of: value, for: parameter)
                } set: { position in
                    let newValue = ParameterScale.value(at: position, for: parameter)
                    model.setInputParameter(.double(newValue), forKey: parameter.key, ofInput: inputID)
                },
                in: 0...1
            ) { editing in
                guard !editing else { return }
                model.eventBus.tap(
                    "inputParameter.slider",
                    domain: .capture,
                    params: [
                        "id": .string(inputID.rawValue),
                        "key": .string(parameter.key),
                        "value": .double(parameter.value(in: payload)),
                    ]
                )
            }
            .controlSize(.small)

            EffectParameterField(parameter: parameter, value: value) { typed in
                model.eventBus.tap(
                    "inputParameter.field",
                    domain: .capture,
                    params: [
                        "id": .string(inputID.rawValue),
                        "key": .string(parameter.key),
                        "value": .double(typed),
                    ]
                )
                model.setInputParameter(.double(typed), forKey: parameter.key, ofInput: inputID)
            }
        }
    }

    /// One color parameter's well — no first-party input declares one, but
    /// the descriptor's kind is handled exhaustively so a third-party input
    /// that does gets its control. The well coalesces a color panel's
    /// continuous changes into one gesture and one `tap`.
    private func parameterColorWell(_ parameter: Parameter) -> some View {
        let value = parameter.color(in: payload) ?? .white
        return EffectColorWell(parameter: parameter, value: value) {
        } onChange: { color in
            model.setInputParameter(color.jsonValue, forKey: parameter.key, ofInput: inputID)
        } onEnd: {
            model.eventBus.tap(
                "inputParameter.colorWell",
                domain: .capture,
                params: [
                    "id": .string(inputID.rawValue),
                    "key": .string(parameter.key),
                ]
            )
        }
    }
}
