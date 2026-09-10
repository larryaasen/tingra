//
//  LayerArrangeCommandTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import Testing

@testable import TingraApp

@Suite("LayerArrangeCommand")
struct LayerArrangeCommandTests {
    @Test("nothing is available without a selection or with a stale index")
    func unavailableWithoutSelection() {
        for command in LayerArrangeCommand.allCases {
            #expect(!command.isAvailable(index: nil, count: 3))
            #expect(!command.isAvailable(index: 3, count: 3))
            #expect(!command.isAvailable(index: -1, count: 3))
        }
    }

    @Test("a move that would go nowhere is disabled at the ends of the stack")
    func endsOfStack() {
        #expect(!LayerArrangeCommand.bringToFront.isAvailable(index: 2, count: 3))
        #expect(!LayerArrangeCommand.bringForward.isAvailable(index: 2, count: 3))
        #expect(LayerArrangeCommand.sendBackward.isAvailable(index: 2, count: 3))
        #expect(LayerArrangeCommand.sendToBack.isAvailable(index: 2, count: 3))
        #expect(!LayerArrangeCommand.sendBackward.isAvailable(index: 0, count: 3))
        #expect(!LayerArrangeCommand.sendToBack.isAvailable(index: 0, count: 3))
        #expect(LayerArrangeCommand.bringToFront.isAvailable(index: 0, count: 3))
        #expect(LayerArrangeCommand.duplicate.isAvailable(index: 0, count: 1))
        #expect(LayerArrangeCommand.delete.isAvailable(index: 0, count: 1))
    }

    @Test("the arrange moves land at the top, one up, one down, and the bottom")
    func destinations() {
        #expect(LayerArrangeCommand.bringToFront.destination(from: 1, count: 4) == 3)
        #expect(LayerArrangeCommand.bringForward.destination(from: 1, count: 4) == 2)
        #expect(LayerArrangeCommand.sendBackward.destination(from: 1, count: 4) == 0)
        #expect(LayerArrangeCommand.sendToBack.destination(from: 1, count: 4) == 0)
        #expect(LayerArrangeCommand.duplicate.destination(from: 1, count: 4) == nil)
        #expect(LayerArrangeCommand.delete.destination(from: 1, count: 4) == nil)
    }

    @Test("the keys are Keynote's, distinct, and Delete has none")
    func shortcuts() {
        #expect(LayerArrangeCommand.bringToFront.key == "]")
        #expect(LayerArrangeCommand.bringToFront.modifiers == [.command, .shift])
        #expect(LayerArrangeCommand.bringForward.key == "]")
        #expect(LayerArrangeCommand.bringForward.modifiers == .command)
        #expect(LayerArrangeCommand.sendBackward.key == "[")
        #expect(LayerArrangeCommand.sendToBack.modifiers == [.command, .shift])
        #expect(LayerArrangeCommand.duplicate.key == "d")
        #expect(LayerArrangeCommand.delete.key == nil)
        #expect(LayerArrangeCommand.delete.shortcut == nil)
        let bound = LayerArrangeCommand.allCases.compactMap { command in
            command.key.map { "\($0.character)-\(command.modifiers.rawValue)" }
        }
        #expect(Set(bound).count == bound.count)
        #expect(bound.count == 5)
    }

    @Test("only Duplicate opens the second group")
    func groups() {
        #expect(LayerArrangeCommand.allCases.filter(\.opensGroup) == [.duplicate])
    }

    @Test("tap names carry the surface's suffix")
    func tapNames() {
        #expect(LayerArrangeCommand.bringToFront.tapName(from: .menuBar) == "layerBringToFront.menuItem")
        #expect(LayerArrangeCommand.delete.tapName(from: .contextMenu) == "layerDelete.menu")
        let names = LayerArrangeCommand.allCases.map { $0.tapName(from: .menuBar) }
        #expect(Set(names).count == names.count)
    }

    @Test("every undo action has a distinct raw value and a title")
    func undoActions() {
        let raw = LayerUndoAction.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count)
        for action in LayerUndoAction.allCases {
            #expect(!action.title.isEmpty)
        }
    }
}
