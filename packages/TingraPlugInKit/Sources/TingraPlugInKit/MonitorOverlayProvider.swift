//
//  MonitorOverlayProvider.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics

/// What a plug-in registers for a monitor overlay: its identity, the stage
/// it runs at, its declared parameters, and a factory making one
/// ``MonitorOverlay`` per monitor (PLUGINS.md, Decision 53). The video
/// effect seam's ``VideoEffectProvider``, for the monitors.
public protocol MonitorOverlayProvider: ParameterDescribing {
    /// The overlay's stable identifier: what a project names to say it is
    /// on.
    var id: MonitorOverlayID { get }

    /// A short user-facing name, the Overlays submenu's item: "Title
    /// Safe".
    var name: String { get }

    /// Whether the overlay changes the picture or draws over it, which
    /// sets both its place in a monitor's draw and its section in the
    /// submenu.
    var stage: MonitorOverlayStage { get }

    /// Whether the overlay has anything to show on a canvas of this size:
    /// a 9:16 crop guide has nothing to show on a 9:16 program. A monitor
    /// overlay that is unavailable is shown disabled in the submenu and is
    /// not drawn, but stays on in the project, so it returns when the
    /// program format changes back. The default is `true`.
    ///
    /// - Parameter canvasSize: The size of the frame the monitor shows,
    ///   before fitting, in pixels.
    /// - Returns: Whether the overlay can draw anything.
    func isAvailable(onCanvas canvasSize: CGSize) -> Bool

    /// Whether the overlay has anything to show on this kind of monitor:
    /// showing alpha over a checkerboard has nothing to show on the
    /// program and preview monitors, whose pictures are opaque. Like an
    /// overlay unavailable on the canvas, it is shown disabled in that
    /// monitor's submenu and is not drawn there. The default is `true`.
    ///
    /// - Parameter monitor: The monitor the submenu or the draw is for.
    /// - Returns: Whether the overlay can draw anything there.
    func isAvailable(on monitor: MonitorOverlayContext.Monitor) -> Bool

    /// Whether the overlay draws the monitor's audio levels, as meters do.
    /// A monitor fills ``MonitorOverlayContext/audioLevels`` only while an
    /// overlay that asks for them is on, and then redraws whenever the
    /// levels change, even on a still picture. The default is `false`.
    var usesAudioLevels: Bool { get }

    /// Makes one monitor's overlay, configured with that monitor's
    /// parameter payload (keys the payload omits take their declared
    /// defaults).
    ///
    /// - Parameter parameters: The parameter payload.
    /// - Returns: A fresh overlay; the monitor owns it.
    func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay
}

extension MonitorOverlayProvider {
    /// Every canvas: most overlays draw on any picture.
    public func isAvailable(onCanvas canvasSize: CGSize) -> Bool {
        true
    }

    /// Every monitor: most overlays draw on any monitor.
    public func isAvailable(on monitor: MonitorOverlayContext.Monitor) -> Bool {
        true
    }

    /// No levels: most overlays draw the same whatever the sound does.
    public var usesAudioLevels: Bool {
        false
    }
}
