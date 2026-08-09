//
//  SidebarRow.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAudio
import TingraComposition
import TingraPlugInKit

/// One row of the main window's sidebar (``SidebarView``): the name to draw,
/// the identity to draw it by, and — for the rows that stage — what that row's
/// lamp reads.
///
/// One row type across every section, though they identify their subject by
/// four different things: a `ShotID` for a shot, an `InputID` for a capture
/// device or a generator, a `PresetID` for a preset, a `ProjectDestinationID`
/// for a destination, and a Core Audio UID for an output. A `ForEach` needs
/// one identity, and each id is unique within its own section, which is the
/// only place a row is drawn. Deriving the rows here also keeps the view
/// seam-only and every rule unit-testable with no window, as ``MultiviewTile``
/// carries the tile rule for `MultiviewView`.
struct SidebarRow: Identifiable, Equatable {
    /// The row's identity, as its subject's raw identifier: the shot's, the
    /// input's, the preset's, or the destination's `rawValue`, or the output
    /// device's Core Audio UID. The typed id is rebuilt from this at the call
    /// site, which is exact — every one of those id types is a raw-string
    /// wrapper.
    let id: String

    /// The user-facing name, drawn verbatim — a shot's or preset's authored
    /// name, a device name reported by discovery, or a destination's label,
    /// never a localized string.
    let name: String

    /// What this row's symbol reads, or nil for a row that does not stage.
    ///
    /// ``MultiviewTile/Tally`` rather than a second enum, so the tally means
    /// one thing across every surface that draws one — the input rows, the
    /// multiview window, and the sidebar's shot, camera, display, and
    /// generator sections. Nil everywhere else, and that is the tally's own
    /// rule rather than an omission: a microphone is on no bus the operator
    /// stages, an output device is not on a bus at all, and neither a preset
    /// nor a destination is a thing that goes to air.
    let tally: MultiviewTile.Tally?

    /// Whether this row is the current one among its section's alternatives —
    /// today, the active preset.
    ///
    /// Deliberately **not** a tally. Red means on program everywhere else in
    /// the app, and a preset is not on a bus: what its rows report is which
    /// one the switcher and the layer editor are working within. So it is
    /// drawn as a checkmark, the macOS idiom for "this is the current one",
    /// and cannot be confused with a lamp.
    let isCurrent: Bool

    /// Creates a row.
    ///
    /// - Parameters:
    ///   - id: The subject's raw identifier.
    ///   - name: The user-facing name, drawn verbatim.
    ///   - tally: What the row's lamp reads, or nil for a row that does not
    ///     stage.
    ///   - isCurrent: Whether this row is its section's current one (default
    ///     no, which is every section but the presets).
    init(id: String, name: String, tally: MultiviewTile.Tally?, isCurrent: Bool = false) {
        self.id = id
        self.name = name
        self.tally = tally
        self.isCurrent = isCurrent
    }

    /// The rows for the active preset's **authored** shots, in switcher order.
    ///
    /// Automatic shots are left out (``ShotOrigin``): the app creates one
    /// whenever an input is staged that no shot shows alone, named after the
    /// device, and a section that means "the shots I made" would fill up with
    /// device names the operator never chose. They remain in the switcher,
    /// which is what keeps a clicked input reachable — this section is a
    /// curated list, not the complete one.
    ///
    /// **Red wins over green**, the tile rule one subject over: a shot that is
    /// both on program and staged reads `onAir`, because what viewers are
    /// seeing is the more urgent fact. That case is ordinary rather than
    /// exotic — the switcher takes a shot to program without clearing it from
    /// preview.
    ///
    /// - Parameters:
    ///   - shots: The active preset's shots, in switcher order.
    ///   - onProgram: The id of the shot currently on program, or nil.
    ///   - onPreview: The id of the shot staged on preview, or nil.
    /// - Returns: One row per authored shot, in the given order.
    static func rows(shots: [Shot], onProgram: ShotID?, onPreview: ShotID?) -> [SidebarRow] {
        shots.filter { $0.origin == .authored }.map { shot in
            let tally: MultiviewTile.Tally =
                if shot.id == onProgram {
                    .onAir
                } else if shot.id == onPreview {
                    .staged
                } else {
                    .idle
                }
            return SidebarRow(id: shot.id.rawValue, name: shot.name, tally: tally)
        }
    }

    /// The rows for one **kind** of discovered input, each carrying that
    /// input's tally — the sidebar's staging device section.
    ///
    /// The tally comes from ``MultiviewTile/tiles(inputs:onProgram:onPreview:)``
    /// rather than being recomputed, so the sidebar is a third surface reading
    /// one tally rule instead of a second copy of it.
    ///
    /// - Parameters:
    ///   - choices: The discovered inputs to draw from, in row order.
    ///   - kind: The device kind this section lists.
    ///   - onProgram: The inputs contributing to program.
    ///   - onPreview: The inputs contributing to the staged shot.
    /// - Returns: One row per matching input, in the given order.
    static func rows(
        from choices: [EngineModel.InputChoice],
        ofKind kind: InputKind,
        onProgram: Set<InputID>,
        onPreview: Set<InputID>
    ) -> [SidebarRow] {
        MultiviewTile.tiles(
            inputs: choices.filter { $0.kind == kind },
            onProgram: onProgram,
            onPreview: onPreview
        )
        .map { SidebarRow(id: $0.id.rawValue, name: $0.name, tally: $0.tally) }
    }

    /// The rows for one **kind** of discovered input, without a tally — the
    /// sidebar's inert sections.
    ///
    /// Filtering on ``InputKind`` rather than on `InputMedia` is what splits
    /// the audio sections by provenance, the same question the camera picker
    /// asks: `.microphone` answers "what hardware is attached", so a generator
    /// — which synthesizes its content and is attached to no device at all —
    /// cannot appear among the microphones; `.generator` over the same
    /// media-role list answers the complementary "what can this Mac synthesize
    /// a sound from", which is where the 440 Hz tone belongs.
    ///
    /// The order is the caller's: the model hands over its device lists
    /// already sorted by name, so a row does not jump when another device
    /// connects.
    ///
    /// - Parameters:
    ///   - choices: The discovered inputs to draw from, in row order.
    ///   - kind: The device kind this section lists.
    /// - Returns: One row per matching input, in the given order.
    static func rows(from choices: [EngineModel.InputChoice], ofKind kind: InputKind) -> [SidebarRow] {
        choices
            .filter { $0.kind == kind }
            .map { SidebarRow(id: $0.id.rawValue, name: $0.name, tally: nil) }
    }

    /// The rows for the project's **presets**, in switcher order, with the
    /// active one marked.
    ///
    /// Every preset appears, unlike the shot section: there is no automatic
    /// preset — a preset exists only because the operator added, duplicated,
    /// or was given one in a new project's seed — so there is nothing to
    /// filter out and no `origin` question to ask.
    ///
    /// - Parameters:
    ///   - presets: The project's presets, in switcher order.
    ///   - active: The id of the active preset, or nil.
    /// - Returns: One row per preset, in the given order.
    static func rows(presets: [Preset], active: PresetID?) -> [SidebarRow] {
        presets.map { preset in
            SidebarRow(id: preset.id.rawValue, name: preset.name, tally: nil, isCurrent: preset.id == active)
        }
    }

    /// The rows for the project's **destinations**, in panel order.
    ///
    /// Named by ``DestinationEdit/displayName``, so the sidebar and the
    /// streaming panel label a destination identically — the operator's name
    /// when they gave one, the URL as typed when they did not, and the
    /// panel's placeholder for a row that is still empty. A URL is not a
    /// secret (the stream key is, and is never part of one), so drawing it is
    /// safe.
    ///
    /// No tally and no current mark: a destination is not on a bus, and its
    /// live state — live, reconnecting, rejected, lost — has four values a
    /// two-colour lamp would have to flatten into something misleading. The
    /// streaming panel owns that reporting.
    ///
    /// - Parameter destinations: The project's destinations, in panel order.
    /// - Returns: One row per destination, in the given order.
    static func rows(destinations: [DestinationEdit]) -> [SidebarRow] {
        destinations.map { SidebarRow(id: $0.id.rawValue, name: $0.displayName, tally: nil) }
    }

    /// The rows for the system's audio **output** devices.
    ///
    /// Sorted here, unlike every other section: the monitor reports its
    /// devices in Core Audio's own device-list order, which is neither
    /// alphabetical nor stable across a connect or disconnect, and a sidebar
    /// that reshuffles when headphones are plugged in is one the operator has
    /// to re-read.
    ///
    /// - Parameter devices: The output devices the monitor discovered.
    /// - Returns: One row per device, in a stable name order.
    static func rows(from devices: [AudioMonitorDevice]) -> [SidebarRow] {
        devices
            .map { SidebarRow(id: $0.uid, name: $0.name, tally: nil) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
