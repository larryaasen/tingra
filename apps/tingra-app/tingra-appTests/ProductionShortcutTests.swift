//
//  ProductionShortcutTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import Testing

@testable import TingraApp

@MainActor
@Suite("ProductionShortcut")
struct ProductionShortcutTests {
    @Test("the pane lists seven shortcuts — the five most common, the take, and the status bar")
    func theListIsTheFiveCommonOnesPlusTheTakeAndTheStatusBar() {
        #expect(ProductionShortcut.allCases.count == 7)
        #expect(ProductionShortcut.allCases.contains(.take))
        #expect(ProductionShortcut.allCases.contains(.toggleStatusBar))
        #expect(Set(ProductionShortcut.allCases).count == 7)
    }

    @Test("the list reads stage, the two takes, the program controls, then the window command")
    func theCaseOrderIsTheReadingOrder() {
        #expect(
            ProductionShortcut.allCases == [
                .stageShot, .cut, .take, .fadeToBlack, .goLive, .record, .toggleStatusBar,
            ]
        )
    }

    @Test("the status bar is ⌘/ — the Finder's and Safari's assignment for it")
    func theStatusBarIsCommandSlash() {
        #expect(ProductionShortcut.toggleStatusBar.key?.character == "/")
        #expect(ProductionShortcut.toggleStatusBar.modifiers == .command)
        #expect(ProductionShortcut.toggleStatusBar.symbol == "⌘/")
    }

    @Test("the take is ⌘Return — the industry's take key, not ⌘T")
    func theTakeIsCommandReturn() {
        #expect(ProductionShortcut.take.key?.character == KeyEquivalent.return.character)
        #expect(ProductionShortcut.take.modifiers == .command)
        #expect(ProductionShortcut.take.symbol == "⌘↩")
    }

    @Test("the cut is the take plus Shift, as it is on a hardware panel")
    func theCutIsTheTakePlusShift() {
        #expect(ProductionShortcut.cut.key?.character == ProductionShortcut.take.key?.character)
        #expect(ProductionShortcut.cut.modifiers == [.command, .shift])
        #expect(ProductionShortcut.cut.symbol == "⇧⌘↩")
    }

    @Test("each shortcut prints the combination macOS would print for it")
    func symbolsMatchTheSystemsOwnSpelling() {
        #expect(ProductionShortcut.stageShot.symbol == "⌘1 – ⌘9")
        #expect(ProductionShortcut.fadeToBlack.symbol == "⇧⌘B")
        #expect(ProductionShortcut.goLive.symbol == "⌘G")
        #expect(ProductionShortcut.record.symbol == "⌘R")
        #expect(ProductionShortcut.toggleStatusBar.symbol == "⌘/")
    }

    @Test("modifier glyphs are printed in the system's order, Shift before Command")
    func modifierGlyphsAreInTheSystemsOrder() {
        // ⇧⌘B, never ⌘⇧B — a menu prints the former, and a settings pane
        // that printed the latter would read as a different shortcut.
        #expect(ProductionShortcut.fadeToBlack.symbol.hasPrefix("⇧⌘"))
    }

    @Test("no two shortcuts claim the same combination")
    func combinationsAreDistinct() {
        let combinations = ProductionShortcut.allCases.compactMap { shortcut -> String? in
            guard let character = shortcut.key?.character else { return nil }
            return "\(shortcut.modifiers.rawValue)-\(character)"
        }
        #expect(Set(combinations).count == combinations.count)
    }

    @Test("staging is the one shortcut with a range of keys rather than one")
    func stagingIsTheOnlyRange() {
        let withoutASingleKey = ProductionShortcut.allCases.filter { $0.key == nil }
        #expect(withoutASingleKey == [.stageShot])
    }

    @Test("the first nine switcher positions stage on ⌘1 through ⌘9")
    func theFirstNinePositionsAreBound() {
        #expect(ProductionShortcut.stageShotKey(forIndex: 0)?.character == "1")
        #expect(ProductionShortcut.stageShotKey(forIndex: 4)?.character == "5")
        #expect(ProductionShortcut.stageShotKey(forIndex: 8)?.character == "9")
        #expect(ProductionShortcut.stageShotShortcut(forIndex: 0)?.modifiers == .command)
    }

    @Test("a tenth shot, and a nonsensical position, are simply unbound")
    func positionsOutsideTheRangeAreUnbound() {
        #expect(ProductionShortcut.stageShotKey(forIndex: 9) == nil)
        #expect(ProductionShortcut.stageShotKey(forIndex: 42) == nil)
        #expect(ProductionShortcut.stageShotKey(forIndex: -1) == nil)
        #expect(ProductionShortcut.stageShotShortcut(forIndex: 9) == nil)
    }

    @Test("every bound position produces a shortcut, and no position past the limit does")
    func boundPositionsMatchTheStatedLimit() {
        let bound = (0..<20).compactMap { ProductionShortcut.stageShotShortcut(forIndex: $0) }
        #expect(bound.count == ProductionShortcut.stageShotLimit)
    }

    @Test("every shortcut the app binds is expressible to SwiftUI")
    func everySingleKeyShortcutIsBindable() {
        for shortcut in ProductionShortcut.allCases where shortcut != .stageShot {
            #expect(shortcut.shortcut != nil, "\(shortcut.rawValue) has no bindable shortcut")
            #expect(shortcut.shortcut?.modifiers == shortcut.modifiers)
        }
    }
}
