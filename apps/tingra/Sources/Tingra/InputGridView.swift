//
//  InputGridView.swift
//  tingra
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
/// Shared by the two surfaces that show it: the main window's top-left area,
/// beside the preview and program monitors (``ContentView/topSection``), and
/// the ``MultiviewView`` window beneath them. One view rather than two, so the
/// grids cannot drift in how a tile reads — the same reason ``MonitorTile`` is
/// shared by both windows' monitors (the `MeterCapsule` lesson, one media
/// over).
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
    /// multiview window takes the default; the main window passes a smaller
    /// value, because its grid shares the top section with the two monitors
    /// and would otherwise fall to a single column.
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
                            badgeTint: badgeTint(for: tile.tally),
                            borderTint: borderTint(for: tile.tally)
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

    /// The name badge's tint for a tally state — the broadcast convention,
    /// with a neutral badge for an input on neither bus.
    ///
    /// - Parameter tally: What the tile's lamp reads.
    private func badgeTint(for tally: MultiviewTile.Tally) -> Color {
        switch tally {
        case .onAir: .red
        case .staged: .green
        case .idle: .gray
        }
    }

    /// The tally border's tint for a tally state, or nil for an input on
    /// neither bus (an unlit lamp is no border, not a gray one).
    ///
    /// - Parameter tally: What the tile's lamp reads.
    private func borderTint(for tally: MultiviewTile.Tally) -> Color? {
        switch tally {
        case .onAir: .red
        case .staged: .green
        case .idle: nil
        }
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
