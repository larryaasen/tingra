//
//  SidebarView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The left selection panel: a standard macOS sidebar listing the available
/// cameras and microphones in two sections.
///
/// It uses a plain sidebar-styled `List` so the system supplies the Liquid
/// Glass material, section headers, and row metrics; each row is a standard
/// `Label` with an SF Symbol, and the active camera and microphone are marked
/// with a trailing checkmark.
struct SidebarView: View {
    /// The shared hardware-selection state driving each section's active row.
    @Environment(HardwareModel.self) private var model

    /// Lays out the two device sections in a sidebar list.
    var body: some View {
        List {
            Section("Cameras") {
                ForEach(model.cameras) { camera in
                    DeviceRow(
                        name: camera.name,
                        systemImage: "video",
                        isActive: model.selectedCameraID == camera.id
                    ) {
                        // Selecting a camera switches the live preview to it.
                        model.selectCamera(camera.id)
                    }
                }
            }
            Section("Microphones") {
                ForEach(model.microphones) { microphone in
                    DeviceRow(
                        name: microphone.name,
                        systemImage: "mic",
                        isActive: model.selectedMicrophoneID == microphone.id
                    ) {
                        model.selectMicrophone(microphone.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// One tappable device row: a standard `Label` (SF Symbol + name) that marks
/// itself active with a trailing checkmark.
private struct DeviceRow: View {
    /// The device name shown in the row.
    let name: String
    /// The SF Symbol identifying the device kind (`video` / `mic`).
    let systemImage: String
    /// Whether this row is the active selection in its section.
    let isActive: Bool
    /// Invoked when the row is activated, to update the selection.
    let onSelect: () -> Void

    /// Draws the label-plus-checkmark row as a borderless button.
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Label(name, systemImage: systemImage)
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

#Preview {
    NavigationSplitView {
        SidebarView()
            .environment(HardwareModel.preview)
    } detail: {
        Color.clear
    }
    .frame(width: 900, height: 560)
}
