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
/// for a color, the shared ``EffectParameterToggle`` for a toggle — drawn
/// generically from the descriptors, so a host-only plug-in's input gets a
/// native settings pane with no app code of its own. The 440 Hz tone is the
/// first: its frequency and level. A UVC camera's controls are the largest
/// (docs/UVC.md): grouped under their section headings, with a value its
/// Auto toggle owns disabled while that toggle is on.
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

            ForEach(Array(parameters.enumerated()), id: \.element.key) { index, parameter in
                if let section = parameter.section, index == 0 || parameters[index - 1].section != section {
                    // Section headings come from the plug-in, like its
                    // parameter names.
                    Text(verbatim: section)
                        .font(.subheadline)
                        .padding(.top, 4)
                }
                switch parameter.kind {
                case .number:
                    parameterSlider(parameter)
                        .disabled(parameter.isControlledAutomatically(in: payload, among: parameters))
                case .color:
                    parameterColorWell(parameter)
                case .toggle:
                    parameterToggle(parameter)
                case .choice:
                    parameterChoice(parameter)
                @unknown default:
                    UnsupportedParameterRow(parameter: parameter)
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

    /// The input's values, keyed by parameter: the project's stored values,
    /// else the values the device keeps for itself.
    private var payload: [String: JSONValue] {
        model.inputParameterValues(for: inputID)
    }

    /// One toggle parameter's switch — a camera's Auto Exposure, Auto White
    /// Balance, or Auto Focus. A flip is one change and one `tap`.
    private func parameterToggle(_ parameter: Parameter) -> some View {
        EffectParameterToggle(parameter: parameter, isOn: parameter.isOn(in: payload) ?? false) { isOn in
            model.eventBus.tap(
                "inputParameter.toggle",
                domain: .capture,
                params: [
                    "id": .string(inputID.rawValue),
                    "key": .string(parameter.key),
                    "value": .bool(isOn),
                ]
            )
            model.setInputParameter(.bool(isOn), forKey: parameter.key, ofInput: inputID)
        }
    }

    /// One choice parameter's pop-up menu (a camera's power-line frequency,
    /// say), drawn by the shared picker. A pick is one discrete change, so it
    /// reports its `tap` and applies the option's value at once.
    private func parameterChoice(_ parameter: Parameter) -> some View {
        EffectParameterPicker(parameter: parameter, selection: parameter.choice(in: payload)) { choice in
            model.eventBus.tap(
                "inputParameter.choice",
                domain: .capture,
                params: [
                    "id": .string(inputID.rawValue),
                    "key": .string(parameter.key),
                    "value": .double(choice.value),
                ]
            )
            model.setInputParameter(.double(choice.value), forKey: parameter.key, ofInput: inputID)
        }
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
