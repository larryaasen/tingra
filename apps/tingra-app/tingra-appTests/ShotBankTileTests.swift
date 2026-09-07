//
//  ShotBankTileTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Testing
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

/// The pure tile derivation behind the main window's shot bank
/// (ARCHITECTURE.md, "The shot bank").
@Suite("ShotBankTile")
struct ShotBankTileTests {
    private static let display = InputID(rawValue: "display-1")
    private static let camera = InputID(rawValue: "camera-1")
    private static let bars = InputID(rawValue: "bars")

    /// An authored shot with the given layers.
    private static func shot(_ id: String, _ name: String, layers: [Layer] = [], origin: ShotOrigin = .authored) -> Shot
    {
        Shot(id: ShotID(rawValue: id), name: name, layers: layers, origin: origin)
    }

    // MARK: Tally

    @Test("a shot on program reads on air, the staged shot reads staged, and the rest are idle")
    func tallyPerBus() {
        let tiles = ShotBankTile.tiles(
            shots: [Self.shot("a", "Wide"), Self.shot("b", "Close"), Self.shot("c", "Bars")],
            onProgram: ShotID(rawValue: "a"),
            onPreview: ShotID(rawValue: "b")
        )

        #expect(tiles.map(\.tally) == [.onAir, .staged, .idle])
    }

    @Test("a shot both on program and staged reads on air")
    func redWinsOverGreen() {
        let tiles = ShotBankTile.tiles(
            shots: [Self.shot("a", "Wide")],
            onProgram: ShotID(rawValue: "a"),
            onPreview: ShotID(rawValue: "a")
        )

        #expect(tiles.first?.tally == .onAir)
    }

    @Test("with nothing on either bus every tile is idle")
    func nothingOnEitherBus() {
        let tiles = ShotBankTile.tiles(
            shots: [Self.shot("a", "Wide"), Self.shot("b", "Close")], onProgram: nil, onPreview: nil)

        #expect(tiles.allSatisfy { $0.tally == .idle })
    }

    // MARK: Order, identity, and name

    @Test("tiles keep switcher order and carry the shot's identity and name")
    func orderIdentityAndName() {
        let tiles = ShotBankTile.tiles(
            shots: [Self.shot("b", "Close"), Self.shot("a", "Wide")],
            onProgram: nil,
            onPreview: nil
        )

        #expect(tiles.map(\.id) == [ShotID(rawValue: "b"), ShotID(rawValue: "a")])
        #expect(tiles.map(\.name) == ["Close", "Wide"])
    }

    @Test("an empty pool yields no tiles")
    func emptyPool() {
        #expect(ShotBankTile.tiles(shots: [], onProgram: nil, onPreview: nil).isEmpty)
    }

    // MARK: Thumbnail

    @Test("a single-layer shot's thumbnail is that layer's input")
    func singleLayerThumbnail() {
        let shot = Self.shot("a", "Camera", layers: [Layer(input: Self.camera)])

        #expect(ShotBankTile.thumbnailInput(of: shot) == Self.camera)
    }

    @Test("a picture-in-picture shot's thumbnail is the full-frame display, not the camera inset on top")
    func pictureInPictureThumbnailIsTheLargestLayer() {
        let shot = Self.shot("pip", "PiP", layers: ProgramLayout.layers(displayID: Self.display, cameraID: Self.camera))

        // The camera is the topmost layer; the display covers more of the frame.
        #expect(shot.layers.last?.input == Self.camera)
        #expect(ShotBankTile.thumbnailInput(of: shot) == Self.display)
    }

    @Test("a small layer on the bottom loses to a larger layer above it")
    func largerUpperLayerWins() {
        let shot = Self.shot(
            "a", "Overlay",
            layers: [
                Layer(input: Self.bars, frame: CGRect(x: 0, y: 0, width: 0.3, height: 0.3)),
                Layer(input: Self.camera, frame: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
            ]
        )

        #expect(ShotBankTile.thumbnailInput(of: shot) == Self.camera)
    }

    @Test("two layers of equal area resolve to the lower one")
    func tieGoesToTheLowestLayer() {
        let shot = Self.shot("a", "Split", layers: [Layer(input: Self.display), Layer(input: Self.camera)])

        #expect(ShotBankTile.thumbnailInput(of: shot) == Self.display)
    }

    @Test("a shot with no layers has no thumbnail input")
    func noLayersNoThumbnail() {
        #expect(ShotBankTile.thumbnailInput(of: Self.shot("a", "Empty")) == nil)
        #expect(
            ShotBankTile.tiles(shots: [Self.shot("a", "Empty")], onProgram: nil, onPreview: nil).first?.thumbnailInput
                == nil)
    }

    // MARK: Layer count and transience

    @Test("a tile carries its shot's layer count")
    func layerCount() {
        let tiles = ShotBankTile.tiles(
            shots: [
                Self.shot("a", "Empty"),
                Self.shot("b", "Camera", layers: [Layer(input: Self.camera)]),
                Self.shot("c", "PiP", layers: ProgramLayout.layers(displayID: Self.display, cameraID: Self.camera)),
            ],
            onProgram: nil,
            onPreview: nil
        )

        #expect(tiles.map(\.layerCount) == [0, 1, 2])
    }

    @Test("an automatic shot is a transient tile, and an authored one is not")
    func transience() {
        let transient = ShotEdit.shot(showing: Self.camera, named: "Razer Kiyo Pro")
        let tiles = ShotBankTile.tiles(
            shots: [Self.shot("a", "Wide"), transient],
            onProgram: nil,
            onPreview: transient.id
        )

        #expect(tiles.map(\.isTransient) == [false, true])
        // A staged transient shot still lights green, so the dashed border
        // can take the tally's colour.
        #expect(tiles.last?.tally == .staged)
    }

    @Test("two tiles are equal only when every field matches")
    func equality() {
        let tile = ShotBankTile(
            id: ShotID(rawValue: "a"), name: "Wide", tally: .idle, thumbnailInput: Self.camera, layerCount: 1,
            isTransient: false)
        let same = ShotBankTile(
            id: ShotID(rawValue: "a"), name: "Wide", tally: .idle, thumbnailInput: Self.camera, layerCount: 1,
            isTransient: false)
        let staged = ShotBankTile(
            id: ShotID(rawValue: "a"), name: "Wide", tally: .staged, thumbnailInput: Self.camera, layerCount: 1,
            isTransient: false)
        let transient = ShotBankTile(
            id: ShotID(rawValue: "a"), name: "Wide", tally: .idle, thumbnailInput: Self.camera, layerCount: 1,
            isTransient: true)

        #expect(tile == same)
        #expect(tile != staged)
        #expect(tile != transient)
    }
}
