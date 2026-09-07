//
//  ShotMenuSurfaceTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApp

@Suite("ShotMenuSurface")
struct ShotMenuSurfaceTests {
    @Test("the switcher keeps the tap names its shot buttons have always reported")
    func switcherKeepsItsNames() {
        let surface = ShotMenuSurface.switcher
        #expect(surface.tapName(for: .duplicate) == "shotDuplicate.menu")
        #expect(surface.tapName(for: .rename) == "shotRename.menu")
        #expect(surface.tapName(for: .defaultTransition) == "shotDefaultTransition.menu")
        #expect(surface.tapName(for: .moveEarlier) == "shotMoveLeft.menu")
        #expect(surface.tapName(for: .moveLater) == "shotMoveRight.menu")
        #expect(surface.tapName(for: .remove) == "shotRemove.menu")
        #expect(surface.tapName(for: .renameConfirm) == "shotRenameConfirm.button")
        #expect(surface.tapName(for: .renameCancel) == "shotRenameCancel.button")
    }

    @Test("the sidebar reports its own names, moving up and down, and keeps its Delete name")
    func sidebarReportsItsOwnNames() {
        let surface = ShotMenuSurface.sidebar
        #expect(surface.tapName(for: .duplicate) == "sidebarShotDuplicate.menu")
        #expect(surface.tapName(for: .rename) == "sidebarShotRename.menu")
        #expect(surface.tapName(for: .defaultTransition) == "sidebarShotDefaultTransition.menu")
        #expect(surface.tapName(for: .moveEarlier) == "sidebarShotMoveUp.menu")
        #expect(surface.tapName(for: .moveLater) == "sidebarShotMoveDown.menu")
        #expect(surface.tapName(for: .remove) == "sidebarShotDelete.menu")
        #expect(surface.tapName(for: .renameConfirm) == "sidebarShotRenameConfirm.button")
        #expect(surface.tapName(for: .renameCancel) == "sidebarShotRenameCancel.button")
    }

    @Test("no two surfaces share a tap name for any action, and no surface reuses one across actions")
    func namesAreDistinctAcrossSurfacesAndActions() {
        var names: Set<String> = []
        for surface in ShotMenuSurface.allCases {
            for action in ShotMenuSurface.Action.allCases {
                names.insert(surface.tapName(for: action))
            }
        }
        #expect(names.count == ShotMenuSurface.allCases.count * ShotMenuSurface.Action.allCases.count)
    }
}
