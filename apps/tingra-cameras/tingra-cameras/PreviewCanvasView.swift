//
//  PreviewCanvasView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The middle content panel: the rounded live-camera preview frame
/// (``PreviewFrame``), aligned to the top of the column and drawn on the
/// standard detail-pane background.
struct PreviewCanvasView: View {
    /// Places the preview frame at the top of the available space.
    var body: some View {
        PreviewFrame()
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The video view window: a 16:9 rounded-rectangle container that shows the
/// live feed for the selected camera or a placeholder when none is
/// selected — or, when the camera can't be opened, a card as tall as its
/// message and no taller (``PreviewErrorCard``), because the message is
/// longer than a narrow 16:9 frame holds. The standard window centres it in its column
/// (``PreviewCanvasView``); the compact window stacks it under the camera
/// picker (``CompactWindowView``).
struct PreviewFrame: View {
    /// The window's camera session, so the frame follows the camera the
    /// window shows.
    @Environment(CameraSession.self) private var session

    /// The frame, with the framing buttons over a live preview, or the
    /// error card.
    var body: some View {
        if let previewError = session.previewError {
            PreviewErrorCard(message: previewError)
        } else {
            videoFrame
        }
    }

    /// The 16:9 frame: the live preview or the placeholder.
    private var videoFrame: some View {
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
    }

    /// Whether the preview shows a live camera whose framing can be moved.
    private var showsFraming: Bool {
        session.previewError == nil && session.selectedCamera != nil && session.hasFraming
    }

    /// The 16:9 frame's contents for the current state: the live preview or
    /// the idle placeholder.
    @ViewBuilder
    private var content: some View {
        if session.selectedCamera != nil {
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
        if let camera = session.selectedCamera {
            return Text("Live preview of \(camera.name)")
        }
        return Text("Live Camera Preview")
    }
}

/// Why the camera can't be shown, in a card that grows with its message:
/// the camera's error is several sentences, more than a 16:9 frame holds at
/// a narrow window's width, so the card takes the message's height instead,
/// in the smaller text styles a status note wears rather than the large
/// title of an empty view.
private struct PreviewErrorCard: View {
    /// The camera's error, from the engine.
    let message: String

    /// The symbol, the title, and the message, centred on a subtle fill.
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "video.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Camera Unavailable")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        // No `fixedSize`: it made the message report the height it needs at
        // any width, and SwiftUI measures a window's minimum at a width near
        // zero, where the message wraps a character per line — the standard
        // window's content grew thousands of points taller than the window
        // and was drawn off-screen. Unfixed, the card still takes the
        // message's height, because its column proposes the full height and
        // text takes only what it needs.
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity)
        // The preview frame's own shape, so the card sits where the video
        // would.
        .background(.quaternary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// The standard placeholder frame content: a `ContentUnavailableView` over a
/// neutral system fill, shown while no camera is selected.
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
        .previewEnvironment()
        .frame(width: 720, height: 520)
}
