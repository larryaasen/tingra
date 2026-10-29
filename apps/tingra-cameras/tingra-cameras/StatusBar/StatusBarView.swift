//
//  StatusBarView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The window's status bar: whether the selected camera is **live**, which
/// camera it is, and the **resolution** of its frames, across the bottom of
/// the preview column.
///
/// Status only, no controls — the main Tingra app's rule for its bar. It
/// draws nothing at all when the operator has turned it off (``StatusBarModel``),
/// which is what lets the window attach it unconditionally as a bottom
/// safe-area inset on the detail column, where macOS puts a status bar beside
/// a sidebar: the sidebar's material runs the full height of the window.
struct StatusBarView: View {
    /// The shared hardware model, read only: the bar reports and never acts.
    @Environment(HardwareModel.self) private var model

    /// Whether the bar is shown.
    @Environment(StatusBarModel.self) private var statusBar

    /// The bar's height — the standard macOS status bar's, near enough that
    /// it reads as one rather than as a row of controls.
    private static let height: CGFloat = 24

    /// The bar, or nothing when it is turned off. The separator rides above
    /// the material: it is what says where the content ended.
    @ViewBuilder var body: some View {
        if statusBar.isVisible {
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: 10) {
                    stateReading

                    if let camera = model.selectedCamera {
                        Divider()
                            .frame(height: 12)
                        // A device name is a proper noun from the system,
                        // never localized.
                        Text(verbatim: camera.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let dimensions = model.frameDimensions {
                        Divider()
                            .frame(height: 12)
                        // Plain digits: a resolution is read as one figure,
                        // so it never takes the locale's grouping separator.
                        Text(verbatim: "\(dimensions.width) × \(dimensions.height)")
                            .monospacedDigit()
                    }

                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .frame(height: Self.height)
            }
            .background(.bar)
        }
    }

    /// The leading reading: a colored symbol and a word for where the
    /// preview stands, so the color is never the only signal.
    private var stateReading: some View {
        Label {
            stateName
        } icon: {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
        }
        .accessibilityElement(children: .combine)
    }

    /// The preview state's word.
    private var stateName: Text {
        switch model.previewState {
        case .noCamera:
            Text("No camera selected", comment: "Status bar reading: no camera is selected or connected")
        case .starting:
            Text("Starting…", comment: "Status bar reading: the selected camera is opening")
        case .live:
            Text("Live", comment: "Status bar reading: the selected camera's frames are showing")
        case .unavailable:
            Text("Camera unavailable", comment: "Status bar reading: the selected camera could not be opened")
        }
    }

    /// The preview state's SF Symbol.
    private var stateSymbol: String {
        switch model.previewState {
        case .noCamera: "video.slash"
        case .starting: "circle.dotted"
        case .live: "circle.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    /// The preview state's symbol color: the system's semantic colors.
    private var stateColor: Color {
        switch model.previewState {
        case .noCamera, .starting: .secondary
        case .live: .green
        case .unavailable: .orange
        }
    }
}
