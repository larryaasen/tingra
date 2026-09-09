//
//  VerticalSlider.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI

/// A vertical slider: an `NSSlider` standing on end, for the mixer's master
/// column, where the monitor level is a fader beside the master meter
/// (GLOSSARY.md, "Master"). SwiftUI's `Slider` lays out horizontally only,
/// and rotating one is a layout trick rather than a control, so this is
/// AppKit where SwiftUI does not cover the need — the `MTKView` rule
/// applied to a control.
///
/// Mirrors `Slider(value:in:onEditingChanged:)`: the binding updates
/// continuously through a drag, and `onEditingChanged` brackets the
/// gesture — `true` on its first change, `false` on release — so callers
/// keep the drag-end `tap` convention (EVENTS.md, "The `tap` convention").
/// A keyboard step or a click on the track is a whole edit on its own,
/// bracketed in one go. Control size and enablement come from the SwiftUI
/// environment, so `.controlSize(.small)` and `.disabled(_:)` apply as they
/// would to any control.
struct VerticalSlider: NSViewRepresentable {
    /// The slider's value, updated continuously as it drags.
    @Binding var value: Double

    /// The slider's range, bottom to top.
    let range: ClosedRange<Double>

    /// The slider's accessibility label and tool tip. Set on the `NSSlider`
    /// itself: an AppKit view is its own accessibility element, so SwiftUI's
    /// `accessibilityLabel` would not reach it.
    let label: String

    /// Called with `true` when an edit begins and `false` when it ends.
    let onEditingChanged: (Bool) -> Void

    /// The surrounding control size, mirrored onto the `NSSlider`.
    @Environment(\.controlSize) private var controlSize

    /// The surrounding enablement, mirrored onto the `NSSlider`.
    @Environment(\.isEnabled) private var isEnabled

    /// Creates a vertical slider over `value` within `range`.
    ///
    /// - Parameters:
    ///   - value: The value the slider edits.
    ///   - range: The slider's range, bottom to top.
    ///   - label: The accessibility label and tool tip.
    ///   - onEditingChanged: Called as an edit begins (`true`) and ends
    ///     (`false`).
    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        label: String,
        onEditingChanged: @escaping (Bool) -> Void
    ) {
        self._value = value
        self.range = range
        self.label = label
        self.onEditingChanged = onEditingChanged
    }

    /// Builds the coordinator that receives the slider's action.
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Creates the `NSSlider`, standing, continuous, wired to the
    /// coordinator.
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.sliderChanged(_:))
        )
        slider.isVertical = true
        slider.isContinuous = true
        return slider
    }

    /// Mirrors the SwiftUI side onto the `NSSlider`: value, range, control
    /// size, enablement, and label. The value is left alone mid-drag — the
    /// slider is the source of truth while the operator holds it, and a
    /// binding that lands a step late must not snap the knob back under the
    /// pointer.
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isEditing, slider.doubleValue != value {
            slider.doubleValue = value
        }
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.controlSize = Self.appKitControlSize(controlSize)
        slider.isEnabled = isEnabled
        slider.toolTip = label
        slider.setAccessibilityLabel(label)
    }

    /// The `NSControl` size matching a SwiftUI control size.
    static func appKitControlSize(_ size: ControlSize) -> NSControl.ControlSize {
        switch size {
        case .mini: .mini
        case .small: .small
        case .large, .extraLarge: .large
        default: .regular
        }
    }

    /// Receives the slider's action and turns AppKit's continuous action
    /// stream into SwiftUI's value-plus-editing-bracket shape.
    @MainActor
    final class Coordinator: NSObject {
        /// The representable, refreshed on every SwiftUI update so the
        /// action always writes the current binding.
        var parent: VerticalSlider

        /// Whether a drag is in progress — between the first change and the
        /// release.
        private(set) var isEditing = false

        /// Creates the coordinator for `parent`.
        init(parent: VerticalSlider) {
            self.parent = parent
        }

        /// The `NSSlider` action: reads the value and the event that caused
        /// the change, so a drag is bracketed as one edit and a release ends
        /// it.
        @objc func sliderChanged(_ sender: NSSlider) {
            apply(sender.doubleValue, from: NSApp.currentEvent?.type)
        }

        /// The action's logic, apart from the `NSSlider` so it is testable:
        /// opens an edit on the first change, writes the value, and closes
        /// the edit unless the change came mid-drag. A change with no mouse
        /// event behind it — a keyboard step, a programmatic set — is a whole
        /// edit on its own.
        ///
        /// - Parameters:
        ///   - newValue: The slider's new value.
        ///   - eventType: The type of the event that caused the change, if
        ///     any.
        func apply(_ newValue: Double, from eventType: NSEvent.EventType?) {
            if !isEditing {
                isEditing = true
                parent.onEditingChanged(true)
            }
            parent.value = newValue
            guard !Self.continuesDrag(eventType) else { return }
            isEditing = false
            parent.onEditingChanged(false)
        }

        /// Whether an event type is the middle of a mouse drag — the one case
        /// that leaves the edit open for the next change.
        static func continuesDrag(_ eventType: NSEvent.EventType?) -> Bool {
            switch eventType {
            case .leftMouseDown, .leftMouseDragged: true
            default: false
            }
        }
    }
}
