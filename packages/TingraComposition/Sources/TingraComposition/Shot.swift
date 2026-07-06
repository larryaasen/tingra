//
//  Shot.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A short-term composition: an ordered arrangement of layers plus the
/// background they sit over (GLOSSARY.md, "Shot"). The compositor renders a
/// shot's layer tree to a single program frame each tick.
///
/// Layers are ordered **bottom to top**: `layers[0]` is drawn first (nearest
/// the background) and later layers composite over it. A shot with no layers
/// (or whose layers' inputs have no frames yet) renders as the background
/// alone — the program is always a live canvas at the tick rate, even before
/// any input delivers (CLOCK.md, "The program tick").
public struct Shot: Sendable, Equatable {
    /// The layer tree, bottom to top.
    public let layers: [Layer]

    /// The background the layers composite over, as straight RGBA in
    /// `0`...`1`. Defaults to opaque black — the broadcast-safe empty
    /// program.
    public let background: BackgroundColor

    /// Creates a shot.
    ///
    /// - Parameters:
    ///   - layers: The layer tree, bottom to top.
    ///   - background: The background color (default: opaque black).
    public init(layers: [Layer] = [], background: BackgroundColor = .black) {
        self.layers = layers
        self.background = background
    }
}

/// A straight (non-premultiplied) RGBA background color in `0`...`1`
/// components — the fill the compositor clears the program frame to before
/// drawing the layer tree.
public struct BackgroundColor: Sendable, Equatable {
    /// The red component, `0`...`1`.
    public let red: Double

    /// The green component, `0`...`1`.
    public let green: Double

    /// The blue component, `0`...`1`.
    public let blue: Double

    /// The alpha component, `0`...`1`.
    public let alpha: Double

    /// Creates a background color from straight RGBA components.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Opaque black — the default empty program background.
    public static let black = BackgroundColor(red: 0, green: 0, blue: 0, alpha: 1)
}
