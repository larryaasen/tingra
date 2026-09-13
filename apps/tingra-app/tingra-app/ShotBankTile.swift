//
//  ShotBankTile.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraComposition
import TingraPlugInKit

/// One shot's tile in the main window's **shot bank** (``ShotBankView``):
/// which shot it is, what its tally reads, and whether it is a transient
/// shot the operator has not kept (its picture is the composed shot itself —
/// ``ShotThumbnailSource``).
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
                isTransient: shot.origin == .automatic
            )
        }
    }
}
