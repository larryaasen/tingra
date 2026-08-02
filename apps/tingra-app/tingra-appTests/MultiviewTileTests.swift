//
//  MultiviewTileTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraPlugInKit

@testable import TingraApp

@Suite("MultiviewTile")
struct MultiviewTileTests {
    /// A running-input choice for a tile.
    @MainActor
    private static func choice(_ id: String) -> EngineModel.InputChoice {
        EngineModel.InputChoice(id: InputID(rawValue: id), name: id, kind: .camera)
    }

    /// An input id.
    private static func input(_ id: String) -> InputID {
        InputID(rawValue: id)
    }

    @Test("an input on the on-program shot reads on air")
    @MainActor
    func programInputReadsOnAir() {
        let tiles = MultiviewTile.tiles(
            inputs: [Self.choice("camera")],
            onProgram: [Self.input("camera")],
            onPreview: []
        )

        #expect(tiles.map(\.tally) == [.onAir])
    }

    @Test("an input on the staged shot reads staged")
    @MainActor
    func previewInputReadsStaged() {
        let tiles = MultiviewTile.tiles(
            inputs: [Self.choice("camera")],
            onProgram: [],
            onPreview: [Self.input("camera")]
        )

        #expect(tiles.map(\.tally) == [.staged])
    }

    @Test("an input on both buses reads on air — red wins over green")
    @MainActor
    func onAirWinsOverStaged() {
        let camera = Self.input("camera")
        let tiles = MultiviewTile.tiles(
            inputs: [Self.choice("camera")],
            onProgram: [camera],
            onPreview: [camera]
        )

        // What is going out to viewers is the more urgent fact, and the one
        // an operator scans a multiview for.
        #expect(tiles.map(\.tally) == [.onAir])
    }

    @Test("an input on neither bus is idle — a running input with no lamp lit")
    @MainActor
    func unusedInputIsIdle() {
        let tiles = MultiviewTile.tiles(
            inputs: [Self.choice("camera")],
            onProgram: [Self.input("display")],
            onPreview: [Self.input("bars")]
        )

        #expect(tiles.map(\.tally) == [.idle])
    }

    @Test("one tile per running input, in the given order, each carrying its name")
    @MainActor
    func oneTilePerRunningInputInOrder() {
        let tiles = MultiviewTile.tiles(
            inputs: [Self.choice("camera"), Self.choice("display"), Self.choice("webcam")],
            onProgram: [Self.input("display")],
            onPreview: [Self.input("webcam")]
        )

        #expect(tiles.map(\.id.rawValue) == ["camera", "display", "webcam"])
        #expect(tiles.map(\.name) == ["camera", "display", "webcam"])
        #expect(tiles.map(\.tally) == [.idle, .onAir, .staged])
    }

    @Test("an on-program input that is not running gets no tile — multiview starts nothing")
    @MainActor
    func aShotInputThatIsNotRunningGetsNoTile() {
        // The tally names an input the engine is not running (a parked
        // picker role, a disconnected device). Multiview tiles only what is
        // already running: opening a monitoring window must never start a
        // device.
        let tiles = MultiviewTile.tiles(
            inputs: [Self.choice("camera")],
            onProgram: [Self.input("camera"), Self.input("parked-display")],
            onPreview: []
        )

        #expect(tiles.map(\.id.rawValue) == ["camera"])
    }

    @Test("no running inputs yields no tiles")
    @MainActor
    func noRunningInputsYieldsNoTiles() {
        #expect(MultiviewTile.tiles(inputs: [], onProgram: [Self.input("camera")], onPreview: []).isEmpty)
    }

    @Test("tiles with the same input, name, and tally are equal; a moved tally is not")
    @MainActor
    func tileEquality() {
        let onAir = MultiviewTile(id: Self.input("camera"), name: "Camera", tally: .onAir)

        #expect(onAir == MultiviewTile(id: Self.input("camera"), name: "Camera", tally: .onAir))
        #expect(onAir != MultiviewTile(id: Self.input("camera"), name: "Camera", tally: .staged))
        #expect(onAir != MultiviewTile(id: Self.input("display"), name: "Camera", tally: .onAir))
        #expect(onAir != MultiviewTile(id: Self.input("camera"), name: "Webcam", tally: .onAir))
    }
}
