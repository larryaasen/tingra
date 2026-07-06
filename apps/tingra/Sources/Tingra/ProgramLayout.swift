//
//  ProgramLayout.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import TingraComposition
import TingraPlugInKit

/// The step-6 program layout: how the chosen display and camera become a
/// shot's layer tree. A pure function of the active input ids, so the
/// arrangement is unit-testable without any hardware, TCC, or the compositor.
///
/// The rule: the display is the full-frame background; the camera composites
/// over it as a bottom-right picture-in-picture. Whichever input is present
/// alone fills the whole program; with neither, the program is the empty
/// (background-only) shot. Presets, multiple shots, and free layer transforms
/// replace this fixed arrangement at roadmap step 7.
enum ProgramLayout {
    /// The camera's picture-in-picture rect over a display, in normalized,
    /// top-left-origin coordinates (bottom-right corner, with a small margin).
    static let cameraInsetFrame = CGRect(x: 0.68, y: 0.68, width: 0.28, height: 0.28)

    /// Builds the layer tree, bottom to top, for the active inputs.
    ///
    /// - Parameters:
    ///   - displayID: The active display input, or nil for none.
    ///   - cameraID: The active camera input, or nil for none.
    /// - Returns: The layers for the shot — display first (background),
    ///   camera over it (full-frame when alone, a corner inset when a
    ///   display is also present).
    static func layers(displayID: InputID?, cameraID: InputID?) -> [Layer] {
        var layers: [Layer] = []
        if let displayID {
            layers.append(Layer(input: displayID))
        }
        if let cameraID {
            if layers.isEmpty {
                layers.append(Layer(input: cameraID))
            } else {
                layers.append(Layer(input: cameraID, frame: cameraInsetFrame))
            }
        }
        return layers
    }
}
