//
//  EditedShotTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraComposition

@testable import TingraApp

@Suite("EditedShot")
struct EditedShotTests {
    /// Two authored shots, the pool the editor resolves against.
    private let wide = Shot(id: ShotID(rawValue: "wide"), name: "Wide")
    private let close = Shot(id: ShotID(rawValue: "close"), name: "Close-up")

    /// The pool in switcher order.
    private var shots: [Shot] { [wide, close] }

    @Test("a shot staged on preview is the one edited, and reads staged")
    func previewStagedEditsTheStagedShot() {
        let edited = EditedShot.following(shots: shots, previewShotID: close.id, activeShotID: wide.id)

        #expect(edited?.shot == close)
        #expect(edited?.tally == .staged)
        #expect(edited?.isOnAir == false)
    }

    @Test("with nothing staged the program shot is edited, and reads on air")
    func nothingStagedEditsTheProgramShot() {
        let edited = EditedShot.following(shots: shots, previewShotID: nil, activeShotID: wide.id)

        #expect(edited?.shot == wide)
        #expect(edited?.tally == .onAir)
        #expect(edited?.isOnAir == true)
    }

    @Test("the same shot on both buses reads on air — red wins over green")
    func sameShotOnBothBusesIsOnAir() {
        let edited = EditedShot.following(shots: shots, previewShotID: close.id, activeShotID: close.id)

        #expect(edited?.shot == close)
        #expect(edited?.tally == .onAir)
        #expect(edited?.isOnAir == true)
    }

    @Test("no shot on either bus follows nothing")
    func noShotOnEitherBusFollowsNothing() {
        #expect(EditedShot.following(shots: shots, previewShotID: nil, activeShotID: nil) == nil)
        #expect(EditedShot.following(shots: [], previewShotID: wide.id, activeShotID: wide.id) == nil)
    }

    @Test("a held program snapshot outside the pool is not followed")
    func heldSnapshotIsNotFollowed() {
        // A preset switch can keep a shot on program that the loaded pool no
        // longer holds; there is nowhere to store an edit to it.
        let held = ShotID(rawValue: "from-another-preset")

        #expect(EditedShot.following(shots: shots, previewShotID: nil, activeShotID: held) == nil)
    }

    @Test("equal and unequal values compare as such")
    func equatable() {
        let a = EditedShot(shot: wide, tally: .staged)
        let b = EditedShot(shot: wide, tally: .staged)
        let c = EditedShot(shot: wide, tally: .onAir)

        #expect(a == b)
        #expect(a != c)
    }
}
