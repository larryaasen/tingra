//
//  LayerInspectorColumn.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition

/// The main window's trailing inspector column (ARCHITECTURE.md, "The
/// inspector column and the sidebar's casting pickers"): a title naming the
/// shot being edited — "Shot: Main Display", beside the shared tally lamp —
/// over a caption naming the selected layer with its kind symbol, then
/// ``LayerInspectorView``
/// — or, while nothing is selected, the unavailable-content shape saying
/// where to select one. Shown and hidden by ⌥⌘I and the toolbar's trailing
/// button (``InspectorCommands``, ``InspectorButton``).
struct LayerInspectorColumn: View {
    /// The engine model whose selected layer the column inspects.
    @Bindable var model: EngineModel

    /// The trailing sidebar's upper pane: the inspector over the selection,
    /// or the empty state. The sidebar's width bounds live on
    /// ``TrailingSidebar``, which holds this above the Library.
    var body: some View {
        Group {
            if let selection = model.selectedLayer, let edited = model.editedShot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header(for: selection.layer, in: edited)
                        LayerInspectorView(model: model, layer: selection.layer, index: selection.index)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No Layer Selected", comment: "Inspector column empty state title")
                    } icon: {
                        Image(systemName: "square.stack.3d.up")
                    }
                } description: {
                    Text(
                        "Select a layer in the list or on the preview monitor.",
                        comment: "Inspector column empty state description"
                    )
                }
            }
        }
    }

    /// The lamp's diameter in the title, sized to the text it sits with.
    private static let lampDiameter: CGFloat = 8

    /// The title: "Shot: <shot name>" in the headline style, beside the same
    /// tally lamp the layer editor's header lights — the shot is what the
    /// operator is editing and what changes on air, the layer only the part
    /// of it in hand — over a caption naming the selected layer by its
    /// input, with the input's kind symbol.
    private func header(for layer: Layer, in edited: EditedShot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(edited.tally.badgeTint)
                    .frame(width: Self.lampDiameter, height: Self.lampDiameter)
                Text(
                    "Shot: \(edited.shot.name)",
                    comment: "Inspector column title naming the shot being edited"
                )
                .font(.headline)
                .lineLimit(1)
            }
            HStack(spacing: 6) {
                Image(systemName: model.kindSymbol(forInput: layer.input))
                    .foregroundStyle(.secondary)
                Text(
                    "Layer: \(model.inputName(for: layer.input))",
                    comment: "Inspector column caption naming the selected layer; the placeholder is its input's name"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}
