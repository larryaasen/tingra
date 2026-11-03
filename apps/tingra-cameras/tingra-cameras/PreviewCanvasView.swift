//
//  PreviewCanvasView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The middle content panel: the rounded live-camera preview frame, aligned to
/// the top of the column and drawn on the standard detail-pane background.
struct PreviewCanvasView: View {
    /// The shared hardware-selection state, so the frame follows the
    /// currently selected camera.
    @Environment(HardwareModel.self) private var model

    /// Places the preview frame at the top of the available space.
    var body: some View {
        // The video view window: a 16:9 rounded-rectangle container that
        // shows the live feed for the selected camera, a placeholder when
        // none is selected, or a message when the camera can't be opened —
        // with no layout change between them.
        content
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityElement()
            .accessibilityLabel(previewAccessibilityLabel)
            .overlay(alignment: .bottomTrailing) {
                // The Maps-style framing buttons, over a live preview of
                // a camera that can be framed.
                if showsFraming {
                    FramingOverlay()
                        .padding(10)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Whether the preview shows a live camera whose framing can be moved.
    private var showsFraming: Bool {
        model.previewError == nil && model.selectedCamera != nil && model.hasFraming
    }

    /// The frame's contents for the current state: an error message, the live
    /// preview, or the idle placeholder.
    @ViewBuilder
    private var content: some View {
        if let previewError = model.previewError {
            PreviewMessage(
                title: Text("Camera Unavailable"),
                systemImage: "video.slash",
                description: Text(previewError)
            )
        } else if model.selectedCamera != nil {
            CameraPreviewView()
                .help(showsFraming ? Text("Drag to pan and tilt. Pinch or Option-scroll to zoom.") : Text(verbatim: ""))
        } else {
            PreviewMessage(
                title: Text("Live Camera Preview"),
                systemImage: "video",
                description: Text("The selected camera's live preview appears here.")
            )
        }
    }

    /// A spoken description of the preview frame that names the selected
    /// camera when there is one.
    private var previewAccessibilityLabel: Text {
        if let camera = model.selectedCamera {
            return Text("Live preview of \(camera.name)")
        }
        return Text("Live Camera Preview")
    }
}

/// The standard placeholder/error frame content: a `ContentUnavailableView`
/// over a neutral system fill, shown while no live feed is attached.
private struct PreviewMessage: View {
    /// The message title.
    let title: Text
    /// The SF Symbol illustrating the message.
    let systemImage: String
    /// The supporting message text.
    let description: Text

    /// Draws the message centered on a subtle fill.
    var body: some View {
        ContentUnavailableView {
            Label {
                title
            } icon: {
                Image(systemName: systemImage)
            }
        } description: {
            description
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary)
    }
}

#Preview {
    PreviewCanvasView()
        .environment(HardwareModel.preview)
        .frame(width: 720, height: 520)
}
