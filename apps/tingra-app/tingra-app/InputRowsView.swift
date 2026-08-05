//
//  InputRowsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus
import TingraPlugInKit

/// The main window's **input rows**: every available camera along the top row,
/// every other video input along the second — the generators (the patterns,
/// and a black generator when one lands) and the displays.
///
/// The split is by **provenance**, not by media: cameras are the row an
/// operator scans first and the one that changes as hardware comes and goes,
/// so it gets its own line rather than being mixed in among the patterns. Both
/// rows are already filtered to inputs that produce video (the media question
/// ``InputMedia`` answers), because a tile shows picture.
///
/// **These rows list every *available* video input, and every one of them is
/// live** — which is how they differ from ``InputGridView``, which tiles only
/// what the program already has running. A switcher's job is to show the
/// operator what they could cut to, and a black rectangle answers that only in
/// the negative, so ``EngineModel/applyConfiguration()`` starts every
/// discovered video input rather than just the cast and referenced ones.
///
/// That is a deliberate exception to the rule the multiview window still
/// keeps — opening a monitoring surface must not start a device — and it is
/// paid for in hardware: every camera holds its indicator light on, and a
/// Continuity Camera keeps its iPhone awake for as long as the app runs. A
/// tile still reads as its name over black in the two honest cases: before the
/// input's first frame arrives, and when starting it was refused (an
/// unauthorized camera, a device that vanished), which the bus reports as an
/// `input.start` error.
///
/// **Clicking a tile stages that input on preview.** These tiles are therefore
/// *not* inert, where the multiview window's still are — and the objection the
/// multiview recorded (a tile is an *input* while preview stages a *shot*, so a
/// click can only guess at which shot was meant) is answered rather than
/// dodged: ``EngineModel/stagePreview(showing:)`` prefers an authored shot that
/// already shows the input, and only invents one when none does. Nothing
/// reaches program from here — staging is not taking, and the Take button
/// remains the one step to air.
struct InputRowsView: View {
    /// The engine model — read only: the rows change nothing.
    let model: EngineModel

    /// The height available for both rows together, including the gap between
    /// them. Passed in rather than measured because the caller derives the
    /// whole top section's height from the window width
    /// (``ContentView/topSectionHeight(forWindowWidth:)``).
    let height: CGFloat

    /// The gap between the two rows, and between tiles within a row.
    private static let rowSpacing: CGFloat = 8

    /// The two rows, cameras above everything else.
    var body: some View {
        // A floor of one point so a degenerate height can never ask for a
        // negative frame; the real minimum comes from the caller.
        let rowHeight = max(1, (height - Self.rowSpacing) / 2)
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            row(
                for: cameras,
                height: rowHeight,
                emptyLabel: Text("No cameras", comment: "Shown in place of the camera row when none is discovered")
            )
            row(
                for: otherVideoInputs,
                height: rowHeight,
                emptyLabel: Text(
                    "No other inputs",
                    comment: "Shown in place of the generator and display row when none is discovered"
                )
            )
        }
    }

    /// Every discovered camera, in the model's stable by-name order.
    private var cameras: [EngineModel.InputChoice] {
        model.videoInputs.filter { $0.kind == .camera }
    }

    /// Every discovered video input that is not a camera: the generators and
    /// the displays.
    private var otherVideoInputs: [EngineModel.InputChoice] {
        model.videoInputs.filter { $0.kind != .camera }
    }

    /// One row of tiles, laid left to right and scrolling horizontally when
    /// there are more than fit, or the given caption when the row is empty.
    ///
    /// - Parameters:
    ///   - inputs: The row's inputs, already in tile order.
    ///   - height: The row's height; each tile is 16:9 within it.
    ///   - emptyLabel: What to show when `inputs` is empty.
    /// - Returns: The row.
    private func row(
        for inputs: [EngineModel.InputChoice],
        height: CGFloat,
        emptyLabel: Text
    ) -> some View {
        let tiles = MultiviewTile.tiles(
            inputs: inputs,
            onProgram: model.programInputIDs,
            onPreview: model.previewInputIDs
        )
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.rowSpacing) {
                ForEach(tiles) { tile in
                    Button {
                        model.eventBus.tap(
                            "inputRow.tile",
                            domain: .composition,
                            params: ["id": .string(tile.id.rawValue), "name": .string(tile.name)]
                        )
                        Task { await model.stagePreview(showing: tile.id) }
                    } label: {
                        MonitorTile(
                            source: InputFrameSource(model: model, id: tile.id),
                            label: Text(verbatim: tile.name),
                            badgeTint: tile.tally.badgeTint,
                            borderTint: tile.tally.borderTint
                        )
                        .frame(width: height * 16 / 9, height: height)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Stage on preview", comment: "Tooltip on an input tile that stages it on preview"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .overlay {
            if tiles.isEmpty {
                emptyLabel
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
