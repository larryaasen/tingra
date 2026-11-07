//
//  CameraParameterRow.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// One camera control: a switch for a toggle, a pop-up menu for a choice, a
/// slider with its value and unit under its name for a number, because beside
/// the name the trailing sidebar leaves a slider almost no travel. A number
/// its Auto switch owns is disabled while that switch is on, because the camera sets it then; when that switch owns no
/// other number, it is drawn at the end of the number's row as an Auto
/// checkbox (White Balance's Temperature, Focus) instead of on a row of its
/// own.
///
/// Each control reports its own `tap` — the switch when it flips, the menu
/// when an option is picked, the slider when a drag ends, the reset when it is double-clicked (EVENTS.md,
/// "The `tap` convention").
struct CameraParameterRow: View {
    /// The window's camera session: the camera it shows and that camera's
    /// controls and values.
    @Environment(CameraSession.self) private var session

    /// The control this row adjusts.
    let parameter: Parameter

    /// The Auto switch drawn at the end of a number's row, or nil when the
    /// number's switch (if any) has a row of its own.
    var automaticToggle: Parameter?

    /// The row for the parameter's kind.
    var body: some View {
        switch parameter.kind {
        case .toggle:
            toggleRow
        case .number:
            sliderRow
        case .choice:
            choiceRow
        case .color:
            // No camera control is a color.
            EmptyView()
        @unknown default:
            // A kind a later kit adds has no camera control behind it.
            EmptyView()
        }
    }

    /// Whether the parameter's Auto switch is on, so the camera owns it.
    private var isControlledAutomatically: Bool {
        parameter.isControlledAutomatically(in: session.cameraParameterValues, among: session.cameraParameters)
    }

    /// A switch for an on/off control.
    private var toggleRow: some View {
        Toggle(isOn: isOnBinding(for: parameter)) {
            // Control names come from the capture plug-in, like device
            // names.
            Text(verbatim: parameter.name)
        }
        .toggleStyle(.switch)
    }

    /// A pop-up menu for a control with named options.
    private var choiceRow: some View {
        Picker(selection: choiceBinding) {
            ForEach(parameter.choices, id: \.value) { choice in
                // Option names come from the capture plug-in, like control
                // names.
                Text(verbatim: choice.name).tag(choice.value)
            }
        } label: {
            Text(verbatim: parameter.name)
        }
    }

    /// A binding to a choice control's option that sends each pick to the
    /// camera and records its tap.
    private var choiceBinding: Binding<Double> {
        Binding {
            parameter.choice(in: session.cameraParameterValues)?.value ?? parameter.defaultValue
        } set: { value in
            session.setCameraParameter(.double(value), for: parameter)
            session.recordCameraParameterTap("cameraParameter.choice", parameter: parameter)
        }
    }

    /// A number control's name over its slider, with its Auto checkbox after
    /// the slider when the row carries one.
    private var sliderRow: some View {
        VStack(alignment: .leading) {
            Text(verbatim: parameter.name)
            HStack {
                CameraParameterSlider(parameter: parameter)
                    .disabled(isControlledAutomatically)
                if let automaticToggle {
                    Toggle(isOn: isOnBinding(for: automaticToggle)) {
                        Text("Auto")
                    }
                    .toggleStyle(.checkbox)
                    .help(Text(verbatim: automaticToggle.name))
                    .accessibilityLabel(Text(verbatim: automaticToggle.name))
                }
            }
        }
    }

    /// A binding to a toggle control's state that sends each flip to the
    /// camera and records its tap.
    ///
    /// - Parameter toggle: The toggle control.
    /// - Returns: The binding.
    private func isOnBinding(for toggle: Parameter) -> Binding<Bool> {
        Binding {
            toggle.isOn(in: session.cameraParameterValues) ?? false
        } set: { isOn in
            session.setCameraParameter(.bool(isOn), for: toggle)
            session.recordCameraParameterTap("cameraParameter.toggle", parameter: toggle)
        }
    }
}

/// A number control's slider with its value and unit beside it, shared by
/// the control rows and the Framing row. Its travel is mapped through the
/// scale the parameter declares and rests only on the camera's own steps
/// (`ParameterScale` snaps to the parameter's declared step); a
/// **double-click** returns it to the camera's default — the reset
/// convention the main app's pan slider and faders set.
struct CameraParameterSlider: View {
    /// The window's camera session: the camera it shows and that camera's
    /// controls and values.
    @Environment(CameraSession.self) private var session

    /// The number control this slider adjusts.
    let parameter: Parameter

    /// The narrowest the value beside the slider may be, so the slider
    /// doesn't shift as the value's width changes.
    var valueMinWidth: CGFloat = 72

    /// Where the value sits within that width: against the row's trailing
    /// edge by default, or against the slider where several share a row.
    var valueAlignment: Alignment = .trailing

    /// The slider, then the value.
    var body: some View {
        let value = parameter.value(in: session.cameraParameterValues)
        HStack {
            CameraSlider(
                value: Binding {
                    ParameterScale.position(of: value, for: parameter)
                } set: { position in
                    let newValue = ParameterScale.value(at: position, for: parameter)
                    session.setCameraParameter(.double(newValue), for: parameter)
                },
                in: 0...1,
                // Control names come from the capture plug-in, like device
                // names.
                label: parameter.name,
                onDoubleClick: {
                    session.resetCameraParameter(parameter)
                },
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    session.recordCameraParameterTap("cameraParameter.slider", parameter: parameter)
                }
            )
            Text(verbatim: parameter.formattedValue(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: valueMinWidth, alignment: valueAlignment)
        }
    }
}
