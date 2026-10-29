//
//  FramingOverlay.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The Maps-style framing buttons in the preview's corner: zoom in, zoom
/// out, and reset the framing, stacked in a Liquid Glass capsule like the
/// zoom control Maps floats over its map. They are the buttons beside the
/// preview's own drag, pinch, and Option-scroll, and the way VoiceOver and
/// keyboard users reach the framing (docs/UVC.md, "The Tingra Cameras
/// controls panel").
struct FramingOverlay: View {
    /// The shared model whose camera framing the buttons change.
    @Environment(HardwareModel.self) private var model

    /// The buttons a camera's framing calls for: zoom only when it has a
    /// zoom, reset always.
    var body: some View {
        VStack(spacing: 0) {
            if model.cameraParameter(forKey: HardwareModel.FramingKey.zoom) != nil {
                Button {
                    model.stepZoom(by: 1)
                } label: {
                    Label("Zoom In", systemImage: "plus")
                }
                .help(Text("Zoom In"))
                Divider()
                Button {
                    model.stepZoom(by: -1)
                } label: {
                    Label("Zoom Out", systemImage: "minus")
                }
                .help(Text("Zoom Out"))
                Divider()
            }
            Button {
                model.resetFraming()
            } label: {
                Label("Reset Framing", systemImage: "arrow.counterclockwise")
            }
            .help(Text("Reset Framing"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(FramingButtonStyle())
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
    }
}

/// One framing button: its icon centered in a square hit target that fills
/// the capsule's width, dimmed while pressed.
private struct FramingButtonStyle: ButtonStyle {
    /// Draws the icon with a square, fully clickable target, at the size
    /// the system gives a large control's icon.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .imageScale(.large)
            .padding(8)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

#Preview {
    FramingOverlay()
        .environment(HardwareModel.preview)
        .padding()
}
