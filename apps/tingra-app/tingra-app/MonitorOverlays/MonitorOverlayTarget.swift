//
//  MonitorOverlayTarget.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraPlugInKit

/// The monitors whose monitor overlays a project saves, one list each
/// (PLUGINS.md, Decision 55 and "Slice 2 as built"): program, preview,
/// every input tile together, and the layer monitor. The multiview
/// window's two bus monitors are the main window's two monitors on another
/// display, so they draw the same overlays; the input tiles are
/// interchangeable, so they share one list.
enum MonitorOverlayTarget: String, CaseIterable, Sendable {
    /// The program monitor.
    case program

    /// The preview monitor.
    case preview

    /// Every multiview input tile.
    case input

    /// The inspector's layer monitor.
    case layer

    /// The target a monitor's snapshot subject names: every monitor that
    /// takes a snapshot draws overlays too.
    ///
    /// - Parameter subject: The monitor's snapshot subject.
    init(subject: SnapshotSubject) {
        switch subject {
        case .program: self = .program
        case .preview: self = .preview
        case .input: self = .input
        case .layer: self = .layer
        }
    }

    /// The monitor a monitor overlay is told is drawing, which is also the
    /// key of its list in the project.
    var monitor: MonitorOverlayContext.Monitor {
        switch self {
        case .program: .program
        case .preview: .preview
        case .input: .input
        case .layer: .layer
        }
    }

    /// The monitor's tally when nothing more is known: a bus monitor is
    /// always lit in its bus's color, and the layer monitor is unlit. An
    /// input tile's tally is its input's, which the tile passes itself.
    var defaultTally: MonitorOverlayContext.Tally {
        switch self {
        case .program: .program
        case .preview: .preview
        case .input, .layer: .unlit
        }
    }

    /// Whether the program format is the canvas this monitor shows: true
    /// for program and preview. An input tile shows its input's own size
    /// and the layer monitor its layer's, which differ tile by tile and
    /// layer by layer, so an overlay's canvas check is left to each draw.
    var showsProgramCanvas: Bool {
        switch self {
        case .program, .preview: true
        case .input, .layer: false
        }
    }

    /// The monitor as an event parameter.
    var eventValue: EventValue {
        .string(rawValue)
    }
}

extension MultiviewTile.Tally {
    /// The tile's tally as a monitor overlay is told it: on air is the
    /// program's red, staged is the preview's green.
    var monitorOverlayTally: MonitorOverlayContext.Tally {
        switch self {
        case .onAir: .program
        case .staged: .preview
        case .idle: .unlit
        }
    }
}
