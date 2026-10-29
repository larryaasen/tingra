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

/// The selected camera's adjustable controls, under the preview: a grouped
/// form with one section per parameter section the camera declares
/// (Exposure, Image, White Balance, Focus, Framing) and a row per control.
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
    /// The shared model holding the selected camera's controls and values.
    @Environment(HardwareModel.self) private var model

    /// The form, or a short note for a camera with no controls.
    var body: some View {
        if model.cameraParameters.isEmpty {
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
                if model.hasFraming {
                    Section {
                        FramingRow()
                    } header: {
                        if let title = framingSectionTitle {
                            Text(verbatim: title)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The Framing row's heading: the section the camera puts its framing
    /// controls in.
    private var framingSectionTitle: String? {
        HardwareModel.FramingKey.all.lazy.compactMap { model.cameraParameter(forKey: $0)?.section }.first
    }

    /// The Auto switches drawn at the end of a number's row, by that
    /// number's key: each switch that owns exactly one number in its own
    /// section.
    private var pairedToggles: [String: Parameter] {
        var governed: [String: [Parameter]] = [:]
        for parameter in model.cameraParameters {
            guard let toggleKey = parameter.automaticToggleKey else { continue }
            governed[toggleKey, default: []].append(parameter)
        }
        var paired: [String: Parameter] = [:]
        for (toggleKey, numbers) in governed {
            guard numbers.count == 1, let number = numbers.first,
                let toggle = model.cameraParameter(forKey: toggleKey),
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
        let hiddenKeys = Set(HardwareModel.FramingKey.all).union(omittedKeys)
        for parameter in model.cameraParameters where !hiddenKeys.contains(parameter.key) {
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
        .environment(HardwareModel.preview)
        .frame(width: 640, height: 400)
}
