//
//  FrameEffect.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreImage.CIFilterBuiltins
import TingraPlugInKit

/// The frame effect's provider: rounded corners and a border on a layer —
/// the third GLOSSARY.md video effect, and the treatment a
/// picture-in-picture layer gets to sit on a background (ARCHITECTURE.md,
/// "The Frame effect").
public struct FrameEffectProvider: VideoEffectProvider {
    /// The frame effect's stable identifier on the project/scripting
    /// contract.
    public static let effectID = EffectID(rawValue: "frame")

    /// The provider's stable identifier.
    public let id = Self.effectID

    /// The user-facing effect name.
    public let name = "Frame"

    /// The three parameters: the corner radius and border width as
    /// fractions of the layer image's shorter side — never pixels, since
    /// the chain runs before placement and a corner must look the same on
    /// a full-frame layer and a small inset one — and the border color.
    /// The sizes are `0` by default, so a fresh Frame draws nothing, and
    /// declare the `%` unit: a stored fraction a host shows as percent.
    public var parameters: [EffectParameter] {
        [
            EffectParameter(
                key: FrameEffect.cornerRadiusKey,
                name: "Corners",
                range: FrameEffect.cornerRadiusRange,
                defaultValue: 0,
                unit: "%"
            ),
            EffectParameter(
                key: FrameEffect.borderWidthKey,
                name: "Border",
                range: FrameEffect.borderWidthRange,
                defaultValue: 0,
                unit: "%"
            ),
            EffectParameter(
                key: FrameEffect.borderColorKey,
                name: "Color",
                defaultColor: FrameEffect.defaultBorderColor
            ),
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Creates one chain slot's frame at the payload's settings.
    public func makeEffect(parameters: [String: JSONValue]) -> any VideoEffect {
        var effect = FrameEffect()
        effect.setParameters(parameters)
        return effect
    }
}

/// Rounded corners and an inside border over four built-in Core Image
/// filters, fused lazily into the renderer's one pass: a rounded-rectangle
/// mask at the image's extent keeps the picture only inside the corners
/// (source-in), the border is the ring between that rounded rectangle and
/// one inset by the border width (source-out), filled with the border
/// color and composited over the masked picture, and the result is
/// cropped back to the source extent so the layer never grows past its
/// frame.
public struct FrameEffect: VideoEffect {
    /// The persisted parameter key of the corner radius.
    static let cornerRadiusKey = "cornerRadius"

    /// The persisted parameter key of the border width.
    static let borderWidthKey = "borderWidth"

    /// The persisted parameter key of the border color.
    static let borderColorKey = "borderColor"

    /// The corner radii the effect accepts, as a fraction of the shorter
    /// side: a half is a full pill on the short axis.
    static let cornerRadiusRange: ClosedRange<Double> = 0...0.5

    /// The border widths the effect accepts, as a fraction of the shorter
    /// side.
    static let borderWidthRange: ClosedRange<Double> = 0...0.1

    /// The border color when the payload names none: opaque white.
    static let defaultBorderColor = EffectColor.white

    /// The current corner radius as a fraction of the shorter side (`0` is
    /// square corners).
    private var cornerRadius: Double = 0

    /// The current border width as a fraction of the shorter side (`0` is
    /// no border).
    private var borderWidth: Double = 0

    /// The current border color.
    private var borderColor = FrameEffect.defaultBorderColor

    /// Creates the effect at its neutral settings.
    public init() {}

    /// Reads any of the three settings from the payload, the sizes clamped
    /// to their declared ranges; absent or ill-shaped keys keep their
    /// current values.
    public mutating func setParameters(_ parameters: [String: JSONValue]) {
        if let value = parameters[Self.cornerRadiusKey]?.doubleValue {
            cornerRadius = Self.cornerRadiusRange.clamping(value)
        }
        if let value = parameters[Self.borderWidthKey]?.doubleValue {
            borderWidth = Self.borderWidthRange.clamping(value)
        }
        if let value = parameters[Self.borderColorKey], let color = EffectColor(value) {
            borderColor = color
        }
    }

    /// Rounds the corners and draws the border, or returns the image
    /// untouched when both sizes are zero (a neutral chain slot costs
    /// nothing) or the image has no edge to round (an infinite extent).
    public func process(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard cornerRadius > 0 || borderWidth > 0, !extent.isInfinite, !extent.isEmpty else { return image }
        let shorterSide = min(extent.width, extent.height)
        let radius = cornerRadius * shorterSide
        let width = borderWidth * shorterSide

        let mask = Self.roundedRectangle(extent, radius: radius, color: .white)
        let masked = image.applyingFilter(
            "CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        guard width > 0 else { return masked.cropped(to: extent) }

        let ring = Self.roundedRectangle(extent, radius: radius, color: Self.ciColor(borderColor))
            .applyingFilter(
                "CISourceOutCompositing",
                parameters: [
                    kCIInputBackgroundImageKey: Self.roundedRectangle(
                        extent.insetBy(dx: width, dy: width), radius: max(0, radius - width), color: .white)
                ]
            )
        return ring.composited(over: masked).cropped(to: extent)
    }

    /// A filled rounded rectangle covering `extent`, with the radius capped
    /// at half the shorter side so a generator is never asked for more
    /// than a pill.
    private static func roundedRectangle(_ extent: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = extent
        filter.radius = Float(min(radius, min(extent.width, extent.height) / 2))
        filter.color = color
        return filter.outputImage ?? CIImage(color: color).cropped(to: extent)
    }

    /// The border color as Core Image's sRGB color.
    private static func ciColor(_ color: EffectColor) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
