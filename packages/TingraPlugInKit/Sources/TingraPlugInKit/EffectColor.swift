//
//  EffectColor.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The value of a color effect parameter (``EffectParameter/Kind/color``):
/// sRGB red, green, blue, and alpha, each `0`…`1` — the working format's
/// BT.709 primaries, so an effect can hand the components to Core Image
/// unconverted (ARCHITECTURE.md, "The Frame effect").
///
/// In a persisted ``EffectConfiguration/parameters`` payload a color is
/// the object `{"red": r, "green": g, "blue": b, "alpha": a}` under the
/// parameter's key — plain JSON on the project/scripting contract, never a
/// packed integer or a hex string. Components outside `0`…`1` are clamped
/// on creation, so a payload can never produce an out-of-gamut value.
public struct EffectColor: Sendable, Equatable, Codable {
    /// The red component, `0`…`1`.
    public let red: Double

    /// The green component, `0`…`1`.
    public let green: Double

    /// The blue component, `0`…`1`.
    public let blue: Double

    /// The alpha component, `0` (transparent) to `1` (opaque).
    public let alpha: Double

    /// Opaque white — the default of a border.
    public static let white = EffectColor(red: 1, green: 1, blue: 1)

    /// Opaque black.
    public static let black = EffectColor(red: 0, green: 0, blue: 0)

    /// Creates a color, clamping every component to `0`…`1`.
    ///
    /// - Parameters:
    ///   - red: The red component.
    ///   - green: The green component.
    ///   - blue: The blue component.
    ///   - alpha: The alpha component (default opaque).
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
        self.alpha = Self.clamped(alpha)
    }

    /// Reads a color out of a payload value: the `{red, green, blue,
    /// alpha}` object shape, with a missing `alpha` meaning opaque. Any
    /// other shape — a number, a string, an object missing a color
    /// component — is nil, so an effect keeps its current color rather
    /// than guessing.
    ///
    /// - Parameter value: The payload value under the parameter's key.
    public init?(_ value: JSONValue) {
        guard
            let members = value.objectValue,
            let red = members["red"]?.doubleValue,
            let green = members["green"]?.doubleValue,
            let blue = members["blue"]?.doubleValue
        else { return nil }
        self.init(red: red, green: green, blue: blue, alpha: members["alpha"]?.doubleValue ?? 1)
    }

    /// The color as its payload value — the `{red, green, blue, alpha}`
    /// object ``init(_:)`` reads back.
    public var jsonValue: JSONValue {
        .object([
            "red": .double(red),
            "green": .double(green),
            "blue": .double(blue),
            "alpha": .double(alpha),
        ])
    }

    /// Clamps one component into `0`…`1`; a non-finite value becomes `0`.
    private static func clamped(_ component: Double) -> Double {
        guard component.isFinite else { return 0 }
        return min(1, max(0, component))
    }
}
