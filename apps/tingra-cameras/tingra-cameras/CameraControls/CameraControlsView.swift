//
//  CameraControlsView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// The selected camera's adjustable controls, in the trailing sidebar: a
/// grouped form with one section per parameter section the camera declares
/// (Exposure, Image, White Balance, Framing) and a row per control.
///
/// Drawn from the camera's `Parameter` descriptors alone, so it shows
/// whatever the camera advertises with the camera's own ranges, and nothing
/// for a camera that has none (docs/UVC.md, "The Tingra Cameras controls
/// panel"). Every change goes straight to the camera; nothing is stored.
///
/// Two kinds of rows are combined to keep the form short: an Auto switch
/// that owns a single number sits at the end of that number's row (White
/// Balance's Temperature, Focus), and the camera's pan, tilt, and zoom share
/// one Framing row, ``FramingRow``, beside the preview's own Maps-style
/// framing. Auto Exposure owns two numbers, so it keeps a row of its own.
struct CameraControlsView: View {
    /// The window's camera session: the camera it shows and that camera's
    /// controls and values.
    @Environment(CameraSession.self) private var session

    /// Whether the dialog confirming Reset All Controls is showing.
    @State private var isConfirmingReset = false

    /// The form, or a short note for a camera with no controls.
    var body: some View {
        if session.cameraParameters.isEmpty {
            Text("This camera has no adjustable controls.")
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity)
        } else {
            let paired = pairedToggles
            Form {
                ForEach(sections(omitting: Set(paired.values.map(\.key)))) { section in
                    Section {
                        ForEach(section.parameters, id: \.key) { parameter in
                            CameraParameterRow(parameter: parameter, automaticToggle: paired[parameter.key])
                        }
                    } header: {
                        if let title = section.title {
                            // Section titles come from the capture plug-in,
                            // like device names.
                            Text(verbatim: title)
                        }
                    }
                }
                if session.hasFraming {
                    // No heading: the row names each of its sliders.
                    Section {
                        FramingRow()
                    }
                }
                Section {
                    Button {
                        session.recordResetAllTap("cameraParameterResetAll.button")
                        isConfirmingReset = true
                    } label: {
                        Text(
                            "Reset All Controls…",
                            comment: "Button asking to return every control of the selected camera to its default"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .formStyle(.grouped)
            .alert(
                Text("Reset All Controls", comment: "Title of the dialog confirming a reset of the camera's controls"),
                isPresented: $isConfirmingReset
            ) {
                Button(role: .destructive) {
                    session.resetAllCameraParameters()
                } label: {
                    Text("Reset", comment: "Reset All Controls dialog confirm button")
                }
                Button(role: .cancel) {
                    session.recordResetAllTap("cameraParameterResetAllCancel.button")
                } label: {
                    Text("Cancel", comment: "Camera preset dialog cancel button")
                }
            } message: {
                if let camera = session.selectedCamera {
                    Text(
                        "Every control of \(camera.name) returns to its default. Saved presets are not changed.",
                        comment: "Reset All Controls dialog message; the placeholder is the camera's name"
                    )
                }
            }
        }
    }

    /// The Auto switches drawn at the end of a number's row, by that
    /// number's key: each switch that owns exactly one number in its own
    /// section.
    private var pairedToggles: [String: Parameter] {
        var governed: [String: [Parameter]] = [:]
        for parameter in session.cameraParameters {
            guard let toggleKey = parameter.automaticToggleKey else { continue }
            governed[toggleKey, default: []].append(parameter)
        }
        var paired: [String: Parameter] = [:]
        for (toggleKey, numbers) in governed {
            guard numbers.count == 1, let number = numbers.first,
                let toggle = session.cameraParameter(forKey: toggleKey),
                toggle.kind == .toggle, toggle.section == number.section
            else { continue }
            paired[number.key] = toggle
        }
        return paired
    }

    /// The parameters other than the framing controls and the given Auto
    /// switches, grouped into consecutive runs that share a section, in the
    /// camera's declaration order.
    ///
    /// - Parameter omittedKeys: The keys of the Auto switches drawn on
    ///   their number's row.
    /// - Returns: The sections.
    private func sections(omitting omittedKeys: Set<String>) -> [ParameterSection] {
        var sections: [ParameterSection] = []
        let hiddenKeys = Set(CameraSession.FramingKey.all).union(omittedKeys)
        for parameter in session.cameraParameters where !hiddenKeys.contains(parameter.key) {
            if let last = sections.last, last.title == parameter.section {
                sections[sections.count - 1].parameters.append(parameter)
            } else {
                sections.append(ParameterSection(title: parameter.section, parameters: [parameter]))
            }
        }
        return sections
    }
}

/// A run of parameters under one section heading.
private struct ParameterSection: Identifiable {
    /// The heading, or nil for parameters the camera puts in no section.
    let title: String?

    /// The parameters, in declaration order.
    var parameters: [Parameter]

    /// The first parameter's key, unique among sections because every key
    /// appears once.
    var id: String { parameters.first?.key ?? title ?? "" }
}

#Preview {
    CameraControlsView()
        .previewEnvironment()
        .frame(width: TrailingSidebar.idealWidth, height: 600)
}
