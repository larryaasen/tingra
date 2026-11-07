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
    /// The window's camera session: the camera it shows and that camera's
    /// controls and values.
    @Environment(CameraSession.self) private var session

    /// The framing controls the camera has, in pan, tilt, zoom order.
    private var parameters: [Parameter] {
        CameraSession.FramingKey.all.compactMap { session.cameraParameter(forKey: $0) }
    }

    /// The narrowest a slider and its value may be side by side, so the row
    /// stacks before a slider has no travel left.
    private static let sideBySideSliderMinWidth: CGFloat = 76

    /// One labeled slider per framing control, sharing the row's width, or
    /// stacked when a narrow window can't fit them side by side.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                sliders(minimumWidth: Self.sideBySideSliderMinWidth, valueMinWidth: 36, valueAlignment: .leading)
            }
            VStack(spacing: 8) {
                sliders(minimumWidth: nil, valueMinWidth: 48, valueAlignment: .trailing)
            }
        }
    }

    /// One labeled slider per framing control.
    ///
    /// - Parameters:
    ///   - minimumWidth: The narrowest each slider may be, or nil
    ///   for no limit.
    ///   - valueMinWidth: The narrowest each value may be.
    ///   - valueAlignment: Where each value sits within that width: beside
    ///     its slider on one row, in a column when stacked.
    /// - Returns: The sliders.
    private func sliders(
        minimumWidth: CGFloat?,
        valueMinWidth: CGFloat,
        valueAlignment: Alignment
    ) -> some View {
        ForEach(parameters, id: \.key) { parameter in
            HStack(spacing: 8) {
                // Control names come from the capture plug-in, like device
                // names.
                Text(verbatim: parameter.name)
                CameraParameterSlider(
                    parameter: parameter, valueMinWidth: valueMinWidth, valueAlignment: valueAlignment
                )
                .frame(minWidth: minimumWidth)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
