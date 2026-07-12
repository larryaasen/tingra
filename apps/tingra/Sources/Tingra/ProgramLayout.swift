//
//  ProgramLayout.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Foundation
import TingraComposition
import TingraPlugInKit

/// The app's built-in program layout: how the chosen display and camera become
/// a preset's shots and their layer trees. A pure function of the active input
/// ids, so the arrangement is unit-testable without any hardware, TCC, or the
/// compositor.
///
/// The layer rule (``layers(displayID:cameraID:)``): the display is the
/// full-frame background; the camera composites over it as a bottom-right
/// picture-in-picture. Whichever input is present alone fills the whole
/// program.
///
/// From those, ``shots(displayID:cameraID:)`` builds the switchable shots the
/// operator cuts among (step 7): a picture-in-picture shot plus a full-frame
/// shot per input when both are present, or a single full-frame shot when only
/// one is. The shot ids are **fixed tokens** (not fresh UUIDs) — originally so
/// identity survived a selection-change rebuild; with the project file, a
/// selection change rebinds instead of rebuilding, so the tokens now serve as
/// the seed's identity and key the switcher's per-shot tap names. This
/// arrangement seeds a **fresh project only** (ARCHITECTURE.md, "Project
/// save/load"), and once seeded these are just shots — renameable and
/// removable like any user-authored shot ("Shot management").
enum ProgramLayout {
    /// The camera's picture-in-picture rect over a display, in normalized,
    /// top-left-origin coordinates (bottom-right corner, with a small margin).
    static let cameraInsetFrame = CGRect(x: 0.68, y: 0.68, width: 0.28, height: 0.28)

    /// The stable id of the display-only shot.
    static let displayShotID = ShotID(rawValue: "display")

    /// The stable id of the camera-only shot.
    static let cameraShotID = ShotID(rawValue: "camera")

    /// The stable id of the picture-in-picture shot (display with the camera
    /// inset over it).
    static let pictureInPictureShotID = ShotID(rawValue: "pip")

    /// Builds the switchable shots for the active inputs, in switcher order.
    ///
    /// - Parameters:
    ///   - displayID: The active display input, or nil for none.
    ///   - cameraID: The active camera input, or nil for none.
    /// - Returns: With both inputs, a picture-in-picture shot (the default,
    ///   listed first) plus a full-frame display shot and a full-frame camera
    ///   shot; with only one input, that single full-frame shot; with neither,
    ///   no shots (a background-only program).
    static func shots(displayID: InputID?, cameraID: InputID?) -> [Shot] {
        switch (displayID, cameraID) {
        case (let display?, let camera?):
            return [
                Shot(
                    id: pictureInPictureShotID,
                    name: String(
                        localized: "Picture in Picture", bundle: .module, comment: "Shot: display with camera inset"),
                    layers: layers(displayID: display, cameraID: camera)
                ),
                Shot(
                    id: displayShotID,
                    name: String(localized: "Display", bundle: .module, comment: "Shot: display full-frame"),
                    layers: layers(displayID: display, cameraID: nil)
                ),
                Shot(
                    id: cameraShotID,
                    name: String(localized: "Camera", bundle: .module, comment: "Shot: camera full-frame"),
                    layers: layers(displayID: nil, cameraID: camera)
                ),
            ]
        case (let display?, nil):
            return [
                Shot(
                    id: displayShotID,
                    name: String(localized: "Display", bundle: .module, comment: "Shot: display full-frame"),
                    layers: layers(displayID: display, cameraID: nil)
                )
            ]
        case (nil, let camera?):
            return [
                Shot(
                    id: cameraShotID,
                    name: String(localized: "Camera", bundle: .module, comment: "Shot: camera full-frame"),
                    layers: layers(displayID: nil, cameraID: camera)
                )
            ]
        case (nil, nil):
            return []
        }
    }

    /// The tap event name for one of the switcher's built-in shot buttons
    /// (EVENTS.md, "The `tap` convention"). Distinct per shot rather than one
    /// generic name for all three — Larry, 2026-07-06: tap names should be
    /// "clear, unique, and descriptive," scoped to the screen they're on
    /// rather than unique across the whole app, so each button's clicks are
    /// independently traceable in the log instead of lumped together and
    /// told apart only by params.
    ///
    /// - Parameter shotID: The id of the tapped shot.
    /// - Returns: `camera.button`, `display.button`, or `pip.button` for the
    ///   three seeded shots; `shot.button` for any other id (a user-authored
    ///   shot added or duplicated in the switcher).
    static func tapName(forShotID shotID: ShotID) -> String {
        switch shotID {
        case cameraShotID: return "camera.button"
        case displayShotID: return "display.button"
        case pictureInPictureShotID: return "pip.button"
        default: return "shot.button"
        }
    }

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
