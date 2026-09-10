//
//  ShotLayerTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Foundation
import Testing
import TingraPlugInKit

@testable import TingraComposition

@Suite("Layer")
struct LayerTests {
    @Test("a layer defaults to filling the whole program at full opacity with no effect chain")
    func layerDefaults() {
        let layer = Layer(input: InputID(rawValue: "camera"))
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(layer.opacity == 1)
        #expect(layer.effects == nil)
    }

    @Test("layers differing only in their effect chain compare not equal")
    func layerChainAffectsEquality() {
        let plain = Layer(input: InputID(rawValue: "camera"))
        let chained = Layer(
            input: InputID(rawValue: "camera"),
            effects: [EffectConfiguration(effect: EffectID(rawValue: "blur"))]
        )
        #expect(plain != chained)
    }

    @Test("layers are equal only when input, frame, and opacity all match")
    func layerEquality() {
        let base = Layer(
            input: InputID(rawValue: "a"), frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), opacity: 0.8)
        let same = Layer(
            input: InputID(rawValue: "a"), frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), opacity: 0.8)
        let otherInput = Layer(
            input: InputID(rawValue: "b"),
            frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            opacity: 0.8
        )
        let otherOpacity = Layer(
            input: InputID(rawValue: "a"),
            frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            opacity: 1
        )
        #expect(base == same)
        #expect(base != otherInput)
        #expect(base != otherOpacity)
    }
}

@Suite("Shot")
struct ShotTests {
    @Test("a shot defaults to no layers over opaque black with an unnamed, fresh identity and no default transition")
    func shotDefaults() {
        let shot = Shot()
        #expect(shot.layers.isEmpty)
        #expect(shot.background == .black)
        #expect(shot.name.isEmpty)
        #expect(shot.defaultTransition == nil)
        // Two default shots get distinct identities.
        #expect(Shot().id != Shot().id)
    }

    @Test("shots are equal only when their id, name, layers, background, and default transition all match")
    func shotEquality() {
        let id = ShotID(rawValue: "shot-1")
        let layer = Layer(input: InputID(rawValue: "a"))
        let base = Shot(id: id, name: "Wide", layers: [layer], background: .black)
        let same = Shot(id: id, name: "Wide", layers: [layer], background: .black)
        let otherID = Shot(id: ShotID(rawValue: "shot-2"), name: "Wide", layers: [layer], background: .black)
        let otherName = Shot(id: id, name: "Tight", layers: [layer], background: .black)
        let otherLayers = Shot(id: id, name: "Wide", layers: [], background: .black)
        let otherBackground = Shot(
            id: id, name: "Wide", layers: [layer], background: BackgroundColor(red: 1, green: 1, blue: 1))
        let otherDefaultTransition = Shot(
            id: id, name: "Wide", layers: [layer], background: .black, defaultTransition: .dissolve)
        #expect(base == same)
        #expect(base != otherID)
        #expect(base != otherName)
        #expect(base != otherLayers)
        #expect(base != otherBackground)
        #expect(base != otherDefaultTransition)
    }
}

@Suite("ProgramFormat")
struct ProgramFormatTests {
    @Test("the program format defaults to 1920x1080 at 30 fps")
    func formatDefaults() {
        let format = ProgramFormat()
        #expect(format.width == 1920)
        #expect(format.height == 1080)
        #expect(format.frameRate == 30)
    }

    @Test("program formats are equal only when every dimension matches")
    func formatEquality() {
        #expect(
            ProgramFormat(width: 1280, height: 720, frameRate: 30)
                == ProgramFormat(width: 1280, height: 720, frameRate: 30))
        #expect(
            ProgramFormat(width: 1280, height: 720, frameRate: 30)
                != ProgramFormat(width: 1920, height: 1080, frameRate: 30))
        #expect(
            ProgramFormat(width: 1280, height: 720, frameRate: 30)
                != ProgramFormat(width: 1280, height: 720, frameRate: 60))
    }

    @Test("the aspect ratio is width over height")
    func formatAspectRatio() {
        #expect(ProgramFormat(width: 1920, height: 1080, frameRate: 30).aspectRatio == 1920.0 / 1080.0)
        #expect(ProgramFormat(width: 1080, height: 1920, frameRate: 30).aspectRatio == 1080.0 / 1920.0)
        #expect(ProgramFormat(width: 640, height: 480, frameRate: 30).aspectRatio == 4.0 / 3.0)
    }

    @Test("a program format round-trips through JSON under stable keys")
    func formatRoundTrips() throws {
        let format = ProgramFormat(width: 3840, height: 2160, frameRate: 60)
        let data = try JSONEncoder().encode(format)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["width", "height", "frameRate"])
        #expect(object["width"] as? Int == 3840)
        #expect(object["height"] as? Int == 2160)
        #expect(object["frameRate"] as? Int == 60)
        #expect(try JSONDecoder().decode(ProgramFormat.self, from: data) == format)
    }

    @Test(
        "decoding a program format without a width, height, or frameRate throws a keyNotFound error",
        arguments: [
            #"{"height":1080,"frameRate":30}"#,
            #"{"width":1920,"frameRate":30}"#,
            #"{"width":1920,"height":1080}"#,
        ])
    func formatMissingKeyThrows(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProgramFormat.self, from: Data(json.utf8))
        }
    }
}
