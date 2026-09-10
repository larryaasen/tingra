//
//  VideoEffectChain.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// One layer's live effect chain: the instances built from its persisted
/// configurations, in signal order, and the one way of running them —
/// shared by the renderer (one per shot and layer) and the app's layer
/// monitor (one per selected layer), so a picture is processed the same
/// wherever it is drawn (ARCHITECTURE.md, "The effect chain says its
/// order, and the layer gets a monitor").
///
/// A value type: the instances are value types whose `process` may
/// advance their own state, so a holder keeps the chain in a `var` and
/// stores it back after each ``apply(to:)``.
public struct VideoEffectChain {
    /// The configurations the instances were built from — the holder
    /// compares these to decide when to rebuild.
    public let configurations: [EffectConfiguration]

    /// The live instances, in signal order. A configuration the factory
    /// declined (no provider in this build) has no instance here; its slot
    /// is pass-through.
    private var effects: [any VideoEffect]

    /// Builds the chain's instances.
    ///
    /// - Parameters:
    ///   - configurations: The layer's persisted chain, in signal order.
    ///   - makeVideoEffect: Resolves one configuration into a live effect,
    ///     or nil for a slot this build cannot serve.
    public init(
        configurations: [EffectConfiguration],
        makeVideoEffect: (EffectConfiguration) -> (any VideoEffect)?
    ) {
        self.configurations = configurations
        self.effects = configurations.compactMap(makeVideoEffect)
    }

    /// Whether the chain has no live instance — the picture passes
    /// through untouched.
    public var isEmpty: Bool { effects.isEmpty }

    /// Runs the chain over an image, in signal order, and crops the
    /// result to the input's extent: an effect may grow the extent (a
    /// blur bleeds past the edges) and a layer occupies its frame, never
    /// more — while an effect that shrinks it (a crop) leaves the extent
    /// it keeps, which the renderer then places (ARCHITECTURE.md, "The
    /// Crop effect"). Composes lazily, `CIImage` to `CIImage`.
    ///
    /// - Parameter image: The layer's image before the chain.
    /// - Returns: The image after the chain.
    public mutating func apply(to image: CIImage) -> CIImage {
        guard !effects.isEmpty else { return image }
        var output = image
        for index in effects.indices {
            output = effects[index].process(output)
        }
        return output.cropped(to: image.extent)
    }
}
