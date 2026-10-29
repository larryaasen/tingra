//
//  FramingRow.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// The camera's pan, tilt, and zoom as one form row instead of three: a
/// compact slider for each, side by side, its name before it and its value
/// after it — the numbers beside the preview's own Maps-style framing
/// (docs/UVC.md, "The Tingra Cameras controls panel"). Each slider
/// double-clicks back to the camera's default like every other slider.
struct FramingRow: View {
    /// The shared model holding the camera's framing.
    @Environment(HardwareModel.self) private var model

    /// The framing controls the camera has, in pan, tilt, zoom order.
    private var parameters: [Parameter] {
        HardwareModel.FramingKey.all.compactMap { model.cameraParameter(forKey: $0) }
    }

    /// One labeled slider per framing control, sharing the row's width.
    var body: some View {
        HStack(spacing: 20) {
            ForEach(parameters, id: \.key) { parameter in
                HStack(spacing: 8) {
                    // Control names come from the capture plug-in, like
                    // device names.
                    Text(verbatim: parameter.name)
                    CameraParameterSlider(parameter: parameter, valueMinWidth: 48)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
