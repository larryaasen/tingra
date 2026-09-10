//
//  CropEffect.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// The crop effect's provider: a layer that shows only part of its input's
/// picture — a portrait strip out of a landscape camera, say — the fourth
/// GLOSSARY.md video effect (ARCHITECTURE.md, "The Crop effect").
public struct CropEffectProvider: VideoEffectProvider {
    /// The crop effect's stable identifier on the project/scripting
    /// contract.
    public static let effectID = EffectID(rawValue: "crop")

    /// The provider's stable identifier.
    public let id = Self.effectID

    /// The user-facing effect name.
    public let name = "Crop"

    /// The four insets — left, top, right, bottom — each a fraction of the
    /// image's width or height cut from that edge, all `0` by default so a
    /// fresh Crop shows the whole picture. Fractions rather than pixels
    /// for the Frame effect's reason: the chain runs before placement,
    /// and a third off each side means the same thing for a 4K camera
    /// and a 720p display. Each declares the `%` unit: a stored fraction a
    /// host shows as percent.
    public var parameters: [EffectParameter] {
        [
            EffectParameter(
                key: CropEffect.leftKey, name: "Left", range: CropEffect.insetRange, defaultValue: 0, unit: "%"),
            EffectParameter(
                key: CropEffect.topKey, name: "Top", range: CropEffect.insetRange, defaultValue: 0, unit: "%"),
            EffectParameter(
                key: CropEffect.rightKey, name: "Right", range: CropEffect.insetRange, defaultValue: 0, unit: "%"),
            EffectParameter(
                key: CropEffect.bottomKey, name: "Bottom", range: CropEffect.insetRange, defaultValue: 0, unit: "%"),
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Creates one chain slot's crop at the payload's settings.
    public func makeEffect(parameters: [String: JSONValue]) -> any VideoEffect {
        var effect = CropEffect()
        effect.setParameters(parameters)
        return effect
    }
}

/// A crop by four edge insets: the kept rectangle is the image's extent
/// with each inset's fraction of the width or height cut from its edge,
/// rounded out to whole pixels. The renderer places the extent a chain
/// leaves into the layer's frame, so the kept region becomes the layer's
/// whole picture — a crop, not a mask — and ``outputExtent(for:)``
/// answers with the same rectangle so the inspector's Match Input can
/// measure the picture without rendering it. **Top is the picture's top**
/// (the operator's view), mapped here onto Core Image's bottom-left
/// space.
public struct CropEffect: VideoEffect {
    /// The persisted parameter key of the left inset.
    static let leftKey = "left"

    /// The persisted parameter key of the top inset.
    static let topKey = "top"

    /// The persisted parameter key of the right inset.
    static let rightKey = "right"

    /// The persisted parameter key of the bottom inset.
    static let bottomKey = "bottom"

    /// The insets the effect accepts, each as a fraction of the image's
    /// width or height: never a whole edge, so one slider alone always
    /// leaves some picture.
    static let insetRange: ClosedRange<Double> = 0...0.9

    /// The current left inset as a fraction of the width.
    private var left: Double = 0

    /// The current top inset as a fraction of the height.
    private var top: Double = 0

    /// The current right inset as a fraction of the width.
    private var right: Double = 0

    /// The current bottom inset as a fraction of the height.
    private var bottom: Double = 0

    /// Creates the effect at its neutral settings.
    public init() {}

    /// Reads any of the four insets from the payload, each clamped to the
    /// declared range; absent or ill-shaped keys keep their current
    /// values.
    public mutating func setParameters(_ parameters: [String: JSONValue]) {
        if let value = parameters[Self.leftKey]?.doubleValue {
            left = Self.insetRange.clamping(value)
        }
        if let value = parameters[Self.topKey]?.doubleValue {
            top = Self.insetRange.clamping(value)
        }
        if let value = parameters[Self.rightKey]?.doubleValue {
            right = Self.insetRange.clamping(value)
        }
        if let value = parameters[Self.bottomKey]?.doubleValue {
            bottom = Self.insetRange.clamping(value)
        }
    }

    /// Crops the image to the kept rectangle, or returns it untouched
    /// when every inset is zero (a neutral chain slot costs nothing),
    /// when the image has no edges to inset (an infinite extent), or when
    /// the insets leave nothing — the seam's pass-through rule, never a
    /// black layer.
    public func process(_ image: CIImage) -> CIImage {
        let kept = keptRectangle(in: image.extent)
        guard kept != image.extent else { return image }
        return image.cropped(to: kept)
    }

    /// The kept rectangle for an input extent — the same arithmetic
    /// ``process(_:)`` crops by.
    public func outputExtent(for inputExtent: CGRect) -> CGRect {
        keptRectangle(in: inputExtent)
    }

    /// The extent with the insets cut from its edges and rounded out to
    /// whole pixels, or the extent itself when there is nothing to cut or
    /// nothing would remain.
    private func keptRectangle(in extent: CGRect) -> CGRect {
        guard left > 0 || top > 0 || right > 0 || bottom > 0, !extent.isInfinite, !extent.isEmpty else {
            return extent
        }
        // Top is the picture's top: in bottom-left space that is the far
        // (maxY) edge, so the top inset lowers maxY and the bottom inset
        // raises minY.
        let kept = CGRect(
            x: extent.minX + left * extent.width,
            y: extent.minY + bottom * extent.height,
            width: extent.width * (1 - left - right),
            height: extent.height * (1 - top - bottom)
        )
        // The raw size, not `width`/`height`: those are absolute, and
        // insets that meet leave a negative size that must read as nothing.
        guard kept.size.width > 0, kept.size.height > 0 else { return extent }
        return kept.integral.intersection(extent)
    }
}
