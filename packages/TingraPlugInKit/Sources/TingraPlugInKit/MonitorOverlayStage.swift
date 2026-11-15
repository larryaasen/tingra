//
//  MonitorOverlayStage.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// Where in a monitor's draw a monitor overlay runs (PLUGINS.md, Decision
/// 53). A monitor runs every `.picture` overlay before any `.guide`
/// overlay, so a guide is always drawn over the picture a picture overlay
/// produced, never mirrored or recolored by it. The stages are also the
/// sections of a monitor's Overlays submenu.
public enum MonitorOverlayStage: Sendable, Hashable, CaseIterable {
    /// The overlay changes the picture itself, for checking it: a flip, a
    /// single channel, the alpha channel.
    case picture

    /// The overlay draws over the picture and leaves it as it is: a safe
    /// area, a crop guide, a center cross, a border.
    case guide
}
