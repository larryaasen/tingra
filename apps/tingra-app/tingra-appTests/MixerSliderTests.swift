//
//  MixerSliderTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import Testing

@testable import TingraApp

/// The mixer slider's coordinator: AppKit's continuous action stream
/// becomes SwiftUI's value-plus-editing-bracket shape — a drag is one edit
/// from its first change to the release, and a change with no drag behind
/// it is a whole edit on its own.
@Suite("MixerSlider")
@MainActor
struct MixerSliderTests {
    /// A recorder standing in for the binding and the editing callback.
    @MainActor
    final class Recorder {
        /// Every value the coordinator wrote, in order.
        var values: [Double] = []

        /// Every editing transition, in order.
        var editing: [Bool] = []

        /// How many double-clicks reached the callback.
        var doubleClicks = 0

        /// A slider whose binding and callback write into this recorder.
        var slider: MixerSlider {
            MixerSlider(
                value: Binding(get: { self.values.last ?? 0 }, set: { self.values.append($0) }),
                in: 0...1,
                label: "Test",
                onDoubleClick: { self.doubleClicks += 1 }
            ) { self.editing.append($0) }
        }
    }

    @Test("a double-click reaches the reset callback and moves nothing")
    func doubleClickReachesTheCallback() {
        let recorder = Recorder()
        let coordinator = MixerSlider.Coordinator(parent: recorder.slider)
        coordinator.doubleClicked()
        #expect(recorder.doubleClicks == 1)
        #expect(recorder.values.isEmpty)
        #expect(recorder.editing.isEmpty)
    }

    @Test("a double-click with no callback is a no-op")
    func doubleClickWithoutCallback() {
        let recorder = Recorder()
        let slider = MixerSlider(
            value: Binding(get: { 0 }, set: { recorder.values.append($0) }),
            in: 0...1,
            label: "Test"
        ) { recorder.editing.append($0) }
        let coordinator = MixerSlider.Coordinator(parent: slider)
        coordinator.doubleClicked()
        #expect(recorder.values.isEmpty)
        #expect(recorder.editing.isEmpty)
    }

    @Test("a drag is bracketed as one edit: open on the first change, closed on release")
    func dragIsOneEdit() {
        let recorder = Recorder()
        let coordinator = MixerSlider.Coordinator(parent: recorder.slider)
        coordinator.apply(0.2, from: .leftMouseDown)
        coordinator.apply(0.4, from: .leftMouseDragged)
        coordinator.apply(0.6, from: .leftMouseDragged)
        #expect(coordinator.isEditing)
        #expect(recorder.editing == [true])
        coordinator.apply(0.6, from: .leftMouseUp)
        #expect(!coordinator.isEditing)
        #expect(recorder.editing == [true, false])
        #expect(recorder.values == [0.2, 0.4, 0.6, 0.6])
    }

    @Test("a keyboard step is a whole edit on its own")
    func keyboardStepIsAWholeEdit() {
        let recorder = Recorder()
        let coordinator = MixerSlider.Coordinator(parent: recorder.slider)
        coordinator.apply(0.5, from: .keyDown)
        #expect(!coordinator.isEditing)
        #expect(recorder.editing == [true, false])
        #expect(recorder.values == [0.5])
    }

    @Test("a change with no event behind it is a whole edit on its own")
    func changeWithoutEventIsAWholeEdit() {
        let recorder = Recorder()
        let coordinator = MixerSlider.Coordinator(parent: recorder.slider)
        coordinator.apply(0.75, from: nil)
        #expect(!coordinator.isEditing)
        #expect(recorder.editing == [true, false])
        #expect(recorder.values == [0.75])
    }

    @Test("only mouse-down and drag events keep an edit open")
    func onlyDragEventsContinueAnEdit() {
        #expect(MixerSlider.Coordinator.continuesDrag(.leftMouseDown))
        #expect(MixerSlider.Coordinator.continuesDrag(.leftMouseDragged))
        #expect(!MixerSlider.Coordinator.continuesDrag(.leftMouseUp))
        #expect(!MixerSlider.Coordinator.continuesDrag(.keyDown))
        #expect(!MixerSlider.Coordinator.continuesDrag(nil))
    }

    @Test("a fader stands on end by default and a pan lies flat when asked")
    func axisDefaultsToVertical() {
        let fader = MixerSlider(value: .constant(0), in: 0...1, label: "Level") { _ in }
        let pan = MixerSlider(value: .constant(0), in: -1...1, axis: .horizontal, label: "Pan") { _ in }
        #expect(fader.axis == .vertical)
        #expect(pan.axis == .horizontal)
    }

    @Test("the second click of a double-click reaches the reset instead of a drag")
    func secondClickReachesTheReset() throws {
        let slider = FaderSlider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
        var resets = 0
        slider.onDoubleClick = { resets += 1 }
        let secondClick = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        slider.mouseDown(with: secondClick)
        #expect(resets == 1)
        #expect(slider.doubleValue == 0.25)
    }

    @Test("control sizes map onto their AppKit counterparts")
    func controlSizesMap() {
        #expect(MixerSlider.appKitControlSize(.mini) == .mini)
        #expect(MixerSlider.appKitControlSize(.small) == .small)
        #expect(MixerSlider.appKitControlSize(.regular) == .regular)
        #expect(MixerSlider.appKitControlSize(.large) == .large)
        #expect(MixerSlider.appKitControlSize(.extraLarge) == .large)
    }
}
