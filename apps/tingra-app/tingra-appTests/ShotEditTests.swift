//
//  ShotEditTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Testing
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

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

    @Test("a shot showing one input carries a single full-frame layer bound to it, under the given name")
    func shotShowingInputHasOneFullFrameLayer() {
        let input = InputID(rawValue: "camera-1")
        let shot = ShotEdit.shot(showing: input, named: "FaceTime HD Camera")

        #expect(shot.name == "FaceTime HD Camera")
        #expect(shot.background == .black)
        #expect(shot.layers.count == 1)
        #expect(shot.layers.first?.input == input)
        // Full frame in normalized coordinates: the tile the operator clicked
        // fills preview rather than sitting in a corner of it.
        #expect(shot.layers.first?.frame == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("every shot showing an input gets its own fresh id")
    func shotsShowingInputHaveDistinctIDs() {
        let input = InputID(rawValue: "camera-1")

        #expect(ShotEdit.shot(showing: input, named: "A").id != ShotEdit.shot(showing: input, named: "A").id)
    }

    @Test("a shot the app creates to stage an input is automatic")
    func stagedInputShotIsAutomatic() {
        let shot = ShotEdit.shot(showing: InputID(rawValue: "camera-1"), named: "Razer Kiyo Pro")

        #expect(shot.origin == .automatic)
    }

    @Test("a shot the operator adds is authored")
    func newShotIsAuthored() {
        #expect(ShotEdit.newShot().origin == .authored)
    }

    @Test("renaming an automatic shot makes it the operator's")
    func renamingPromotesToAuthored() {
        let automatic = ShotEdit.shot(showing: InputID(rawValue: "camera-1"), named: "Razer Kiyo Pro")

        #expect(ShotEdit.renaming(automatic, to: "Host Wide").origin == .authored)
    }

    @Test("a rejected rename promotes nothing")
    func rejectedRenamePromotesNothing() {
        let automatic = ShotEdit.shot(showing: InputID(rawValue: "camera-1"), named: "Razer Kiyo Pro")

        #expect(ShotEdit.renaming(automatic, to: "   ").origin == .automatic)
    }

    @Test("a duplicate is the operator's, whatever it was made from")
    func duplicateIsAuthored() {
        let automatic = ShotEdit.shot(showing: InputID(rawValue: "camera-1"), named: "Razer Kiyo Pro")

        #expect(ShotEdit.duplicate(of: automatic).origin == .authored)
    }

    @Test("setting a default transition leaves an automatic shot automatic")
    func defaultTransitionPreservesOrigin() {
        let automatic = ShotEdit.shot(showing: InputID(rawValue: "camera-1"), named: "Razer Kiyo Pro")

        #expect(ShotEdit.settingDefaultTransition(.dissolve, of: automatic).origin == .automatic)
    }

    @Test("staging an input reuses a shot that shows exactly that input")
    func stagingReusesAShotShowingOnlyTheInput() {
        let input = InputID(rawValue: "camera-1")
        let existing = ShotEdit.shot(showing: input, named: "Razer Kiyo Pro")

        #expect(ShotEdit.shot(in: [ShotEdit.newShot(), existing], showingOnly: input)?.id == existing.id)
    }

    @Test("a renamed shot still matches the input it shows alone")
    func renamedShotStillMatches() {
        let input = InputID(rawValue: "camera-1")
        let renamed = ShotEdit.renaming(ShotEdit.shot(showing: input, named: "Razer Kiyo Pro"), to: "Wide")

        // The match is on what the shot shows, never on what it is called.
        #expect(ShotEdit.shot(in: [renamed], showingOnly: input)?.id == renamed.id)
    }

    @Test("a shot that only contains the input among other layers is not a match")
    func shotContainingTheInputIsNotAMatch() {
        let input = InputID(rawValue: "camera-1")
        // The shape that prompted the rule: a camera under a PLUGE overlay.
        let composed = LayerTreeEdit.addingLayer(
            boundTo: InputID(rawValue: "pluge"),
            to: ShotEdit.shot(showing: input, named: "Camera")
        )

        #expect(ShotEdit.shot(in: [composed], showingOnly: input) == nil)
    }

    @Test("a shot whose layer is cropped is not a match")
    func croppedLayerIsNotAMatch() {
        let input = InputID(rawValue: "camera-1")
        let shot = Shot(
            name: "Inset",
            layers: [Layer(input: input, frame: CGRect(x: 0, y: 0, width: 0.66, height: 0.67))]
        )

        #expect(ShotEdit.shot(in: [shot], showingOnly: input) == nil)
    }

    @Test("a shot whose layer is faded is not a match")
    func fadedLayerIsNotAMatch() {
        let input = InputID(rawValue: "camera-1")
        let shot = Shot(name: "Ghost", layers: [Layer(input: input, opacity: 0.5)])

        #expect(ShotEdit.shot(in: [shot], showingOnly: input) == nil)
    }

    @Test("a shot showing a different input is not a match")
    func differentInputIsNotAMatch() {
        let shot = ShotEdit.shot(showing: InputID(rawValue: "camera-2"), named: "Other")

        #expect(ShotEdit.shot(in: [shot], showingOnly: InputID(rawValue: "camera-1")) == nil)
    }

    @Test("an empty switcher matches nothing")
    func emptyShotsMatchNothing() {
        #expect(ShotEdit.shot(in: [], showingOnly: InputID(rawValue: "camera-1")) == nil)
    }

    @Test("the first matching shot wins when two show the same input alone")
    func firstMatchWins() {
        let input = InputID(rawValue: "camera-1")
        let first = ShotEdit.shot(showing: input, named: "One")
        let second = ShotEdit.shot(showing: input, named: "Two")

        #expect(ShotEdit.shot(in: [first, second], showingOnly: input)?.id == first.id)
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
