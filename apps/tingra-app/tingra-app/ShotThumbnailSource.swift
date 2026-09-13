//
//  ShotThumbnailSource.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreVideo
import TingraComposition
import TingraPlugInKit

/// The frame source behind a shot bank tile: **the whole shot** — every
/// layer's latest frame through its chain, placed in its frame and blended
/// over the background, composed exactly as the program renders it — so a
/// tile shows what a take would put on air, not one layer standing in for
/// it (ARCHITECTURE.md, "Shot thumbnails are the shot").
///
/// The composition is a lazy `CIImage` from the bank's own
/// `CoreImageShotRenderer`, drawn straight into the tile's drawable at
/// thumbnail size in the monitor's one pass — no program-size buffer is
/// rendered for a picture the operator glances at. The shot is looked up
/// by id on every draw, so a live layer edit shows in its tile; every frame
/// is read, composed, and dropped within one draw, as every monitor's is
/// (ownership clause 4).
@MainActor
struct ShotThumbnailSource: MonitorFrameSource {
    /// The model: the shots and the inputs' latest frames.
    let model: EngineModel

    /// The shot this tile shows.
    let shotID: ShotID

    /// The bank's renderer, shared by its tiles.
    let renderer: CoreImageShotRenderer

    /// Creates the source for one shot.
    ///
    /// - Parameters:
    ///   - model: The engine model.
    ///   - shotID: The shot to compose.
    ///   - renderer: The bank's renderer.
    init(model: EngineModel, shotID: ShotID, renderer: CoreImageShotRenderer) {
        self.model = model
        self.shotID = shotID
        self.renderer = renderer
    }

    /// The shot as it is now, or nil once it has left the pool.
    private var shot: Shot? {
        model.shots.first { $0.id == shotID }
    }

    /// The lowest layer's frame that exists — the frame that says there is
    /// something to draw. Nil while no layer's input has delivered (or the
    /// shot has no layers), which the tile shows as black over its caption.
    var latest: CVPixelBuffer? {
        guard let shot else { return nil }
        for layer in shot.layers {
            if let frame = model.latestFrame(forInput: layer.input) { return frame }
        }
        return nil
    }

    /// The whole shot composed over its background in program pixels —
    /// every layer's latest frame, not only the one ``latest`` returned,
    /// which is the monitor's cue to draw rather than the picture itself.
    func image(for pixelBuffer: CVPixelBuffer) -> CIImage {
        guard let shot else { return CIImage(cvPixelBuffer: pixelBuffer) }
        return renderer.composedImage(shot: shot, frames: model.latestFrames(for: shot), format: model.format)
    }
}
