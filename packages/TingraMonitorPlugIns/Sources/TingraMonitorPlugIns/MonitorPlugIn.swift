//
//  MonitorPlugIn.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The first-party monitor overlay plug-in (PLUGINS.md, Decision 56):
/// registers the common monitor overlays through the same
/// `MonitorOverlayRegistering` seam a third-party bundle uses, in the
/// fixed order the Overlays submenu lists them.
public struct MonitorPlugIn: PlugIn {
    /// The plug-in's stable identifier, also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.monitorOverlays")

    /// The user-facing plug-in name.
    public let name = "Monitor Overlays"

    /// The overlays this plug-in registers, in submenu order: the picture
    /// overlays (flip, blue only, zebra, alpha), then the guides: the tally
    /// border, the two safe areas, the three crop guides, the center cross,
    /// the center lines, the grid, and the VU meters.
    static let providers: [any MonitorOverlayProvider] = [
        FlipHorizontalOverlayProvider(),
        BlueOnlyOverlayProvider(),
        ZebraOverlayProvider(),
        ShowAlphaOverlayProvider(),
        TallyBorderOverlayProvider(),
        SafeAreaOverlayProvider.titleSafe,
        SafeAreaOverlayProvider.actionSafe,
        CropGuideOverlayProvider.fourByThree,
        CropGuideOverlayProvider.square,
        CropGuideOverlayProvider.nineBySixteen,
        CenterCrossOverlayProvider(),
        CenterLinesOverlayProvider(),
        RuleOfThirdsOverlayProvider(),
        VUMetersOverlayProvider(),
    ]

    /// The ids of the overlays this plug-in registers, in submenu order: the
    /// order a front end lists the first-party overlays in, ahead of any
    /// other plug-in's.
    public static var overlayIDs: [MonitorOverlayID] {
        providers.map(\.id)
    }

    /// Creates the plug-in.
    public init() {}

    /// Registers the first-party monitor overlays.
    ///
    /// - Parameter context: The host's registration seams.
    /// - Throws: The registry's error when an overlay's id is taken.
    public func activate(in context: PlugInContext) async throws {
        for provider in Self.providers {
            try await context.monitorOverlays.register(provider)
        }
    }
}
