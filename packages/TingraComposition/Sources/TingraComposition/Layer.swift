//
//  Layer.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import TingraPlugInKit

/// One positioned element inside a shot: an input placed into a rectangle of
/// the program frame, with an opacity and an optional effect chain
/// (GLOSSARY.md, "Layer", "Effect chain"). Titles and overlays are later
/// additions.
///
/// A layer names its input by ``InputID`` rather than holding the input
/// itself, so a shot is a plain value the app can build, compare, and switch
/// live — the compositor resolves the id to the latest frame that input has
/// produced at tick time.
///
/// It is `Codable` as part of the persisted ``Shot`` document: the `frame` is
/// flattened to explicit `x`/`y`/`width`/`height` keys rather than the nested
/// arrays a `CGRect` would synthesize, keeping the JSON a clean, stable
/// project contract (CLAUDE.md, "Data Models").
public struct Layer: Sendable, Equatable, Codable {
    /// The input whose latest frame fills this layer. If that input has not
    /// produced a frame yet (or has stalled), the layer contributes nothing
    /// this tick and the layers beneath it show through.
    public let input: InputID

    /// Where the input's frame is drawn within the program frame, in
    /// **normalized, top-left-origin** coordinates: `(0, 0)` is the top-left
    /// corner of the program, `(1, 1)` the bottom-right. The default fills
    /// the whole program. The compositor flips this into Core Image's
    /// bottom-left space, so callers reason in the same top-left space as
    /// SwiftUI.
    public let frame: CGRect

    /// The layer's opacity, `0` (transparent) to `1` (opaque). Values
    /// outside the range are clamped by the renderer.
    public let opacity: Double

    /// The layer's video effect chain, in signal order (the chain *is* its
    /// array — ARCHITECTURE.md, "The effect seam"), or nil for no chain.
    /// The renderer applies it to the layer's frame **before** placement
    /// and opacity, so an effect sees the input's own image and the chain
    /// composes lazily into the one render pass. An **optional key within
    /// v1** (the pre-release rule, no version bump): absent means no
    /// chain, so every pre-effects document decodes unchanged.
    public let effects: [EffectConfiguration]?

    /// Creates a layer.
    ///
    /// - Parameters:
    ///   - input: The input whose latest frame fills the layer.
    ///   - frame: The normalized, top-left-origin destination rect within
    ///     the program frame (default: the whole program).
    ///   - opacity: The layer opacity, `0`...`1` (default `1`).
    ///   - effects: The layer's video effect chain, in signal order, or
    ///     nil (default) for no chain.
    public init(
        input: InputID,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        opacity: Double = 1,
        effects: [EffectConfiguration]? = nil
    ) {
        self.input = input
        self.frame = frame
        self.opacity = opacity
        self.effects = effects
    }

    /// The coding keys — the `frame` flattened to explicit components so the
    /// project document stays legible and stable.
    private enum CodingKeys: String, CodingKey {
        case input
        case x
        case y
        case width
        case height
        case opacity
        case effects
    }

    /// Decodes a layer. `input` is required; the `frame` components,
    /// `opacity`, and the effect chain are optional and fall back to the
    /// same defaults as the memberwise initializer (fill the whole
    /// program, full opacity, no chain), so a minimal hand-written layer
    /// needs only its input.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decode(InputID.self, forKey: .input)
        let x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        let y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        let width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 1
        let height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 1
        frame = CGRect(x: x, y: y, width: width, height: height)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        effects = try container.decodeIfPresent([EffectConfiguration].self, forKey: .effects)
    }

    /// Encodes a layer, always writing every settled field so the document
    /// round-trips exactly; the optional effect chain is written only when
    /// authored, so a chainless layer encodes as it did before effects
    /// existed.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(Double(frame.origin.x), forKey: .x)
        try container.encode(Double(frame.origin.y), forKey: .y)
        try container.encode(Double(frame.size.width), forKey: .width)
        try container.encode(Double(frame.size.height), forKey: .height)
        try container.encode(opacity, forKey: .opacity)
        try container.encodeIfPresent(effects, forKey: .effects)
    }
}
