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
}
