//
//  MonitorOverlaySettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus
import TingraPlugInKit

/// The Overlay Settings window: a section per registered monitor overlay
/// that declares settings, in the Overlays submenus' order, each with a
/// control per declared `Parameter` (PLUGINS.md, Decision 15), drawn with
/// the controls an input's settings already use: a slider and the shared
/// ``EffectParameterField`` for a number, ``EffectColorWell`` for a color,
/// ``EffectParameterToggle`` for a toggle, and ``EffectParameterPicker``
/// for a choice. So a third-party overlay gets the same native settings as
/// a first-party one, with no app code of its own.
///
/// A value is the overlay's on every monitor (PLUGINS.md, Decision 55), so
/// the window is one surface rather than a popover per monitor, opened by
/// **Overlay Settings…** at the end of every Overlays submenu. Edits apply
/// live, are saved with the project, and report their `tap` where they
/// settle: the slider at drag end, the field on commit, the well when its
/// burst settles.
struct MonitorOverlaySettingsView: View {
    /// The model whose project's overlay values the window edits.
    let model: EngineModel

    /// The window: a grouped form of the overlays with settings, or a
    /// placeholder when none has any.
    var body: some View {
        if providers.isEmpty {
            ContentUnavailableView {
                Text(
                    "No Overlay Settings",
                    comment: "Overlay Settings window placeholder title when no monitor overlay has settings")
            } description: {
                Text(
                    "None of the monitor overlays has settings to change.",
                    comment: "Overlay Settings window placeholder description")
            }
        } else {
            Form {
                ForEach(providers, id: \.id) { provider in
                    section(for: provider)
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The registered overlays that declare settings, in menu order.
    private var providers: [any MonitorOverlayProvider] {
        model.monitorOverlayCatalog.providers.filter { !$0.parameters.isEmpty }
    }

    /// One overlay's section: its name, then a control per parameter, and
    /// a button returning it to its defaults.
    ///
    /// - Parameter provider: The overlay.
    /// - Returns: The section.
    private func section(for provider: any MonitorOverlayProvider) -> some View {
        let payload = model.monitorOverlayParameterValues(for: provider.id)
        return Section {
            ForEach(provider.parameters, id: \.key) { parameter in
                control(for: parameter, of: provider.id, in: payload)
            }
        } header: {
            HStack {
                // Overlay names come from the plug-in, like effect names.
                Text(verbatim: provider.name)
                Spacer()
                Button {
                    model.eventBus.tap(
                        "monitorOverlaySettings.reset", domain: .composition,
                        params: ["overlay": .string(provider.id.rawValue)])
                    model.resetMonitorOverlayParameters(ofOverlay: provider.id)
                } label: {
                    Text(
                        "Reset",
                        comment: "Overlay Settings: returns one monitor overlay's settings to their defaults")
                }
                .controlSize(.small)
                .disabled(payload.isEmpty)
            }
        }
    }

    /// The control for one parameter, by kind.
    ///
    /// - Parameters:
    ///   - parameter: The declared parameter.
    ///   - id: The overlay it belongs to.
    ///   - payload: The overlay's stored values.
    /// - Returns: The control.
    @ViewBuilder
    private func control(
        for parameter: Parameter, of id: MonitorOverlayID, in payload: [String: JSONValue]
    ) -> some View {
        switch parameter.kind {
        case .number:
            slider(parameter, of: id, in: payload)
        case .color:
            colorWell(parameter, of: id, in: payload)
        case .toggle:
            EffectParameterToggle(parameter: parameter, isOn: parameter.isOn(in: payload) ?? false) { isOn in
                report("monitorOverlayParameter.toggle", id, parameter, ["value": .bool(isOn)])
                model.setMonitorOverlayParameter(.bool(isOn), forKey: parameter.key, ofOverlay: id)
            }
        case .choice:
            EffectParameterPicker(parameter: parameter, selection: parameter.choice(in: payload)) { choice in
                report("monitorOverlayParameter.choice", id, parameter, ["value": .double(choice.value)])
                model.setMonitorOverlayParameter(.double(choice.value), forKey: parameter.key, ofOverlay: id)
            }
        @unknown default:
            UnsupportedParameterRow(parameter: parameter)
        }
    }

    /// A number parameter's slider, its travel mapped through the scale the
    /// parameter declares, beside the shared value field.
    private func slider(
        _ parameter: Parameter, of id: MonitorOverlayID, in payload: [String: JSONValue]
    ) -> some View {
        let value = parameter.value(in: payload)
        return LabeledContent {
            HStack(spacing: 6) {
                Slider(
                    value: Binding {
                        ParameterScale.position(of: value, for: parameter)
                    } set: { position in
                        let newValue = ParameterScale.value(at: position, for: parameter)
                        model.setMonitorOverlayParameter(.double(newValue), forKey: parameter.key, ofOverlay: id)
                    },
                    in: 0...1
                ) { editing in
                    guard !editing else { return }
                    let settled = parameter.value(in: model.monitorOverlayParameterValues(for: id))
                    report("monitorOverlayParameter.slider", id, parameter, ["value": .double(settled)])
                }
                .controlSize(.small)
                EffectParameterField(parameter: parameter, value: value) { typed in
                    report("monitorOverlayParameter.field", id, parameter, ["value": .double(typed)])
                    model.setMonitorOverlayParameter(.double(typed), forKey: parameter.key, ofOverlay: id)
                }
            }
        } label: {
            Text(verbatim: parameter.name)
        }
    }

    /// A color parameter's well, which coalesces a color panel's continuous
    /// changes into one gesture and one `tap`.
    private func colorWell(
        _ parameter: Parameter, of id: MonitorOverlayID, in payload: [String: JSONValue]
    ) -> some View {
        EffectColorWell(parameter: parameter, value: parameter.color(in: payload) ?? .white) {
        } onChange: { color in
            model.setMonitorOverlayParameter(color.jsonValue, forKey: parameter.key, ofOverlay: id)
        } onEnd: {
            report("monitorOverlayParameter.colorWell", id, parameter, [:])
        }
    }

    /// Reports a control's `tap`, with the overlay and the parameter key.
    ///
    /// - Parameters:
    ///   - name: The tap's name.
    ///   - id: The overlay.
    ///   - parameter: The parameter changed.
    ///   - extra: Further params, such as the value.
    private func report(
        _ name: String, _ id: MonitorOverlayID, _ parameter: Parameter, _ extra: [String: EventValue]
    ) {
        var params: [String: EventValue] = ["overlay": .string(id.rawValue), "key": .string(parameter.key)]
        params.merge(extra) { _, new in new }
        model.eventBus.tap(name, domain: .composition, params: params)
    }
}
