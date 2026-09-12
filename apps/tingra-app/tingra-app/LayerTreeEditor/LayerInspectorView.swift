//
//  LayerInspectorView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import SwiftUI
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// The selected layer's inspector, in Final Cut Pro's Video Inspector shape
/// (ARCHITECTURE.md, "The layer inspector"): an **Input** popup that rebinds
/// the layer in place; **Position** and **Size** as number fields with
/// steppers in program pixels or percent (``LayerInspectorUnit``), with an
/// aspect lock and Reset; a **Placement** row of nine anchors and three
/// sizes (``LayerPlacement``); **Opacity** as a slider paired with a percent
/// field; and the layer's effect chain (``LayerEffectChainView``).
///
/// Every committed field, every button, and every popup choice is one
/// layer-tree edit — so one undo step — and reports one `tap` where it
/// executes (EVENTS.md, "The `tap` convention"); the opacity slider brackets
/// its drag in a gesture like the handles do. The unit toggle and the lock
/// are view state for the session: pixels is the right default every
/// launch, and a lock that persisted would surprise the next edit.
struct LayerInspectorView: View {
    /// The engine model whose followed shot's layer this edits.
    @Bindable var model: EngineModel

    /// The layer, as the editor last read it.
    let layer: Layer

    /// The layer's bottom-to-top index in the shot.
    let index: Int

    /// Which unit the position and size fields use.
    @State private var unit: LayerInspectorUnit = .pixels

    /// A number field's width, enough for four digits and a sign.
    private static let fieldWidth: CGFloat = 52

    /// The side of an anchor button.
    private static let anchorButtonSize: CGFloat = 22

    /// One component of the frame a field edits.
    private enum Component {
        case x, y, width, height

        /// The field's axis, for the unit conversion.
        var axis: Axis {
            switch self {
            case .x, .width: .horizontal
            case .y, .height: .vertical
            }
        }

        /// The field's label.
        var label: Text {
            switch self {
            case .x: Text("X", comment: "Layer frame slider label: horizontal position")
            case .y: Text("Y", comment: "Layer frame slider label: vertical position")
            case .width: Text("Width", comment: "Layer frame slider label")
            case .height: Text("Height", comment: "Layer frame slider label")
            }
        }

        /// The field's `tap` name.
        var tapName: String {
            switch self {
            case .x: "layerPositionX.field"
            case .y: "layerPositionY.field"
            case .width: "layerWidth.field"
            case .height: "layerHeight.field"
            }
        }

        /// What an edit of this component did, for the Undo item.
        var undoAction: LayerUndoAction {
            switch self {
            case .x, .y: .moveLayer
            case .width, .height: .resizeLayer
            }
        }

        /// Reads the component from a frame.
        func value(of frame: CGRect) -> CGFloat {
            switch self {
            case .x: frame.origin.x
            case .y: frame.origin.y
            case .width: frame.width
            case .height: frame.height
            }
        }
    }

    /// The inspector, laid out for the column: a two-column grid — the
    /// property's label, then its controls — with the effect chain beneath a
    /// divider.
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                rowLabel(Text("Input", comment: "Layer inspector row: the input the layer is bound to"))
                inputPicker
            }
            GridRow {
                rowLabel(Text("Position", comment: "Layer inspector row: the layer's position"))
                HStack(spacing: 8) {
                    field(.x)
                    field(.y)
                }
            }
            GridRow {
                rowLabel(Text("Size", comment: "Logging settings: label of the row showing the log file's size"))
                HStack(spacing: 8) {
                    field(.width)
                    field(.height)
                }
            }
            // Two lines, not one: the unit toggle, the lock, Match Input,
            // and Reset side by side are wider than the column's narrowest
            // width in every language, so the buttons truncated or pushed
            // past the column's edge (found 2026-09-12).
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                HStack(spacing: 6) {
                    unitPicker
                    Spacer()
                    aspectLock
                }
            }
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                HStack(spacing: 6) {
                    matchInputButton
                    resetButton
                    Spacer(minLength: 0)
                }
            }
            GridRow {
                rowLabel(Text("Placement", comment: "Layer inspector row: the anchor grid and size presets"))
                    .gridCellAnchor(.topLeading)
                // The presets beside the anchor grid where the column has
                // room, beneath it where it does not: beside, the row is
                // wider than the narrowest column in every language (the
                // grid alone is 130 points, measured 2026-09-12), and the
                // presets' titles differ most between languages.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        anchorGrid
                        sizeButtons(along: .vertical)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        anchorGrid
                        sizeButtons(along: .horizontal)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        anchorGrid
                        sizeButtons(along: .vertical)
                    }
                }
            }
            GridRow {
                rowLabel(Text("Opacity", comment: "Layer opacity slider label"))
                HStack(spacing: 6) {
                    opacitySlider
                    opacityField
                }
            }
            GridRow {
                Divider()
                    .gridCellColumns(2)
            }
            GridRow {
                LayerEffectChainView(model: model, layerIndex: index, effects: layer.effects ?? [])
                    .gridCellColumns(2)
            }
            GridRow {
                layerMonitor
                    .gridCellColumns(2)
            }
        }
        .controlSize(.small)
    }

    /// The layer monitor: the selected layer's input as the layer shows
    /// it, after its effect chain, at a size a corner or a crop can be
    /// judged at (ARCHITECTURE.md, "The effect chain says its order, and
    /// the layer gets a monitor"). A monitor in GLOSSARY.md's sense —
    /// nothing reaches viewers from it — badged "Layer" beside the
    /// program and preview monitors' shape. Behind a disclosure that is
    /// **closed by default**, and the tile exists only while it is open:
    /// a closed monitor draws nothing, at no display-rate cost
    /// (``EngineModel/isLayerMonitorDisclosed``).
    private var layerMonitor: some View {
        DisclosureGroup(isExpanded: monitorDisclosureBinding) {
            if model.isLayerMonitorDisclosed {
                MonitorTile(
                    source: LayerMonitorSource(model: model),
                    label: Text("Layer", comment: "Title of the Layer menu, arranging the selected layer"),
                    badgeTint: .gray,
                    aspectRatio: model.programAspectRatio
                )
                .snapshotMenu(model: model, subject: .layer, tapName: "layerMonitorSnapshot.menuItem")
                .padding(.top, 4)
            }
        } label: {
            Text(
                "Layer Monitor",
                comment: "Disclosure heading of the inspector's monitor showing the layer after its effects"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// The disclosure's binding: opening or closing the monitor reports
    /// the click first.
    private var monitorDisclosureBinding: Binding<Bool> {
        $model.isLayerMonitorDisclosed.reportingTap(to: model.eventBus, "layerMonitor.disclosure", domain: .composition)
        {
            ["disclosed": .bool($0)]
        }
    }

    /// A row's leading label, in the inspector's secondary caption style.
    private func rowLabel(_ text: Text) -> some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .leading)
    }

    /// The Input popup: every discovered video input, plus the layer's own
    /// input by its last-known name when it is not among them, so a layer
    /// whose device went away still says what it was.
    ///
    /// It fills the controls column and truncates a long name rather than
    /// taking its natural size: a popup's natural width is its longest
    /// choice's, and a grid column is as wide as its widest cell, so one
    /// long file name among the inputs widened every row beside it and
    /// pushed the inspector past the sidebar's edge (found 2026-09-12).
    private var inputPicker: some View {
        Picker(selection: inputBinding) {
            ForEach(model.layerInputChoices) { choice in
                Text(choice.name).tag(choice.id)
            }
            if !model.isInputAvailable(layer.input) {
                Text(model.inputName(for: layer.input)).tag(layer.input)
            }
        } label: {
            Text("Input", comment: "Layer inspector row: the input the layer is bound to")
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The popup's binding: choosing an input rebinds the layer, reporting
    /// the choice first.
    private var inputBinding: Binding<InputID> {
        Binding {
            currentLayer?.input ?? layer.input
        } set: { input in
            guard input != currentLayer?.input else { return }
            model.eventBus.tap(
                "layerInput.picker",
                domain: .composition,
                params: [
                    "index": .int(index), "input": .string(input.rawValue),
                    "name": .string(model.inputName(for: input)),
                ]
            )
            Task { await model.rebindLayer(at: index, to: input) }
        }
    }

    /// One position or size field with its stepper, and its label beneath —
    /// the shape of Keynote's Arrange inspector. Beside the field, the
    /// labels made the Size row wider than the column's narrowest width in
    /// English, German, and Spanish alike; beneath, both rows fit in all
    /// three (measured 2026-09-12).
    private func field(_ component: Component) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                CommittingNumberField(
                    value: fieldBinding(component).wrappedValue,
                    fractionDigits: unit.fractionDigits,
                    label: component.label
                ) { typed in
                    fieldBinding(component).wrappedValue = typed
                }
                .frame(width: Self.fieldWidth)
                Stepper(value: fieldBinding(component), step: unit.step) {
                    component.label
                }
                .labelsHidden()
            }
            component.label
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A field's binding in the current unit: reads the live frame, and a
    /// commit applies one edit with the aspect rule.
    private func fieldBinding(_ component: Component) -> Binding<Double> {
        Binding {
            unit.value(component.value(of: currentFrame), along: component.axis, in: model.programFormat)
        } set: { value in
            let normalized = unit.normalized(value, along: component.axis, in: model.programFormat)
            let frame = currentFrame
            let edited: CGRect =
                switch component {
                case .x: CGRect(x: normalized, y: frame.minY, width: frame.width, height: frame.height)
                case .y: CGRect(x: frame.minX, y: normalized, width: frame.width, height: frame.height)
                case .width:
                    LayerFrameGesture.settingWidth(normalized, of: frame, holdingAspect: model.holdsLayerAspect)
                case .height:
                    LayerFrameGesture.settingHeight(normalized, of: frame, holdingAspect: model.holdsLayerAspect)
                }
            guard edited != frame else { return }
            model.eventBus.tap(
                component.tapName,
                domain: .composition,
                params: ["index": .int(index), "value": .double(value), "unit": .string(unit.rawValue)]
            )
            applyFrame(edited, component.undoAction)
        }
    }

    /// The pixels/percent toggle.
    private var unitPicker: some View {
        Picker(selection: unitBinding) {
            ForEach(LayerInspectorUnit.allCases, id: \.self) { unit in
                unit.title.tag(unit)
            }
        } label: {
            Text("Unit", comment: "Layer inspector: the pixels/percent unit toggle's accessibility label")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// The unit toggle's binding, reporting the choice.
    private var unitBinding: Binding<LayerInspectorUnit> {
        $unit.reportingTap(to: model.eventBus, "layerUnit.picker", domain: .composition) {
            ["unit": .string($0.rawValue)]
        }
    }

    /// The aspect lock: a toggle drawn as a padlock, reporting each flip.
    /// It holds the proportion for the fields here and for the handles on
    /// the monitor alike (``EngineModel/holdsLayerAspect``).
    private var aspectLock: some View {
        Toggle(isOn: aspectBinding) {
            Label {
                Text("Lock Aspect Ratio", comment: "Layer inspector toggle keeping the layer's proportion")
            } icon: {
                Image(systemName: model.holdsLayerAspect ? "lock.fill" : "lock.open")
            }
            .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .help(Text("Lock Aspect Ratio", comment: "Layer inspector toggle keeping the layer's proportion"))
    }

    /// The lock's binding, reporting each flip.
    private var aspectBinding: Binding<Bool> {
        $model.holdsLayerAspect.reportingTap(to: model.eventBus, "layerAspectLock.toggle", domain: .composition) {
            ["on": .bool($0)]
        }
    }

    /// Match Input: the way back after an accidental stretch — the height
    /// set so the layer shows its input in the input's own proportion, the
    /// width and origin kept. The proportion is the picture's *after the
    /// layer's effect chain*, so a cropped layer matches its crop
    /// (ARCHITECTURE.md, "The Crop effect"). Disabled until the input has
    /// delivered a frame (its proportion is read from the frame) and
    /// while the layer already matches it.
    private var matchInputButton: some View {
        let matched = matchedFrame
        return Button {
            guard let matched else { return }
            model.eventBus.tap("layerMatchAspect.button", domain: .composition, params: ["index": .int(index)])
            applyFrame(matched, .resizeLayer)
        } label: {
            Text("Match Input", comment: "Layer inspector button restoring the input's own aspect ratio")
        }
        .disabled(matched == nil || matched == currentFrame)
        .help(
            Text(
                "Restore the input's own aspect ratio, keeping the width",
                comment: "Tooltip on the layer inspector's Match Input button"))
    }

    /// The frame Match Input would apply, or nil while the input has no
    /// frame to read a proportion from (or the chain leaves no picture).
    private var matchedFrame: CGRect? {
        guard let inputAspect = model.layerPictureAspectRatio(for: currentLayer ?? layer) else { return nil }
        return LayerFrameGesture.matchingAspect(
            currentFrame, inputAspect: inputAspect, programAspect: model.programAspectRatio)
    }

    /// Reset: back to the full frame, `Layer`'s own default.
    private var resetButton: some View {
        Button {
            let full = Layer(input: layer.input).frame
            model.eventBus.tap("layerReset.button", domain: .composition, params: ["index": .int(index)])
            applyFrame(full, .resizeLayer)
        } label: {
            Text("Reset", comment: "Permissions settings: button that forgets the system's decision for a service")
        }
        .disabled(currentFrame == Layer(input: layer.input).frame)
    }

    /// The nine anchors, three rows of three bordered buttons.
    private var anchorGrid: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(LayerPlacement.Anchor.rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { anchor in
                        Button {
                            model.eventBus.tap(
                                "layerAnchor.button",
                                domain: .composition,
                                params: ["index": .int(index), "anchor": .string(anchor.rawValue)]
                            )
                            applyFrame(LayerPlacement.anchoring(currentFrame, at: anchor), .moveLayer)
                        } label: {
                            Image(systemName: anchor.symbol)
                                .frame(width: Self.anchorButtonSize, height: Self.anchorButtonSize)
                        }
                        .buttonStyle(.bordered)
                        .help(anchor.title)
                        .accessibilityLabel(anchor.title)
                    }
                }
            }
        }
        .buttonBorderShape(.roundedRectangle)
    }

    /// The three size presets, stacked beside the anchor grid or laid in a
    /// line beneath it (``body``'s Placement row chooses).
    ///
    /// - Parameter axis: Which way the presets run.
    private func sizeButtons(along axis: Axis) -> some View {
        let layout =
            axis == .vertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            ForEach(LayerPlacement.Size.allCases, id: \.self) { size in
                Button {
                    model.eventBus.tap(
                        "layerSize.button",
                        domain: .composition,
                        params: ["index": .int(index), "size": .string(size.rawValue)]
                    )
                    applyFrame(LayerPlacement.sizing(currentFrame, to: size), .resizeLayer)
                } label: {
                    size.title
                }
            }
        }
    }

    /// The opacity slider, one gesture and one `tap` per drag.
    private var opacitySlider: some View {
        Slider(value: opacityBinding, in: 0...1) { editing in
            if editing {
                model.beginLayerGesture()
                return
            }
            model.endLayerGesture(.changeOpacity)
            model.eventBus.tap(
                "layerOpacity.slider",
                domain: .composition,
                params: ["index": .int(index), "value": .double(currentLayer?.opacity ?? 0)]
            )
        }
    }

    /// The opacity as a percent field, one edit per commit.
    private var opacityField: some View {
        HStack(spacing: 2) {
            CommittingNumberField(
                value: (currentLayer?.opacity ?? 0) * 100,
                fractionDigits: 0,
                label: Text("Opacity", comment: "Layer opacity slider label")
            ) { percent in
                let opacity = min(max(percent / 100, 0), 1)
                guard opacity != currentLayer?.opacity else { return }
                model.eventBus.tap(
                    "layerOpacity.field",
                    domain: .composition,
                    params: ["index": .int(index), "value": .double(opacity)]
                )
                model.setLayerOpacity(opacity, at: index)
            }
            .frame(width: Self.fieldWidth)
            Text(verbatim: "%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A live binding to the layer's opacity, for the slider.
    private var opacityBinding: Binding<Double> {
        Binding {
            currentLayer?.opacity ?? 0
        } set: { newValue in
            model.setLayerOpacity(newValue, at: index)
        }
    }

    /// The layer as the model holds it now — fresher than ``layer`` while a
    /// gesture is applying edits tick by tick.
    private var currentLayer: Layer? {
        guard let layers = model.editedShot?.shot.layers, layers.indices.contains(index) else { return nil }
        return layers[index]
    }

    /// The layer's frame as the model holds it now.
    private var currentFrame: CGRect {
        currentLayer?.frame ?? layer.frame
    }

    /// Applies one frame edit as its own undo step.
    private func applyFrame(_ frame: CGRect, _ action: LayerUndoAction) {
        model.setLayerFrame(frame, at: index, as: action)
    }
}
