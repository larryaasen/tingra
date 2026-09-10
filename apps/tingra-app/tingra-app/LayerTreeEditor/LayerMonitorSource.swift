//
//  LayerMonitorSource.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreVideo
import TingraComposition
import TingraPlugInKit

/// The frame source behind the inspector's layer monitor: the selected
/// layer's input, drawn through the layer's effect chain, so a corner, a
/// border, or a crop is seen at a legible size the moment a slider moves
/// (ARCHITECTURE.md, "The effect chain says its order, and the layer gets
/// a monitor"). Reads the selection on every draw, so the one monitor in
/// the column follows whichever layer is selected.
///
/// The chain's instances are the monitor's own, separate from the
/// renderer's (an effect may carry state), kept in a reference so a
/// display-rate draw rebuilds them only when the chain's configurations
/// change. The frame is read, drawn, and dropped within one draw, as every
/// monitor's is.
@MainActor
struct LayerMonitorSource: MonitorFrameSource {
    /// The model: the selection, the frames, and the effect providers.
    let model: EngineModel

    /// The live chain, rebuilt when the selected layer's chain changes.
    private let cache = LayerChainCache()

    /// Creates the source over the model's selected layer.
    ///
    /// - Parameter model: The engine model.
    init(model: EngineModel) {
        self.model = model
    }

    /// The selected layer's input's most recent frame, or nil while
    /// nothing is selected or the input has not delivered one.
    var latest: CVPixelBuffer? {
        guard let layer = model.selectedLayer?.layer else { return nil }
        return model.latestFrame(forInput: layer.input)
    }

    /// The frame after the selected layer's chain, scaled to the
    /// proportion of the layer's frame in the program — the picture as
    /// the layer places it, a stretch included, which is what the program
    /// shows and what the operator is judging. Opacity is left out: over
    /// the monitor's black it would read as dimming, not as the blend the
    /// program makes over the layers beneath.
    func image(for pixelBuffer: CVPixelBuffer) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let layer = model.selectedLayer?.layer else { return image }
        let picture: CIImage
        if let configurations = layer.effects, !configurations.isEmpty {
            picture = cache.apply(configurations, to: image, makeVideoEffect: model.makeVideoEffect(for:))
        } else {
            picture = image
        }
        return Self.placed(picture, in: layer.frame, format: model.format)
    }

    /// The picture scaled to the layer frame's size in program pixels, at
    /// the origin — the renderer's placement without its translation. The
    /// picture unchanged when either size is empty.
    ///
    /// - Parameters:
    ///   - picture: The picture after the chain.
    ///   - frame: The layer's normalized frame.
    ///   - format: The program format the frame is normalized against.
    private static func placed(_ picture: CIImage, in frame: CGRect, format: ProgramFormat) -> CIImage {
        let extent = picture.extent
        let width = frame.width * Double(format.width)
        let height = frame.height * Double(format.height)
        guard extent.width > 0, extent.height > 0, width > 0, height > 0 else { return picture }
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: width / extent.width, y: height / extent.height))
        return picture.transformed(by: transform)
    }
}

/// The reference holding a layer monitor's live chain across draws: a
/// `VideoEffectChain` is a value whose instances may advance state on each
/// apply, and the source is a struct handed to the monitor once.
@MainActor
private final class LayerChainCache {
    /// The chain built for the configurations last seen, or nil before
    /// the first draw with a chain.
    private var chain: VideoEffectChain?

    /// Runs the chain for `configurations` over the image, rebuilding the
    /// instances first if the configurations changed since the last draw.
    ///
    /// - Parameters:
    ///   - configurations: The selected layer's chain now.
    ///   - image: The frame's image.
    ///   - makeVideoEffect: Resolves one configuration into a live effect.
    /// - Returns: The image after the chain.
    func apply(
        _ configurations: [EffectConfiguration],
        to image: CIImage,
        makeVideoEffect: (EffectConfiguration) -> (any VideoEffect)?
    ) -> CIImage {
        if chain?.configurations != configurations {
            chain = VideoEffectChain(configurations: configurations, makeVideoEffect: makeVideoEffect)
        }
        guard var live = chain else { return image }
        let output = live.apply(to: image)
        chain = live
        return output
    }
}
