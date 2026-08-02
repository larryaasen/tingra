//
//  MultiviewTile.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// One input's tile in the multiview: which input it shows and what its
/// **tally** lamp reads (GLOSSARY.md, "Multiview", "Tally").
///
/// A plain value derived by ``tiles(inputs:onProgram:onPreview:)``, a pure
/// function of the running inputs and the two tallies — so the whole rule
/// that decides which lamp lights is unit-testable with no compositor, no
/// window, and no GPU (the ``ProgramLayout`` and ``MixerStrip`` pattern).
struct MultiviewTile: Identifiable, Equatable {
    /// What a tile's tally lamp reads — the broadcast convention the
    /// program and preview monitors already use.
    enum Tally: Equatable {
        /// The input is contributing to what viewers see right now
        /// (including the outgoing half of a transition still on screen).
        case onAir

        /// The input is contributing to the shot staged on preview.
        case staged

        /// The input is running but on neither bus.
        case idle
    }

    /// The input this tile shows.
    let id: InputID

    /// The input's user-facing name, as discovery reported it.
    let name: String

    /// What this tile's lamp reads.
    let tally: Tally

    /// Builds the multiview's input tiles.
    ///
    /// **Red wins over green.** An input in both the on-program and the
    /// staged shot reads `onAir`: what is going out to viewers is the more
    /// urgent fact, and it is the one an operator scans for.
    ///
    /// The tile order is the caller's — the model hands over the running
    /// inputs already sorted by name, so tiles do not reshuffle when a
    /// device connects.
    ///
    /// - Parameters:
    ///   - inputs: The inputs the engine is currently running, in tile
    ///     order. Multiview shows exactly these: opening a monitoring
    ///     window must never start a device that was not already running.
    ///   - onProgram: The inputs contributing to program, from
    ///     `Compositor.programInputIDs` — which unions the outgoing shot's
    ///     inputs while a transition is in progress, so a tile stays lit
    ///     for as long as its pixels are visibly on air.
    ///   - onPreview: The inputs contributing to the staged shot.
    /// - Returns: One tile per input, in the given order.
    static func tiles(
        inputs: [EngineModel.InputChoice],
        onProgram: Set<InputID>,
        onPreview: Set<InputID>
    ) -> [MultiviewTile] {
        inputs.map { input in
            let tally: Tally =
                if onProgram.contains(input.id) {
                    .onAir
                } else if onPreview.contains(input.id) {
                    .staged
                } else {
                    .idle
                }
            return MultiviewTile(id: input.id, name: input.name, tally: tally)
        }
    }
}
