//
//  EditedShot.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraComposition

/// The shot the layer-tree editor follows, with the tally its header shows —
/// the pure, unit-tested rule behind ``EngineModel/editedShot``.
///
/// **The editor follows preview.** The staging bus is where an operator
/// builds the next shot before taking it, so that is the shot whose layers
/// they mean to edit; only when nothing is staged does the editor fall back
/// to the shot on program, the pre-preview-bus behavior (ARCHITECTURE.md,
/// "The layer-tree editor"). No toggle: which shot is edited is answered by
/// what is staged, and a second selector would be one more thing to keep in
/// agreement with the switcher.
///
/// **The tally says whether the edit is live.** Green when the shot is only
/// on preview; red when it is on program — and red wins when the same shot
/// is on both buses, the rule ``MultiviewTile/tiles(inputs:onProgram:onPreview:)``
/// already applies to inputs, because an edit to a shot on program is on air
/// at the next tick whether or not it is also staged. The lamp is never
/// ``MultiviewTile/Tally/idle``: a shot on neither bus is not followed.
struct EditedShot: Equatable {
    /// The shot being edited — a shot of the active preset's session pool,
    /// so an edit can be stored back into it.
    let shot: Shot

    /// Which bus the shot is on, red winning over green.
    let tally: MultiviewTile.Tally

    /// Whether an edit to this shot reaches viewers at the next tick.
    var isOnAir: Bool {
        tally == .onAir
    }

    /// Resolves which shot the editor follows.
    ///
    /// A held program snapshot (a shot a preset switch kept on program from
    /// outside the loaded pool) has no entry in `shots`, so it cannot be
    /// followed: `Compositor.updateShot(_:)` matches by id against the loaded
    /// preset, and there would be nothing to store the edit into. That case
    /// resolves to `nil` like an empty pool does.
    ///
    /// - Parameters:
    ///   - shots: The active preset's shots, in switcher order.
    ///   - previewShotID: The shot staged on preview, if any.
    ///   - activeShotID: The shot on program, if any.
    /// - Returns: The followed shot and its tally, or `nil` when neither bus
    ///   carries a shot from `shots`.
    static func following(shots: [Shot], previewShotID: ShotID?, activeShotID: ShotID?) -> EditedShot? {
        guard let followedID = previewShotID ?? activeShotID,
            let shot = shots.first(where: { $0.id == followedID })
        else { return nil }
        let tally: MultiviewTile.Tally = followedID == activeShotID ? .onAir : .staged
        return EditedShot(shot: shot, tally: tally)
    }
}
