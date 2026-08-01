//
//  MultiviewView.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The multiview window: program, preview, and every running input tiled at
/// once for monitoring (GLOSSARY.md, "Multiview").
///
/// It is **not a bus** — nothing is fed from it and nothing is promoted out
/// of it, which is the test a bus has to pass. It is a monitoring surface
/// over surfaces that already exist: program and preview read the relays the
/// main window's monitors already read, and each input tile pulls that
/// input's latest frame straight from the compositor's latest-wins slot at
/// display cadence (ARCHITECTURE.md, "Multiview"; CLOCK.md's
/// preview-sampling rule). Nothing here runs while the window is closed, and
/// the engine's tick task is untouched by its existence.
///
/// The main window now carries the same ``InputGridView`` in its top section,
/// which is what this window is: the grid beneath the two monitors. It still
/// earns its place — a multiview's conventional home is a second display,
/// which a window gives for free, and there its tiles are as large as the
/// screen rather than as large as the space the switcher leaves them
/// (ARCHITECTURE.md, "The main window's two sections"). The tiles are inert
/// on both surfaces, for the reason recorded on ``InputGridView``.
struct MultiviewView: View {
    /// The engine model — read only: multiview changes nothing.
    let model: EngineModel

    /// Program and preview across the top, the input tiles beneath.
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Preview left of program, the same left-to-right reading
                // order the main window uses.
                MonitorTile(
                    source: model.previewRelay,
                    label: Text(
                        "Preview", comment: "Name of the preview bus — labels its monitor and its switcher row"),
                    badgeTint: .green
                )
                MonitorTile(
                    source: model.programRelay,
                    label: Text(
                        "Program", comment: "Name of the program bus — labels its monitor and its switcher row"),
                    badgeTint: .red
                )
            }

            InputGridView(model: model)
        }
        .padding()
        .background(.background)
    }
}
