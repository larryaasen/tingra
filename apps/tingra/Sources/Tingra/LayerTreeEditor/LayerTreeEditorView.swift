//
//  LayerTreeEditorView.swift
//  tingra
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

/// The layer-tree editor: edits the layer tree of the shot currently
/// selected in the switcher, live on program (roadmap step 7).
///
/// The list shows the shot's layers **topmost first** (the design-tool
/// convention); the underlying `layers` array stacks bottom to top, so the
/// list is the array reversed and every operation addresses the layer by its
/// bottom-to-top array index. Add binds a new layer to any discovered camera
/// or display; move up/down steps the selected layer through the stack; the
/// sliders adjust its normalized top-left-origin frame and its opacity —
/// every edit is on program at the next tick, no separate "apply" step
/// (CLOCK.md, the live canvas).
///
/// Every button reports its own `tap` event right where it executes, and the
/// sliders report one `tap` when a drag ends with the final value — never
/// per-drag-step traffic (EVENTS.md, "The `tap` convention").
struct LayerTreeEditorView: View {
    /// The engine model whose active shot is edited.
    @Bindable var model: EngineModel

    /// The selected layer's index in the shot's bottom-to-top `layers`
    /// array, or `nil` for no selection. View-local: like the active shot,
    /// which layer is being inspected is transient session state.
    @State private var selectedLayerIndex: Int?

    /// One adjustable component of a layer's normalized frame.
    private enum FrameComponent: CaseIterable {
        case x, y, width, height

        /// Reads this component from a frame.
        func value(of frame: CGRect) -> Double {
            switch self {
            case .x: frame.origin.x
            case .y: frame.origin.y
            case .width: frame.size.width
            case .height: frame.size.height
            }
        }

        /// Returns the frame with this component replaced.
        func replacing(in frame: CGRect, with value: Double) -> CGRect {
            var frame = frame
            switch self {
            case .x: frame.origin.x = value
            case .y: frame.origin.y = value
            case .width: frame.size.width = value
            case .height: frame.size.height = value
            }
            return frame
        }

        /// The slider's user-facing label.
        var label: Text {
            switch self {
            case .x: Text("X", comment: "Layer frame slider label: horizontal position")
            case .y: Text("Y", comment: "Layer frame slider label: vertical position")
            case .width: Text("Width", comment: "Layer frame slider label")
            case .height: Text("Height", comment: "Layer frame slider label")
            }
        }

        /// The slider's `tap` event name, distinct per control so each
        /// slider's use is independently traceable in the log.
        var tapName: String {
            switch self {
            case .x: "layerFrameX.slider"
            case .y: "layerFrameY.slider"
            case .width: "layerFrameWidth.slider"
            case .height: "layerFrameHeight.slider"
            }
        }
    }

    /// The editor body: hidden while no shot is selected (there is no layer
    /// tree to edit).
    var body: some View {
        if let shot = model.activeShot {
            VStack(alignment: .leading, spacing: 6) {
                header(for: shot)
                layerList(for: shot)
                if let index = selectedLayerIndex, shot.layers.indices.contains(index) {
                    inspector(for: shot.layers[index], at: index)
                } else {
                    Text("Select a layer to edit its frame and opacity.", comment: "Layer editor empty-selection hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: model.activeShotID) {
                // The editor follows the switcher: a different shot has a
                // different layer tree, so the old selection is meaningless.
                selectedLayerIndex = nil
            }
        }
    }

    /// The header row: the "Layers" title with the add/remove/move controls.
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
                guard let index = selectedLayerIndex else { return }
                model.eventBus.tap("layerMoveUp.button", domain: .composition, params: ["index": .int(index)])
                model.moveLayer(at: index, .up)
                selectedLayerIndex = index + 1
            } label: {
                Label {
                    Text("Move Up", comment: "Button moving the selected layer toward the top of the stack")
                } icon: {
                    Image(systemName: "chevron.up")
                }
                .labelStyle(.iconOnly)
            }
            .disabled(selectedLayerIndex.map { $0 >= shot.layers.count - 1 } ?? true)

            Button {
                guard let index = selectedLayerIndex else { return }
                model.eventBus.tap("layerMoveDown.button", domain: .composition, params: ["index": .int(index)])
                model.moveLayer(at: index, .down)
                selectedLayerIndex = index - 1
            } label: {
                Label {
                    Text("Move Down", comment: "Button moving the selected layer toward the bottom of the stack")
                } icon: {
                    Image(systemName: "chevron.down")
                }
                .labelStyle(.iconOnly)
            }
            .disabled(selectedLayerIndex.map { $0 <= 0 } ?? true)

            Button {
                guard let index = selectedLayerIndex else { return }
                model.eventBus.tap("layerRemove.button", domain: .composition, params: ["index": .int(index)])
                selectedLayerIndex = nil
                Task { await model.removeLayer(at: index) }
            } label: {
                Label {
                    Text("Remove Layer", comment: "Button removing the selected layer")
                } icon: {
                    Image(systemName: "minus")
                }
                .labelStyle(.iconOnly)
            }
            .disabled(selectedLayerIndex == nil)
        }
    }

    /// The layer list, topmost layer first, selecting the layer the
    /// inspector edits.
    private func layerList(for shot: Shot) -> some View {
        List(selection: $selectedLayerIndex) {
            ForEach(Array(shot.layers.indices.reversed()), id: \.self) { index in
                HStack {
                    Text(model.inputName(for: shot.layers[index].input))
                    Spacer()
                    Text(shot.layers[index].opacity.formatted(.percent.precision(.fractionLength(0))))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(index)
            }
        }
        .listStyle(.bordered)
        .frame(height: 110)
        .onChange(of: selectedLayerIndex) { _, newValue in
            model.eventBus.tap(
                "layerSelect.list",
                domain: .composition,
                params: ["index": .int(newValue ?? -1)]
            )
        }
    }

    /// The selected layer's inspector: frame and opacity sliders, applied
    /// live while dragging.
    private func inspector(for layer: Layer, at index: Int) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                ForEach(FrameComponent.allCases, id: \.self) { component in
                    componentSlider(component, for: layer, at: index)
                }
            }
            GridRow {
                HStack(spacing: 4) {
                    Text("Opacity", comment: "Layer opacity slider label")
                        .font(.caption)
                    Slider(value: opacityBinding(at: index), in: 0...1) { editing in
                        guard !editing else { return }
                        model.eventBus.tap(
                            "layerOpacity.slider",
                            domain: .composition,
                            params: ["index": .int(index), "value": .double(currentLayer(at: index)?.opacity ?? 0)]
                        )
                    }
                }
                .gridCellColumns(FrameComponent.allCases.count)
            }
        }
        .controlSize(.small)
    }

    /// One frame-component slider (X, Y, Width, or Height), applied live.
    private func componentSlider(_ component: FrameComponent, for layer: Layer, at index: Int) -> some View {
        HStack(spacing: 4) {
            component.label
                .font(.caption)
            Slider(value: frameBinding(component, at: index), in: 0...1) { editing in
                guard !editing else { return }
                let value = (currentLayer(at: index)?.frame).map(component.value(of:)) ?? 0
                model.eventBus.tap(
                    component.tapName,
                    domain: .composition,
                    params: ["index": .int(index), "value": .double(value)]
                )
            }
        }
    }

    /// The active shot's layer at the given bottom-to-top index, freshly read
    /// from the model so slider bindings always see the latest edit.
    private func currentLayer(at index: Int) -> Layer? {
        guard let layers = model.activeShot?.layers, layers.indices.contains(index) else { return nil }
        return layers[index]
    }

    /// A live binding to one component of the layer's normalized frame.
    private func frameBinding(_ component: FrameComponent, at index: Int) -> Binding<Double> {
        Binding {
            (currentLayer(at: index)?.frame).map(component.value(of:)) ?? 0
        } set: { newValue in
            guard let frame = currentLayer(at: index)?.frame else { return }
            model.setLayerFrame(component.replacing(in: frame, with: newValue), at: index)
        }
    }

    /// A live binding to the layer's opacity.
    private func opacityBinding(at index: Int) -> Binding<Double> {
        Binding {
            currentLayer(at: index)?.opacity ?? 0
        } set: { newValue in
            model.setLayerOpacity(newValue, at: index)
        }
    }
}
