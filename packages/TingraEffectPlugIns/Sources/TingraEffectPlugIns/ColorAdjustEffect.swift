//
//  ColorAdjustEffect.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreImage.CIFilterBuiltins
import TingraPlugInKit

/// The color adjustment effect's provider: brightness, contrast, and
/// saturation on a layer — the first GLOSSARY.md video effect, and the
/// shading control an operator reaches for first when a camera does not
/// match the others.
public struct ColorAdjustEffectProvider: VideoEffectProvider {
    /// The color adjustment effect's stable identifier on the
    /// project/scripting contract.
    public static let effectID = EffectID(rawValue: "colorAdjust")

    /// The provider's stable identifier.
    public let id = Self.effectID

    /// The user-facing effect name.
    public let name = "Color Adjustment"

    /// The three parameters, each neutral at its Core Image identity value.
    public var parameters: [EffectParameter] {
        [
            EffectParameter(
                key: ColorAdjustEffect.brightnessKey, name: "Brightness", range: -1...1, defaultValue: 0),
            EffectParameter(
                key: ColorAdjustEffect.contrastKey, name: "Contrast", range: 0.25...4, defaultValue: 1),
            EffectParameter(
                key: ColorAdjustEffect.saturationKey, name: "Saturation", range: 0...2, defaultValue: 1),
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Creates one chain slot's color adjustment at the payload's settings.
    public func makeEffect(parameters: [String: JSONValue]) -> any VideoEffect {
        var effect = ColorAdjustEffect()
        effect.setParameters(parameters)
        return effect
    }
}

/// A brightness/contrast/saturation trim over `CIColorControls` — a lazy
/// Core Image filter the renderer fuses into its one render pass.
public struct ColorAdjustEffect: VideoEffect {
    /// The persisted parameter key of the brightness trim.
    static let brightnessKey = "brightness"

    /// The persisted parameter key of the contrast scale.
    static let contrastKey = "contrast"

    /// The persisted parameter key of the saturation scale.
    static let saturationKey = "saturation"

    /// The current brightness trim (`0` is neutral).
    private var brightness: Double = 0

    /// The current contrast scale (`1` is neutral).
    private var contrast: Double = 1

    /// The current saturation scale (`1` is neutral).
    private var saturation: Double = 1

    /// Creates the effect at its neutral settings.
    public init() {}

    /// Reads any of the three settings from the payload, clamped to their
    /// declared ranges; absent or non-numeric keys keep their current
    /// values.
    public mutating func setParameters(_ parameters: [String: JSONValue]) {
        if let value = parameters[Self.brightnessKey]?.doubleValue {
            brightness = min(1, max(-1, value))
        }
        if let value = parameters[Self.contrastKey]?.doubleValue {
            contrast = min(4, max(0.25, value))
        }
        if let value = parameters[Self.saturationKey]?.doubleValue {
            saturation = min(2, max(0, value))
        }
    }

    /// Applies the trim, or returns the image untouched when every
    /// setting is neutral (a neutral chain slot costs nothing).
    public func process(_ image: CIImage) -> CIImage {
        guard brightness != 0 || contrast != 1 || saturation != 1 else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = Float(brightness)
        filter.contrast = Float(contrast)
        filter.saturation = Float(saturation)
        return filter.outputImage ?? image
    }
}
