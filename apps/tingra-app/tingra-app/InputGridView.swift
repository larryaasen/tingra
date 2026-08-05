//
//  InputGridView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-31.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo
import SwiftUI
import TingraPlugInKit

/// The **input grid**: one tile per running input, each carrying that input's
/// name badge and its **tally** border — red on air, green staged, no border
/// idle (GLOSSARY.md, "Multiview", "Tally").
///
/// The ``MultiviewView`` window's grid, beneath its two monitors. The main
/// window used to carry this same grid in its top-left area; it now carries
/// ``InputRowsView`` there instead — two provenance-ordered rows rather than
/// one adaptive grid, listing what is *available* where this grid tiles what
/// is *running*. The two surfaces still cannot drift in how a tile **reads**,
/// because both draw ``MonitorTile`` and both take their lamp colours from
/// ``MultiviewTile/Tally`` (the `MeterCapsule` lesson, one media over).
///
/// Each tile pulls that input's latest frame straight from the compositor's
/// latest-wins slot at display cadence (``InputFrameSource``), so the grid
/// starts nothing: it tiles exactly the inputs the engine is already running,
/// and a running input that has not delivered its first frame yet shows a
/// black tile carrying its name rather than popping in later.
///
/// The tiles are deliberately **inert**: a tile is an *input* and preview
/// stages a *shot*, so clicking one could only guess at which shot the
/// operator meant — and a guess one click from air is exactly what the
/// preview bus refused when it kept modifier-clicks off the program row
/// (ARCHITECTURE.md, "Multiview"). Staging stays on the switcher, which does
/// it unambiguously. That holds all the more now that the grid sits *in* the
/// main window, one row above the switcher that would have to interpret the
/// guess.
struct InputGridView: View {
    /// The engine model — read only: the grid changes nothing.
    let model: EngineModel

    /// The narrowest a tile may be before the grid drops a column. The
    /// multiview window, the grid's one caller, takes the default — a window
    /// of its own is exactly the case that can afford wide tiles.
    var minimumTileWidth: CGFloat = 220

    /// The tiles in an adaptive grid, or the placeholder when nothing is
    /// running.
    var body: some View {
        if tiles.isEmpty {
            ContentUnavailableView {
                Text("No Inputs Running", comment: "Input grid placeholder title when no input is running")
            } description: {
                Text(
                    "Choose a camera or a display to see it here.",
                    comment: "Input grid placeholder guidance when no input is running"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTileWidth), spacing: 12)], spacing: 12) {
                    ForEach(tiles) { tile in
                        MonitorTile(
                            source: InputFrameSource(model: model, id: tile.id),
                            label: Text(verbatim: tile.name),
                            badgeTint: tile.tally.badgeTint,
                            borderTint: tile.tally.borderTint
                        )
                    }
                }
            }
        }
    }

    /// The input tiles, re-derived whenever the model's program or preview
    /// tally changes.
    private var tiles: [MultiviewTile] {
        MultiviewTile.tiles(
            inputs: model.multiviewInputs,
            onProgram: model.programInputIDs,
            onPreview: model.previewInputIDs
        )
    }

}

/// One input's frames for a tile in the input grid, read straight from the
/// compositor's latest-wins slot.
///
/// The read is a **pull** on each draw rather than a stream: a tile draws at
/// display cadence, and pulling is also the only way it *can* get frames —
/// draining the input's own `frames()` would finish the compositor's fill
/// task and stop the program (ARCHITECTURE.md, "Multiview"). The frame it
/// returns is a retained, read-only share of a buffer the compositor holds;
/// the coordinator draws it and drops it, never accumulating (the ownership
/// rule's clause 4).
@MainActor
struct InputFrameSource: MonitorFrameSource {
    /// The model, which forwards the read to the compositor.
    let model: EngineModel

    /// The input this source reads.
    let id: InputID

    /// The input's most recent frame, or nil until it delivers one.
    var latest: CVPixelBuffer? {
        model.latestFrame(forInput: id)
    }
}
