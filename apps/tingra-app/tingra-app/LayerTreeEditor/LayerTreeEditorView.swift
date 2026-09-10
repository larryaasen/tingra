//
//  LayerTreeEditorView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import SwiftUI
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// The layer-tree editor: edits the layer tree of the shot staged on
/// preview — or, when nothing is staged, of the shot on program — live
/// (roadmap step 7; ARCHITECTURE.md, "The layer-tree editor").
///
/// **Which shot is edited is answered by the switcher, not by a toggle
/// here.** ``EditedShot`` resolves it: preview first, program as the
/// fallback. The header names that shot beside the shared tally lamp —
/// green while the shot is only staged, red while it is on program, red
/// winning when it is on both — and, in the red case, says outright that
/// edits are on air, because every edit flows through
/// `Compositor.updateShot(_:)` and a shot on program shows it at the next
/// tick whether the operator meant a rehearsal or not.
///
/// The list shows the shot's layers **topmost first** (the design-tool
/// convention); the underlying `layers` array stacks bottom to top, so the
/// list is the array reversed and every operation addresses the layer by its
/// bottom-to-top array index. Add binds a new layer to any discovered camera,
/// display, or video generator — as does dropping a sidebar input row on the
/// list (``DraggedInput``; ARCHITECTURE.md, "The shot bank"); rows drag to
/// reorder, and the row's context menu and the Layer menu carry Keynote's
/// arrange commands (``LayerMenuItems``); the Delete key removes the
/// selection; the trailing inspector column (``LayerInspectorColumn``)
/// rebinds the selected layer, places it by pixel fields or preset, and sets
/// its opacity — every edit is on program at the next tick, no separate
/// "apply" step (CLOCK.md, the live canvas). The selection is the model's
/// (``EngineModel/selectedLayerIndex``), shared with the handles on the
/// monitor (``LayerHandlesOverlay``) and the Layer menu (ARCHITECTURE.md,
/// "Direct manipulation, drag-to-reorder, and undo in the layer-tree
/// editor").
///
/// Every button reports its own `tap` event right where it executes
/// (EVENTS.md, "The `tap` convention").
struct LayerTreeEditorView: View {
    /// The engine model whose followed shot (``EngineModel/editedShot``) is
    /// edited.
    @Bindable var model: EngineModel

    /// The lamp's diameter in the header — a dot beside the shot's name,
    /// sized to the caption text it sits with.
    private static let lampDiameter: CGFloat = 8

    /// One list row's height, which sizes the list to its rows: tall enough
    /// for the thumbnail.
    private static let rowHeight: CGFloat = 30

    /// The row thumbnail's width; 16:9, so its height follows.
    private static let thumbnailWidth: CGFloat = 40

    /// The widest the list and its header row grow: a thumbnail, a name,
    /// and a percentage need no more, and rows stretched across the whole
    /// window read as a table with nothing in it (Larry, 2026-09-09).
    private static let maximumWidth: CGFloat = 480

    /// How many rows the list is sized for: never fewer than two (so an
    /// empty or one-layer shot still has room to drop on) and never more
    /// than six, past which it scrolls.
    private static let listRows = 2...6

    /// The editor body: hidden while no shot is followed (an empty pool, or a
    /// held program snapshot with nothing staged — there is no layer tree to
    /// edit).
    var body: some View {
        if let edited = model.editedShot {
            let shot = edited.shot
            VStack(alignment: .leading, spacing: 6) {
                shotHeader(for: edited)
                header(for: shot)
                layerList(for: shot)
            }
            .frame(maxWidth: Self.maximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The header naming the followed shot: the tally lamp, the shot's name,
    /// and — while the shot is on program — the note that edits are live.
    ///
    /// The lamp takes ``MultiviewTile/Tally/badgeTint``, the same red and
    /// green the input tiles and the sidebar's rows light with, so a lamp
    /// means one thing everywhere in the window. The name is authored, so it
    /// is drawn verbatim.
    private func shotHeader(for edited: EditedShot) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(edited.tally.badgeTint)
                .frame(width: Self.lampDiameter, height: Self.lampDiameter)
                .accessibilityLabel(
                    edited.isOnAir
                        ? Text(
                            "On program",
                            comment: "Accessibility label of the layer editor's lamp: the edited shot is on program")
                        : Text(
                            "On preview",
                            comment:
                                "Accessibility label of the layer editor's lamp: the edited shot is staged on preview")
                )

            Text(
                "Editing \(edited.shot.name)",
                comment: "Layer editor header naming the shot being edited; the placeholder is the shot's name"
            )
            .font(.caption.weight(.semibold))
            .lineLimit(1)

            if edited.isOnAir {
                Text("Edits are live on air.", comment: "Layer editor header note while the edited shot is on program")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
    }

    /// The header row: the "Layers" title with the add and remove controls.
    /// The Move Up / Move Down chevrons that stood here went with
    /// drag-to-reorder and the Layer menu; Remove stays as the one-click
    /// affordance beside Add.
    private func header(for shot: Shot) -> some View {
        HStack(spacing: 8) {
            Text("Layers", comment: "Layer editor section title")
                .font(.caption.weight(.semibold))

            Spacer()

            Menu {
                ForEach(model.layerInputChoices) { choice in
                    Button(choice.name) {
                        model.eventBus.tap(
                            "layerAdd.menu",
                            domain: .composition,
                            params: ["input": .string(choice.id.rawValue), "name": .string(choice.name)]
                        )
                        Task { await model.addLayer(boundTo: choice.id) }
                    }
                }
            } label: {
                Label {
                    Text("Add Layer", comment: "Menu adding a layer bound to an input")
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                removeSelectedLayer(reporting: "layerRemove.button")
            } label: {
                Label {
                    Text("Remove Layer", comment: "Button removing the selected layer")
                } icon: {
                    Image(systemName: "minus")
                }
                .labelStyle(.iconOnly)
            }
            .disabled(model.selectedLayer == nil)
        }
    }

    /// The layer list, topmost first, sized to its rows; an empty shot shows
    /// what to do instead of an empty box. A single selection, held by the
    /// model; rows drag to reorder and carry the Layer menu's items as their
    /// context menu; Delete removes the selection.
    ///
    /// Also the **drop target** for a sidebar input row: a dropped camera,
    /// display, or video generator becomes a new layer on top, the
    /// drag-from-grid the multiview record deferred, landing where a layer
    /// is actually made.
    private func layerList(for shot: Shot) -> some View {
        Group {
            if shot.layers.isEmpty {
                emptyState
            } else {
                List(selection: selectionBinding) {
                    ForEach(Array(shot.layers.indices.reversed()), id: \.self) { index in
                        layerRow(shot.layers[index], at: index)
                            .tag(index)
                            .contextMenu {
                                LayerMenuItems(model: model, surface: .contextMenu, index: index)
                            }
                    }
                    .onMove { source, destination in
                        reorder(from: source, to: destination, count: shot.layers.count)
                    }
                }
                .listStyle(.bordered)
                .onDeleteCommand {
                    removeSelectedLayer(reporting: "layerDelete.key")
                }
            }
        }
        .frame(height: Self.listHeight(forLayerCount: shot.layers.count))
        .dropDestination(for: DraggedInput.self) { items, _ in
            // Only a discovered video input can be a layer; a payload naming
            // anything else is a device that went away mid-drag.
            guard let input = items.first?.id, model.layerInputChoices.contains(where: { $0.id == input }) else {
                return false
            }
            model.eventBus.tap(
                "layerList.drop",
                domain: .composition,
                params: ["input": .string(input.rawValue), "name": .string(model.inputName(for: input))]
            )
            Task { await model.addLayer(boundTo: input) }
            return true
        }
    }

    /// The empty shot's list: what a layer is made from and how, in the
    /// system's unavailable-content shape, framed like the list it stands
    /// in for so the drop target reads as one.
    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Layers", comment: "Layer editor empty state title: the edited shot has no layers")
            } icon: {
                Image(systemName: "square.stack.3d.up.slash")
            }
        } description: {
            Text(
                "Drag an input here or use Add Layer.",
                comment: "Layer editor empty state description: how to add a layer"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.separator)
        }
    }

    /// One row: a live thumbnail of the input (``InputFrameSource``, the
    /// shot bank's source, so a row shows what it is), the input's kind symbol, its name, and its opacity — dimmed
    /// with a warning symbol when the input is not discovered, Final Cut's
    /// missing-media reading, so a dormant layer never looks like a live one.
    private func layerRow(_ layer: Layer, at index: Int) -> some View {
        let available = model.isInputAvailable(layer.input)
        return HStack(spacing: 6) {
            MonitorTile(
                source: InputFrameSource(model: model, id: layer.input), label: nil, badgeTint: .clear,
                cornerRadius: 3
            )
            .frame(width: Self.thumbnailWidth, height: Self.thumbnailWidth * 9 / 16)
            Image(systemName: available ? model.kindSymbol(forInput: layer.input) : "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(model.inputName(for: layer.input))
            Spacer()
            Text(layer.opacity.formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .foregroundStyle(available ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(
            available
                ? Text(verbatim: "")
                : Text("Not connected", comment: "Tooltip on a layer whose input is not currently discovered")
        )
        .accessibilityHint(
            available
                ? Text(verbatim: "")
                : Text("Not connected", comment: "Tooltip on a layer whose input is not currently discovered")
        )
    }

    /// The list's selection, reporting a `tap` when the list changes it —
    /// the monitor and the menu report their own, so the model's stored
    /// selection is not watched for changes.
    private var selectionBinding: Binding<Int?> {
        $model.selectedLayerIndex.reportingTap(to: model.eventBus, "layerSelect.list", domain: .composition) {
            ["index": .int($0 ?? -1)]
        }
    }

    /// The list's height for a shot: its rows, within ``listRows``.
    private static func listHeight(forLayerCount count: Int) -> CGFloat {
        CGFloat(min(max(count, listRows.lowerBound), listRows.upperBound)) * rowHeight + 12
    }

    /// Applies a drag-to-reorder and keeps the selection on the layer that
    /// moved, so the row the operator dragged stays the one the inspector
    /// shows.
    private func reorder(from source: IndexSet, to destination: Int, count: Int) {
        guard let moved = source.first else { return }
        model.eventBus.tap(
            "layerList.reorder",
            domain: .composition,
            params: ["from": .int(count - 1 - moved), "to": .int(destination)]
        )
        let wasSelected = model.selectedLayerIndex == count - 1 - moved
        model.moveLayers(fromDisplayed: source, toDisplayed: destination)
        if wasSelected {
            let landed = destination > moved ? destination - 1 : destination
            model.selectedLayerIndex = count - 1 - landed
        }
    }

    /// Removes the selected layer, reporting the tap of whichever control
    /// asked — the Remove button or the Delete key.
    private func removeSelectedLayer(reporting tapName: String) {
        guard let selection = model.selectedLayer else { return }
        model.eventBus.tap(tapName, domain: .composition, params: ["index": .int(selection.index)])
        model.selectedLayerIndex = nil
        Task { await model.removeLayer(at: selection.index) }
    }
}
