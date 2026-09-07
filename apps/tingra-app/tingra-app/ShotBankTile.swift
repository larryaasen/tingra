//
//  ShotBankTile.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import TingraComposition
import TingraPlugInKit

/// One shot's tile in the main window's **shot bank** (``ShotBankView``):
/// which shot it is, what its tally reads, which input's picture stands in
/// for it, and whether it is a transient shot the operator has not kept.
///
/// A plain value derived by ``tiles(shots:onProgram:onPreview:)``, a pure
/// function of the pool and the two bus ids — the ``MultiviewTile`` pattern
/// one subject over, so the whole rule that decides what a tile shows is
/// unit-testable with no compositor, no window, and no GPU (ARCHITECTURE.md,
/// "The shot bank").
struct ShotBankTile: Identifiable, Equatable {
    /// The shot this tile shows.
    let id: ShotID

    /// The shot's name, drawn verbatim — authored, or a device's for a
    /// transient shot.
    let name: String

    /// What this tile's tally border reads: red on program, green staged,
    /// none idle — the shot-level rule the sidebar's shot rows read.
    let tally: MultiviewTile.Tally

    /// The input whose latest frame the tile draws, or nil for a shot with no
    /// layers (drawn black over its caption). See ``thumbnailInput(of:)``.
    let thumbnailInput: InputID?

    /// How many layers the shot has. A tile whose count is above one wears a
    /// stacked-layers glyph, so a single input's picture is not mistaken for
    /// the whole composition.
    let layerCount: Int

    /// Whether the shot is **transient** — automatic, staged by clicking an
    /// input in the sidebar, kept only if the operator keeps, edits, or airs
    /// it (``ShotOrigin/automatic``; ARCHITECTURE.md, "The shot bank"). A
    /// transient tile is drawn with a dashed border and a Keep button.
    let isTransient: Bool

    /// Builds the bank's tiles, one per shot in switcher order.
    ///
    /// **Red wins over green**: a shot both on program and staged reads
    /// `onAir`, because what viewers are seeing is the more urgent fact. That
    /// case is ordinary — a take leaves the taken shot staged as well.
    ///
    /// - Parameters:
    ///   - shots: The active preset's shots, in switcher order — the session
    ///     pool, transient shots included.
    ///   - onProgram: The id of the shot on program, or nil.
    ///   - onPreview: The id of the shot staged on preview, or nil.
    /// - Returns: One tile per shot, in the given order.
    static func tiles(shots: [Shot], onProgram: ShotID?, onPreview: ShotID?) -> [ShotBankTile] {
        shots.map { shot in
            let tally: MultiviewTile.Tally =
                if shot.id == onProgram {
                    .onAir
                } else if shot.id == onPreview {
                    .staged
                } else {
                    .idle
                }
            return ShotBankTile(
                id: shot.id,
                name: shot.name,
                tally: tally,
                thumbnailInput: thumbnailInput(of: shot),
                layerCount: shot.layers.count,
                isTransient: shot.origin == .automatic
            )
        }
    }

    /// The input whose picture stands in for a shot: the layer covering the
    /// **largest area** of the frame, the lowest layer winning a tie.
    ///
    /// Not the topmost layer — for a picture-in-picture shot that is the
    /// small camera inset, and the tile would show a face where the shot is
    /// mostly a display — and not a composite of the shot, which would cost a
    /// renderer pass per shot per tick for a picture the operator glances at.
    /// The layer that fills most of the frame is what the shot mostly *is*.
    /// Ties go to the lowest layer because it is the one drawn first, nearest
    /// the background, and so the one the others sit over.
    ///
    /// - Parameter shot: The shot to choose for.
    /// - Returns: The dominant layer's input, or nil for a shot with no layers.
    static func thumbnailInput(of shot: Shot) -> InputID? {
        var best: (input: InputID, area: CGFloat)?
        for layer in shot.layers {
            let area = layer.frame.width * layer.frame.height
            if let current = best, area <= current.area { continue }
            best = (layer.input, area)
        }
        return best?.input
    }
}
