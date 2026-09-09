//
//  VerticalSliderTests.swift
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

/// The vertical slider's coordinator: AppKit's continuous action stream
/// becomes SwiftUI's value-plus-editing-bracket shape — a drag is one edit
/// from its first change to the release, and a change with no drag behind
/// it is a whole edit on its own.
@Suite("VerticalSlider")
@MainActor
struct VerticalSliderTests {
    /// A recorder standing in for the binding and the editing callback.
    @MainActor
    final class Recorder {
        /// Every value the coordinator wrote, in order.
        var values: [Double] = []

        /// Every editing transition, in order.
        var editing: [Bool] = []

        /// A slider whose binding and callback write into this recorder.
        var slider: VerticalSlider {
            VerticalSlider(
                value: Binding(get: { self.values.last ?? 0 }, set: { self.values.append($0) }),
                in: 0...1,
                label: "Test"
            ) { self.editing.append($0) }
        }
    }

    @Test("a drag is bracketed as one edit: open on the first change, closed on release")
    func dragIsOneEdit() {
        let recorder = Recorder()
        let coordinator = VerticalSlider.Coordinator(parent: recorder.slider)
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
        let coordinator = VerticalSlider.Coordinator(parent: recorder.slider)
        coordinator.apply(0.5, from: .keyDown)
        #expect(!coordinator.isEditing)
        #expect(recorder.editing == [true, false])
        #expect(recorder.values == [0.5])
    }

    @Test("a change with no event behind it is a whole edit on its own")
    func changeWithoutEventIsAWholeEdit() {
        let recorder = Recorder()
        let coordinator = VerticalSlider.Coordinator(parent: recorder.slider)
        coordinator.apply(0.75, from: nil)
        #expect(!coordinator.isEditing)
        #expect(recorder.editing == [true, false])
        #expect(recorder.values == [0.75])
    }

    @Test("only mouse-down and drag events keep an edit open")
    func onlyDragEventsContinueAnEdit() {
        #expect(VerticalSlider.Coordinator.continuesDrag(.leftMouseDown))
        #expect(VerticalSlider.Coordinator.continuesDrag(.leftMouseDragged))
        #expect(!VerticalSlider.Coordinator.continuesDrag(.leftMouseUp))
        #expect(!VerticalSlider.Coordinator.continuesDrag(.keyDown))
        #expect(!VerticalSlider.Coordinator.continuesDrag(nil))
    }

    @Test("control sizes map onto their AppKit counterparts")
    func controlSizesMap() {
        #expect(VerticalSlider.appKitControlSize(.mini) == .mini)
        #expect(VerticalSlider.appKitControlSize(.small) == .small)
        #expect(VerticalSlider.appKitControlSize(.regular) == .regular)
        #expect(VerticalSlider.appKitControlSize(.large) == .large)
        #expect(VerticalSlider.appKitControlSize(.extraLarge) == .large)
    }
}
