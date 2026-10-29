//
//  CameraSlider.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI

/// A horizontal slider for a camera control that returns to the control's
/// default on a **double-click**: a stock `NSSlider` in SwiftUI.
///
/// SwiftUI's `Slider` cannot carry the reset: its `NSSlider` tracks each
/// click inside `mouseDown`, so a tap gesture added beside it never sees
/// the second click. ``ResettableSlider`` catches that click itself — the
/// second click of a double-click arrives as its own event with
/// `clickCount == 2` — the same fix as the main app's fader slider
/// (ARCHITECTURE.md, "The console mixer").
///
/// Mirrors `Slider(value:in:onEditingChanged:)`: the binding updates
/// continuously through a drag, and `onEditingChanged` brackets the
/// gesture — `true` on its first change, `false` on release — so callers
/// keep the drag-end `tap` convention (EVENTS.md, "The `tap` convention").
/// A keyboard step or a click on the track is a whole edit on its own.
/// Enablement comes from the SwiftUI environment, so `.disabled(_:)`
/// applies as it would to any control.
struct CameraSlider: NSViewRepresentable {
    /// The slider's position, updated continuously as it drags.
    @Binding var value: Double

    /// The slider's range, left to right.
    let range: ClosedRange<Double>

    /// The slider's accessibility label. Set on the `NSSlider` itself: an
    /// AppKit view is its own accessibility element, so SwiftUI's
    /// `accessibilityLabel` would not reach it.
    let label: String

    /// Called on a double-click, in place of a drag — the control's reset.
    let onDoubleClick: () -> Void

    /// Called with `true` when an edit begins and `false` when it ends.
    let onEditingChanged: (Bool) -> Void

    /// The surrounding enablement, mirrored onto the `NSSlider`.
    @Environment(\.isEnabled) private var isEnabled

    /// Creates a slider over `value` within `range`.
    ///
    /// - Parameters:
    ///   - value: The position the slider edits.
    ///   - range: The slider's range, left to right.
    ///   - label: The accessibility label.
    ///   - onDoubleClick: Called on a double-click in place of a drag.
    ///   - onEditingChanged: Called as an edit begins (`true`) and ends
    ///     (`false`).
    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        label: String,
        onDoubleClick: @escaping () -> Void,
        onEditingChanged: @escaping (Bool) -> Void
    ) {
        self._value = value
        self.range = range
        self.label = label
        self.onDoubleClick = onDoubleClick
        self.onEditingChanged = onEditingChanged
    }

    /// Builds the coordinator that receives the slider's action.
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Creates the continuous slider, wired to the coordinator for both its
    /// action and its double-click.
    func makeNSView(context: Context) -> ResettableSlider {
        let slider = ResettableSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.sliderChanged(_:))
        )
        slider.isContinuous = true
        slider.onDoubleClick = { [weak coordinator = context.coordinator] in coordinator?.doubleClicked() }
        return slider
    }

    /// Mirrors the SwiftUI side onto the `NSSlider`: value, range,
    /// enablement, and label. The value is left alone mid-drag — the slider
    /// is the source of truth while the operator holds it, and a binding
    /// that lands a step late must not snap the knob back under the
    /// pointer.
    func updateNSView(_ slider: ResettableSlider, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isEditing, slider.doubleValue != value {
            slider.doubleValue = value
        }
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isEnabled = isEnabled
        slider.setAccessibilityLabel(label)
    }

    /// Receives the slider's action and turns AppKit's continuous action
    /// stream into SwiftUI's value-plus-editing-bracket shape.
    @MainActor
    final class Coordinator: NSObject {
        /// The representable, refreshed on every SwiftUI update so the
        /// action always writes the current binding.
        var parent: CameraSlider

        /// Whether a drag is in progress — between the first change and the
        /// release.
        private(set) var isEditing = false

        /// Creates the coordinator for `parent`.
        init(parent: CameraSlider) {
            self.parent = parent
        }

        /// The `NSSlider` action: reads the value and the event that caused
        /// the change, so a drag is bracketed as one edit and a release ends
        /// it.
        @objc func sliderChanged(_ sender: NSSlider) {
            if !isEditing {
                isEditing = true
                parent.onEditingChanged(true)
            }
            parent.value = sender.doubleValue
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseDragged:
                // Mid-drag: the edit stays open for the next change.
                return
            default:
                isEditing = false
                parent.onEditingChanged(false)
            }
        }

        /// A double-click on the slider: forwarded to the representable's
        /// reset.
        func doubleClicked() {
            parent.onDoubleClick()
        }
    }
}

/// The `NSSlider` behind ``CameraSlider``: a stock slider that hands a
/// double-click to ``onDoubleClick`` instead of tracking it as a drag. The
/// first click of the pair is tracked as usual (AppKit tracks a whole drag
/// inside `mouseDown`), so a double-click first lands the knob where it was
/// clicked and then resets it.
final class ResettableSlider: NSSlider {
    /// Called on a double-click, in place of the drag.
    var onDoubleClick: (() -> Void)?

    /// Catches the second click of a double-click before AppKit tracks it,
    /// and otherwise tracks the drag as any slider does.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        super.mouseDown(with: event)
    }
}
