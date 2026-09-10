//
//  LayerHandlesOverlay.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// Direct manipulation of the selected layer on the monitor showing the
/// edited shot — the Keynote, Motion, and Final Cut Pro pattern
/// (ARCHITECTURE.md, "Direct manipulation, drag-to-reorder, and undo in the
/// layer-tree editor").
///
/// Drawn inside ``MonitorTile`` over the fitted video rect, so its bounds
/// *are* the program: a layer's normalized top-left-origin frame maps to
/// the view by one scale. The selected layer wears a selection rectangle
/// and eight handles in the tally's tint — green while the shot is only
/// staged, red while the edit is on air. Dragging the body moves the
/// layer; a handle resizes it, Shift — or the inspector's lock
/// (``EngineModel/holdsLayerAspect``) — holding the aspect ratio and Option
/// resizing about the center; a click selects the topmost layer under the
/// pointer, or clears the selection on the background; the arrow keys
/// nudge by 1% (Shift: 10%) and Delete removes. While a drag is within six
/// points of an edge, the center, or a third, the frame snaps and a yellow
/// guide shows why (``LayerSnap``).
///
/// Every gesture is one undo step and one `tap`: a drag calls
/// ``EngineModel/beginLayerGesture()`` at its first movement and
/// ``EngineModel/endLayerGesture(_:)`` at its end, reporting the final frame
/// once (EVENTS.md, "The `tap` convention"). The geometry is
/// ``LayerFrameGesture``'s, pure and unit-tested; this view only maps
/// points to fractions and back.
struct LayerHandlesOverlay: View {
    /// The engine model whose selection and followed shot this manipulates.
    @Bindable var model: EngineModel

    /// The shot being edited, with the tally that tints the handles.
    let edited: EditedShot

    /// The selected layer's frame when the drag in progress began, or nil
    /// between drags. Set on the first movement, which is also when the
    /// gesture is opened on the model.
    @State private var dragOrigin: CGRect?

    /// The guides the current drag has snapped to, or nil while nothing is
    /// dragging.
    @State private var snap: LayerSnap.Result?

    /// The modifier keys down now, for Shift and Option during a resize.
    @State private var modifiers: EventModifiers = []

    /// Whether the overlay has keyboard focus, which the arrow keys and
    /// Delete need. Taken on any click or drag, the way Keynote's canvas
    /// takes it.
    @FocusState private var isFocused: Bool

    /// The drawn size of a handle.
    private static let handleSize: CGFloat = 8

    /// The hit area around a handle — larger than the drawing, so a handle
    /// is easy to grab without being big enough to hide the picture.
    private static let handleHitSize: CGFloat = 16

    /// How near, in points, a drag snaps to a guide.
    private static let snapDistance: CGFloat = 6

    /// The overlay: the guides, the selection rectangle, and the handles,
    /// over a click target the size of the program.
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(.rect)

                if let snap {
                    guides(snap, in: size)
                }

                if let selection = model.selectedLayer {
                    let rect = viewRect(of: selection.layer.frame, in: size)
                    selectionRectangle(rect, index: selection.index, in: size)
                    ForEach(LayerHandle.allCases, id: \.self) { handle in
                        handleView(handle, on: rect, index: selection.index, in: size)
                    }
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                select(at: location, in: size)
            }
        }
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onModifierKeysChanged { _, current in
            modifiers = current
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            nudge(press)
        }
        .onDeleteCommand {
            removeSelectedLayer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text("Layer handles", comment: "Accessibility label of the selected layer's handles on the monitor"))
    }

    /// The selection rectangle: the tint's outline, draggable to move the
    /// layer.
    private func selectionRectangle(_ rect: CGRect, index: Int, in size: CGSize) -> some View {
        Rectangle()
            .stroke(edited.tally.badgeTint, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .contentShape(.rect)
            .position(x: rect.midX, y: rect.midY)
            .gesture(moveGesture(index: index, in: size))
    }

    /// One handle: a white square outlined in the tint, on its point of the
    /// rectangle, draggable to resize.
    private func handleView(_ handle: LayerHandle, on rect: CGRect, index: Int, in size: CGSize) -> some View {
        let unit = handle.unitPosition
        return Rectangle()
            .fill(.white)
            .overlay(Rectangle().stroke(edited.tally.badgeTint, lineWidth: 1))
            .frame(width: Self.handleSize, height: Self.handleSize)
            .frame(width: Self.handleHitSize, height: Self.handleHitSize)
            .contentShape(.rect)
            .position(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
            .gesture(resizeGesture(handle, index: index, in: size))
    }

    /// The smart guides a drag has snapped to: one-point yellow lines
    /// across the whole program, Keynote's color.
    private func guides(_ snap: LayerSnap.Result, in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(snap.verticalGuides, id: \.self) { x in
                Rectangle()
                    .fill(.yellow)
                    .frame(width: 1, height: size.height)
                    .position(x: x * size.width, y: size.height / 2)
            }
            ForEach(snap.horizontalGuides, id: \.self) { y in
                Rectangle()
                    .fill(.yellow)
                    .frame(width: size.width, height: 1)
                    .position(x: size.width / 2, y: y * size.height)
            }
        }
        .allowsHitTesting(false)
    }

    /// The drag that moves the selected layer.
    private func moveGesture(index: Int, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                guard let origin = beginDragIfNeeded(index: index) else { return }
                let moved = LayerFrameGesture.moving(origin, by: normalized(value.translation, in: size))
                let snapped = LayerSnap.snappingMove(moved, threshold: snapThreshold(in: size))
                snap = snapped
                model.setLayerFrame(snapped.frame, at: index)
            }
            .onEnded { _ in
                endDrag(index: index, action: .moveLayer, tapName: "layerMove.drag")
            }
    }

    /// The drag that resizes the selected layer by one handle.
    private func resizeGesture(_ handle: LayerHandle, index: Int, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                guard let origin = beginDragIfNeeded(index: index) else { return }
                let resized = LayerFrameGesture.resizing(
                    origin,
                    handle: handle,
                    by: normalized(value.translation, in: size),
                    holdingAspect: modifiers.contains(.shift) || model.holdsLayerAspect,
                    aboutCenter: modifiers.contains(.option)
                )
                let snapped = LayerSnap.snappingResize(resized, handle: handle, threshold: snapThreshold(in: size))
                snap = snapped
                model.setLayerFrame(snapped.frame, at: index)
            }
            .onEnded { _ in
                endDrag(index: index, action: .resizeLayer, tapName: "layerResize.drag")
            }
    }

    /// Opens the gesture on the model at a drag's first movement, taking
    /// focus and remembering where the frame started; returns that origin
    /// for every movement after.
    ///
    /// - Parameter index: The dragged layer's index.
    /// - Returns: The frame when the drag began, or nil if the layer is
    ///   gone.
    private func beginDragIfNeeded(index: Int) -> CGRect? {
        if let dragOrigin { return dragOrigin }
        guard let selection = model.selectedLayer, selection.index == index else { return nil }
        isFocused = true
        model.beginLayerGesture()
        dragOrigin = selection.layer.frame
        return selection.layer.frame
    }

    /// Closes the gesture: one undo step and one `tap` with the final frame.
    ///
    /// - Parameters:
    ///   - index: The dragged layer's index.
    ///   - action: What the drag did, for the Undo item's name.
    ///   - tapName: The `tap` the drag reports.
    private func endDrag(index: Int, action: LayerUndoAction, tapName: String) {
        defer {
            dragOrigin = nil
            snap = nil
        }
        guard dragOrigin != nil else { return }
        model.endLayerGesture(action)
        guard let frame = model.selectedLayer?.layer.frame else { return }
        model.eventBus.tap(
            tapName,
            domain: .composition,
            params: [
                "index": .int(index),
                "x": .double(frame.origin.x),
                "y": .double(frame.origin.y),
                "width": .double(frame.width),
                "height": .double(frame.height),
            ]
        )
    }

    /// Selects the topmost layer under a click, or clears the selection over
    /// the background, taking focus either way.
    ///
    /// - Parameters:
    ///   - location: The click, in the overlay's points.
    ///   - size: The overlay's size.
    private func select(at location: CGPoint, in size: CGSize) {
        isFocused = true
        let point = CGPoint(x: location.x / size.width, y: location.y / size.height)
        let hit = LayerFrameGesture.layerIndex(at: point, in: edited.shot.layers)
        guard hit != model.selectedLayerIndex else { return }
        model.eventBus.tap("layerSelect.monitor", domain: .composition, params: ["index": .int(hit ?? -1)])
        model.selectedLayerIndex = hit
    }

    /// Nudges the selected layer by an arrow key: 1% of the program, or 10%
    /// with Shift. Each press is its own undo step and its own `tap`.
    ///
    /// - Parameter press: The key press.
    /// - Returns: Handled, so the scroll view above does not also scroll.
    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        guard let selection = model.selectedLayer else { return .ignored }
        let direction: LayerFrameGesture.NudgeDirection? =
            switch press.key {
            case .upArrow: .up
            case .downArrow: .down
            case .leftArrow: .left
            case .rightArrow: .right
            default: nil
            }
        guard let direction else { return .ignored }
        let step = press.modifiers.contains(.shift) ? LayerFrameGesture.largeNudgeStep : LayerFrameGesture.nudgeStep
        model.eventBus.tap(
            "layerNudge.key",
            domain: .composition,
            params: ["index": .int(selection.index), "step": .double(step)]
        )
        model.nudgeLayer(at: selection.index, direction, by: step)
        return .handled
    }

    /// Removes the selected layer on the Delete key.
    private func removeSelectedLayer() {
        guard let selection = model.selectedLayer else { return }
        model.eventBus.tap("layerDelete.key", domain: .composition, params: ["index": .int(selection.index)])
        model.selectedLayerIndex = nil
        Task { await model.removeLayer(at: selection.index) }
    }

    /// A normalized frame in the overlay's points.
    private func viewRect(of frame: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: frame.origin.x * size.width,
            y: frame.origin.y * size.height,
            width: frame.width * size.width,
            height: frame.height * size.height
        )
    }

    /// A drag translation in points as a fraction of the program.
    private func normalized(_ translation: CGSize, in size: CGSize) -> CGSize {
        CGSize(width: translation.width / size.width, height: translation.height / size.height)
    }

    /// The snap distance as a fraction of the program on each axis — six
    /// points is a different fraction of a wide monitor than a narrow one.
    private func snapThreshold(in size: CGSize) -> CGSize {
        CGSize(width: Self.snapDistance / size.width, height: Self.snapDistance / size.height)
    }
}
