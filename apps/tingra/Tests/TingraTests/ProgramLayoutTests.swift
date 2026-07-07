//
//  ProgramLayoutTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Testing
import TingraComposition
import TingraPlugInKit

@testable import Tingra

@Suite("ProgramLayout")
struct ProgramLayoutTests {
    private let display = InputID(rawValue: "display-1")
    private let camera = InputID(rawValue: "camera-1")

    @Test("no active inputs yields an empty layer tree (a background-only program)")
    func noInputs() {
        #expect(ProgramLayout.layers(displayID: nil, cameraID: nil).isEmpty)
    }

    @Test("a display alone fills the whole program")
    func displayAlone() {
        let layers = ProgramLayout.layers(displayID: display, cameraID: nil)
        #expect(layers == [Layer(input: display)])
    }

    @Test("a camera alone fills the whole program")
    func cameraAlone() {
        let layers = ProgramLayout.layers(displayID: nil, cameraID: camera)
        #expect(layers == [Layer(input: camera)])
    }

    @Test("display plus camera puts the display full-frame and the camera as a corner inset over it")
    func displayAndCamera() {
        let layers = ProgramLayout.layers(displayID: display, cameraID: camera)
        #expect(layers.count == 2)
        // The display is the background (bottom), full-frame.
        #expect(layers[0] == Layer(input: display))
        // The camera is on top, inset in the bottom-right corner.
        #expect(layers[1] == Layer(input: camera, frame: ProgramLayout.cameraInsetFrame))
        #expect(layers[1].frame != CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("no active inputs yields no shots (a background-only program)")
    func noShots() {
        #expect(ProgramLayout.shots(displayID: nil, cameraID: nil).isEmpty)
    }

    @Test("a single input yields one full-frame shot with that input's stable id")
    func singleInputShot() {
        let displayShots = ProgramLayout.shots(displayID: display, cameraID: nil)
        #expect(displayShots.map(\.id) == [ProgramLayout.displayShotID])
        #expect(displayShots.first?.layers == [Layer(input: display)])

        let cameraShots = ProgramLayout.shots(displayID: nil, cameraID: camera)
        #expect(cameraShots.map(\.id) == [ProgramLayout.cameraShotID])
        #expect(cameraShots.first?.layers == [Layer(input: camera)])
    }

    @Test("both inputs yield picture-in-picture first, then a full-frame shot per input")
    func bothInputsShots() {
        let shots = ProgramLayout.shots(displayID: display, cameraID: camera)
        #expect(
            shots.map(\.id) == [
                ProgramLayout.pictureInPictureShotID,
                ProgramLayout.displayShotID,
                ProgramLayout.cameraShotID,
            ])
        // The default (first) shot is the composited picture-in-picture.
        #expect(shots[0].layers == ProgramLayout.layers(displayID: display, cameraID: camera))
        #expect(shots[1].layers == [Layer(input: display)])
        #expect(shots[2].layers == [Layer(input: camera)])
        // Every shot is named for the switcher.
        #expect(shots.allSatisfy { !$0.name.isEmpty })
    }

    @Test("a shot keeps its id across rebuilds so the active shot survives a selection change")
    func shotIDsAreStableAcrossRebuilds() {
        let first = ProgramLayout.shots(displayID: display, cameraID: camera)
        let other = InputID(rawValue: "camera-2")
        let second = ProgramLayout.shots(displayID: display, cameraID: other)
        // Same roles, different camera device: the ids match, so a switcher's
        // active selection is preserved.
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("each built-in shot button gets its own distinct tap event name")
    func tapNamesAreDistinctPerShot() {
        #expect(ProgramLayout.tapName(forShotID: ProgramLayout.cameraShotID) == "camera.button")
        #expect(ProgramLayout.tapName(forShotID: ProgramLayout.displayShotID) == "display.button")
        #expect(ProgramLayout.tapName(forShotID: ProgramLayout.pictureInPictureShotID) == "pip.button")
    }

    @Test("an unrecognized shot id falls back to a generic tap event name")
    func tapNameFallsBackForUnknownShot() {
        #expect(ProgramLayout.tapName(forShotID: ShotID(rawValue: "future-user-shot")) == "shot.button")
    }
}
