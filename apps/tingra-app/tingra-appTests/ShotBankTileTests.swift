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

    // MARK: Transience

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
            id: ShotID(rawValue: "a"), name: "Wide", tally: .idle, isTransient: false)
        let same = ShotBankTile(
            id: ShotID(rawValue: "a"), name: "Wide", tally: .idle, isTransient: false)
        let staged = ShotBankTile(
            id: ShotID(rawValue: "a"), name: "Wide", tally: .staged, isTransient: false)
        let transient = ShotBankTile(
            id: ShotID(rawValue: "a"), name: "Wide", tally: .idle, isTransient: true)

        #expect(tile == same)
        #expect(tile != staged)
        #expect(tile != transient)
    }
}
