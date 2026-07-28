//
//  MultiviewView.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo
import SwiftUI
import TingraPlugInKit

/// The multiview window: program, preview, and every running input tiled at
/// once for monitoring (GLOSSARY.md, "Multiview").
///
/// It is **not a bus** — nothing is fed from it and nothing is promoted out
/// of it, which is the test a bus has to pass. It is a monitoring surface
/// over surfaces that already exist: program and preview read the relays the
/// main window's monitors already read, and each input tile pulls that
/// input's latest frame straight from the compositor's latest-wins slot at
/// display cadence (ARCHITECTURE.md, "Multiview"; CLOCK.md's
/// preview-sampling rule). Nothing here runs while the window is closed, and
/// the engine's tick task is untouched by its existence.
///
/// The tiles are deliberately **inert**: a tile is an *input* and preview
/// stages a *shot*, so clicking one could only guess at which shot the
/// operator meant — and a guess one click from air is exactly what the
/// preview bus refused when it kept modifier-clicks off the program row.
/// Staging stays on the switcher, which does it unambiguously.
struct MultiviewView: View {
    /// The engine model — read only: multiview changes nothing.
    let model: EngineModel

    /// Program and preview across the top, the input tiles beneath.
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Preview left of program, the same left-to-right reading
                // order the main window uses.
                MonitorTile(
                    source: model.previewRelay,
                    label: Text(
                        "Preview", comment: "Name of the preview bus — labels its monitor and its switcher row"),
                    badgeTint: .green
                )
                MonitorTile(
                    source: model.programRelay,
                    label: Text(
                        "Program", comment: "Name of the program bus — labels its monitor and its switcher row"),
                    badgeTint: .red
                )
            }

            if tiles.isEmpty {
                ContentUnavailableView {
                    Text("No Inputs Running", comment: "Multiview placeholder title when no input is running")
                } description: {
                    Text(
                        "Choose a camera or a display to see it here.",
                        comment: "Multiview placeholder guidance when no input is running"
                    )
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
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
        .padding()
        .background(.background)
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

/// One input's frames for a multiview tile, read straight from the
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
