//
//  PresetMenuSurfaceTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApp

@Suite("PresetMenuSurface")
struct PresetMenuSurfaceTests {
    @Test("the sidebar reports its own names, moving up and down rather than left and right")
    func sidebarReportsItsOwnNames() {
        let surface = PresetMenuSurface.sidebar
        #expect(surface.tapName(for: .duplicate) == "sidebarPresetDuplicate.menu")
        #expect(surface.tapName(for: .rename) == "sidebarPresetRename.menu")
        #expect(surface.tapName(for: .moveEarlier) == "sidebarPresetMoveUp.menu")
        #expect(surface.tapName(for: .moveLater) == "sidebarPresetMoveDown.menu")
        #expect(surface.tapName(for: .remove) == "sidebarPresetRemove.menu")
        #expect(surface.tapName(for: .renameConfirm) == "sidebarPresetRenameConfirm.button")
        #expect(surface.tapName(for: .renameCancel) == "sidebarPresetRenameCancel.button")
    }

    @Test("no two surfaces share a tap name for any action, and no surface reuses one across actions")
    func namesAreDistinctAcrossSurfacesAndActions() {
        var names: Set<String> = []
        for surface in PresetMenuSurface.allCases {
            for action in PresetMenuSurface.Action.allCases {
                names.insert(surface.tapName(for: action))
            }
        }
        #expect(names.count == PresetMenuSurface.allCases.count * PresetMenuSurface.Action.allCases.count)
    }
}
