//
//  BlurEffect.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreImage.CIFilterBuiltins
import TingraPlugInKit

/// The blur effect's provider: a Gaussian blur on a layer — the second
/// GLOSSARY.md video effect, and the one a production reaches for to
/// obscure a background or soften a plate.
public struct BlurEffectProvider: VideoEffectProvider {
    /// The blur effect's stable identifier on the project/scripting
    /// contract.
    public static let effectID = EffectID(rawValue: "blur")

    /// The provider's stable identifier.
    public let id = Self.effectID

    /// The user-facing effect name.
    public let name = "Blur"

    /// The one parameter: the blur radius in pixels of the layer's own
    /// image, `0` (no blur) by default.
    public var parameters: [EffectParameter] {
        [
            EffectParameter(
                key: BlurEffect.radiusKey,
                name: "Radius",
                range: BlurEffect.radiusRange,
                defaultValue: 0,
                unit: "px"
            )
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Creates one chain slot's blur at the payload's radius.
    public func makeEffect(parameters: [String: JSONValue]) -> any VideoEffect {
        var effect = BlurEffect()
        effect.setParameters(parameters)
        return effect
    }
}

/// A Gaussian blur over `CIGaussianBlur` — a lazy Core Image filter the
/// renderer fuses into its one render pass. The radius is in pixels of the
/// layer's own captured image, applied before placement, so it means the
/// same thing wherever the layer sits in the program.
public struct BlurEffect: VideoEffect {
    /// The persisted parameter key of the radius.
    static let radiusKey = "radiusPixels"

    /// The radii the effect accepts, in pixels.
    static let radiusRange: ClosedRange<Double> = 0...100

    /// The current blur radius in pixels (`0` is no blur).
    private var radius: Double = 0

    /// Creates the effect with no blur.
    public init() {}

    /// Reads a new `radiusPixels` from the payload, clamped to the
    /// declared range; an absent or non-numeric key keeps the current
    /// radius.
    public mutating func setParameters(_ parameters: [String: JSONValue]) {
        guard let value = parameters[Self.radiusKey]?.doubleValue else { return }
        radius = min(Self.radiusRange.upperBound, max(Self.radiusRange.lowerBound, value))
    }

    /// Blurs the image, or returns it untouched at radius zero (a neutral
    /// chain slot costs nothing).
    public func process(_ image: CIImage) -> CIImage {
        guard radius > 0 else { return image }
        let filter = CIFilter.gaussianBlur()
        // The blur bleeds past the source extent; clamping first keeps the
        // layer's edges opaque instead of fading into transparency, and the
        // renderer crops the chain's output back to the source extent.
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(radius)
        return filter.outputImage ?? image
    }
}
