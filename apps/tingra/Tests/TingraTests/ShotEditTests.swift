//
//  ShotEditTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Testing
import TingraComposition
import TingraPlugInKit

@testable import Tingra

/// The pure shot-management operations behind the switcher's add, duplicate,
/// and rename commands (see ARCHITECTURE.md, "Shot management").
@Suite("ShotEdit")
struct ShotEditTests {
    /// A shot with a distinctive layer tree, background, and default
    /// transition, standing in for an operator-edited shot.
    private func makeShot(id: String = "interview", name: String = "Interview") -> Shot {
        Shot(
            id: ShotID(rawValue: id),
            name: name,
            layers: [
                Layer(input: InputID(rawValue: "display-1")),
                Layer(input: InputID(rawValue: "camera-1"), frame: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)),
            ],
            background: BackgroundColor(red: 0.1, green: 0.2, blue: 0.3),
            defaultTransition: .dissolve
        )
    }

    @Test("a new shot is empty over black with a fresh id and a non-empty name")
    func newShotIsEmptyOverBlack() {
        let shot = ShotEdit.newShot()

        #expect(shot.layers.isEmpty)
        #expect(shot.background == .black)
        #expect(!shot.name.isEmpty)
    }

    @Test("every new shot gets its own fresh id")
    func newShotsHaveDistinctIDs() {
        #expect(ShotEdit.newShot().id != ShotEdit.newShot().id)
    }

    @Test("a duplicate copies the source's layer tree, background, and default transition under a fresh id")
    func duplicateCopiesLayersUnderFreshID() {
        let source = makeShot()

        let copy = ShotEdit.duplicate(of: source)

        #expect(copy.id != source.id)
        #expect(copy.layers == source.layers)
        #expect(copy.background == source.background)
        #expect(copy.defaultTransition == source.defaultTransition)
        // The copy is named after its source, and never collides with it.
        #expect(copy.name.contains(source.name))
        #expect(copy != source)
    }

    @Test("every duplicate gets its own fresh id")
    func duplicatesHaveDistinctIDs() {
        let source = makeShot()
        #expect(ShotEdit.duplicate(of: source).id != ShotEdit.duplicate(of: source).id)
    }

    @Test("renaming replaces the name and preserves the shot's identity, layers, background, and default transition")
    func renamingPreservesIdentity() {
        let shot = makeShot()

        let renamed = ShotEdit.renaming(shot, to: "Two Shot")

        #expect(renamed.name == "Two Shot")
        #expect(renamed.id == shot.id)
        #expect(renamed.layers == shot.layers)
        #expect(renamed.background == shot.background)
        #expect(renamed.defaultTransition == shot.defaultTransition)
        #expect(renamed != shot)
    }

    @Test("a rename trims surrounding whitespace")
    func renamingTrimsWhitespace() {
        let renamed = ShotEdit.renaming(makeShot(), to: "  Two Shot \n")
        #expect(renamed.name == "Two Shot")
    }

    @Test("a rename to an empty or whitespace-only name returns the shot unchanged")
    func renamingToEmptyNameIsIgnored() {
        let shot = makeShot()

        #expect(ShotEdit.renaming(shot, to: "") == shot)
        #expect(ShotEdit.renaming(shot, to: "   \n") == shot)
    }

    @Test("a rename to the same name returns an equal shot")
    func renamingToSameNameIsEqual() {
        let shot = makeShot()
        #expect(ShotEdit.renaming(shot, to: shot.name) == shot)
    }

    @Test("setting a default transition replaces it and preserves the shot's identity, layers, and background")
    func settingDefaultTransitionPreservesIdentity() {
        let shot = makeShot()

        let edited = ShotEdit.settingDefaultTransition(.wipe(edge: .top), of: shot)

        #expect(edited.defaultTransition == .wipe(edge: .top))
        #expect(edited.id == shot.id)
        #expect(edited.name == shot.name)
        #expect(edited.layers == shot.layers)
        #expect(edited.background == shot.background)
        #expect(edited != shot)
    }

    @Test("setting a shader default transition stores the shader at the default duration")
    func settingShaderDefaultTransitionStoresShader() {
        let edited = ShotEdit.settingDefaultTransition(.shader(name: .blinds), of: makeShot())
        #expect(edited.defaultTransition == .shader(name: .blinds, duration: Transition.defaultShaderDuration))
    }

    @Test("setting a nil default transition clears the shot's default")
    func settingNilDefaultTransitionClears() {
        let cleared = ShotEdit.settingDefaultTransition(nil, of: makeShot())
        #expect(cleared.defaultTransition == nil)
    }

    @Test("setting the same default transition returns an equal shot")
    func settingSameDefaultTransitionIsEqual() {
        let shot = makeShot()
        #expect(ShotEdit.settingDefaultTransition(shot.defaultTransition, of: shot) == shot)
    }
}
