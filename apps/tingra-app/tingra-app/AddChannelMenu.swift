//
//  AddChannelMenu.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus
import TingraPlugInKit

/// The **Add Channel** menu: the plus button beside the **Mixer** heading,
/// the shot bank's Add Shot pattern one panel over, listing every discovered
/// audio input that is not on the mixer yet. Choosing one adds its strip at
/// the end of the row, muted (``EngineModel/addStrip(for:)``;
/// ARCHITECTURE.md, "Per-strip routing", the amendment of 2026-11-07).
///
/// The items group the way the sidebar does — the microphones, then the
/// audio generators, then the media files with sound — under the sidebar's
/// own section headings, so an input is found under the same word in both
/// places. A group with nothing to offer is left out, and when every audio
/// input is already a strip the menu says so, disabled, rather than opening
/// empty: an answer, not a blank menu.
struct AddChannelMenu: View {
    /// The engine model the items add through, and report their `tap` to.
    let model: EngineModel

    /// The menu, drawn as a borderless plus glyph.
    var body: some View {
        Menu {
            let available = model.audioInputsOffMixer
            if available.isEmpty {
                Button {
                } label: {
                    Text(
                        "Every audio input is on the mixer",
                        comment: "Add Channel menu placeholder when every discovered audio input already has a strip"
                    )
                }
                .disabled(true)
            } else {
                group(
                    Text("Audio Inputs", comment: "Sidebar section heading over the audio input device list"),
                    inputs: available.filter { $0.kind == .microphone }
                )
                group(
                    Text("Audio Generators", comment: "Sidebar section heading over the audio generators"),
                    inputs: available.filter { $0.kind == .generator }
                )
                group(
                    Text(
                        "Media",
                        comment:
                            "Library tab listing the project's media files\nSidebar section heading over the project's media files"
                    ),
                    inputs: available.filter { $0.kind == .media }
                )
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Not focusable, like the Add Shot button: a menu opened by click,
        // where a focus ring around a bare glyph reads as a stray border.
        .focusable(false)
        .focusEffectDisabled()
        .help(Text("Add an audio input to the mixer", comment: "Tooltip on the mixer's Add Channel menu"))
        .accessibilityLabel(Text("Add Channel", comment: "Accessibility label of the mixer's Add Channel menu"))
    }

    /// One headed group of inputs, each item adding that input's strip — or
    /// nothing at all when the group is empty.
    ///
    /// - Parameters:
    ///   - title: The group's heading.
    ///   - inputs: The inputs to list, in the model's stable order.
    /// - Returns: The group.
    @ViewBuilder private func group(_ title: Text, inputs: [EngineModel.InputChoice]) -> some View {
        if !inputs.isEmpty {
            Section {
                ForEach(inputs) { input in
                    Button {
                        model.eventBus.tap(
                            "mixerAddChannel.menuItem",
                            domain: .audio,
                            params: [
                                "id": .string(input.id.rawValue),
                                "name": .string(input.name),
                                "kind": .string(input.kind.rawValue),
                            ]
                        )
                        model.addStrip(for: input.id)
                    } label: {
                        // A device's name is reported by discovery: runtime
                        // data, drawn verbatim.
                        Text(verbatim: input.name)
                    }
                }
            } header: {
                title
            }
        }
    }
}
