//
//  AddShotMenuSurfaceTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApp

@Suite("AddShotMenuSurface")
struct AddShotMenuSurfaceTests {
    @Test("the sidebar's Shots section menu reports its own names")
    func sidebarNames() {
        let surface = AddShotMenuSurface.sidebar
        #expect(surface.tapName(for: .empty) == "sidebarShotAddEmpty.menuItem")
        #expect(surface.tapName(for: .input) == "sidebarShotAddInput.menuItem")
        #expect(surface.tapName(for: .addWindow) == "sidebarShotAddWindow.menuItem")
    }

    @Test("the bank heading's plus button reports its own names")
    func bankNames() {
        let surface = AddShotMenuSurface.bank
        #expect(surface.tapName(for: .empty) == "shotBankAddEmpty.menuItem")
        #expect(surface.tapName(for: .input) == "shotBankAddInput.menuItem")
        #expect(surface.tapName(for: .addWindow) == "shotBankAddWindow.menuItem")
    }

    @Test("the menu bar's Shots menu reports its own names")
    func menuBarNames() {
        let surface = AddShotMenuSurface.menuBar
        #expect(surface.tapName(for: .empty) == "shotsMenuAddEmpty.menuItem")
        #expect(surface.tapName(for: .input) == "shotsMenuAddInput.menuItem")
        #expect(surface.tapName(for: .addWindow) == "shotsMenuAddWindow.menuItem")
    }

    @Test("no two surfaces share a tap name for any item, and no surface reuses one across items")
    func namesAreDistinct() {
        var names: Set<String> = []
        for surface in AddShotMenuSurface.allCases {
            for item in AddShotMenuSurface.Item.allCases {
                names.insert(surface.tapName(for: item))
            }
        }
        #expect(names.count == AddShotMenuSurface.allCases.count * AddShotMenuSurface.Item.allCases.count)
    }
}
