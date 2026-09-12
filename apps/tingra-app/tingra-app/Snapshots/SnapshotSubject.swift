//
//  SnapshotSubject.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import SwiftUI
import TingraPlugInKit

/// Which monitor a snapshot is taken from (ARCHITECTURE.md, "Snapshots").
/// Each case maps to the `MonitorFrameSource` that monitor draws, so what is
/// saved is what the monitor shows (``EngineModel/snapshotSource(for:)``).
nonisolated enum SnapshotSubject: Hashable, Sendable {
    /// The program monitor: the program frame itself, at the program
    /// format's size.
    case program

    /// The preview monitor: the staged shot's frame, at the program
    /// format's size.
    case preview

    /// A multiview tile: that input's native frame.
    case input(InputID)

    /// The layer monitor: the selected layer after its effect chain, at the
    /// layer's size in program pixels.
    case layer

    /// The subject's kind as the `snapshot.*` events name it — a stable
    /// scripting value, never localized.
    var kind: String {
        switch self {
        case .program: "program"
        case .preview: "preview"
        case .input: "input"
        case .layer: "layer"
        }
    }

    /// The input a tile's snapshot is of, or nil for the other monitors.
    var inputID: InputID? {
        guard case .input(let id) = self else { return nil }
        return id
    }
}

/// What the last snapshot request came to, shown as a badge on the monitor
/// it was taken from — never a sound and never a flash (ARCHITECTURE.md,
/// "Snapshots"): system audio can be an input on air, and a flash on the
/// program monitor reads as the program flashing.
struct SnapshotFeedback: Equatable, Identifiable {
    /// How the request ended.
    enum Outcome: Equatable {
        /// The file was written.
        ///
        /// - Parameter fileName: The file's name, without its folder.
        case saved(fileName: String)

        /// Nothing was written, for the given reason.
        ///
        /// - Parameter message: The cause, as the operator reads it.
        case notSaved(message: String)

        /// The monitor had no frame to save — preview cleared, or an input
        /// that has not delivered yet — so nothing was written.
        case noPicture
    }

    /// Distinguishes one request's badge from the next, so a second
    /// snapshot restarts the badge rather than being absorbed by the first.
    let id = UUID()

    /// The monitor the snapshot was taken from — the one that wears the
    /// badge.
    let subject: SnapshotSubject

    /// How the request ended.
    let outcome: Outcome

    /// How long the badge stays up: about two seconds, a little longer for a
    /// failure, so the operator has time to hover it for the cause.
    var displayDuration: Duration {
        switch outcome {
        case .saved, .noPicture: .seconds(2)
        case .notSaved: .seconds(5)
        }
    }

    /// The badge's words.
    var title: Text {
        switch outcome {
        case .saved:
            Text("Snapshot Saved", comment: "Badge on a monitor after its picture was saved as an image file")
        case .notSaved:
            Text("Snapshot Not Saved", comment: "Badge on a monitor when its picture could not be saved")
        case .noPicture:
            Text(
                "No Picture to Save",
                comment: "Badge on a monitor asked for a snapshot while it shows no picture")
        }
    }

    /// The badge's tooltip: the file's name, or the cause of a failure.
    var help: Text {
        switch outcome {
        case .saved(let fileName):
            Text(verbatim: fileName)
        case .notSaved(let message):
            Text(verbatim: message)
        case .noPicture:
            Text(
                "The monitor was not showing a picture, so nothing was saved.",
                comment: "Tooltip on the No Picture to Save badge")
        }
    }

    /// The badge's tint: quiet for a save, orange when nothing was written.
    var tint: Color {
        switch outcome {
        case .saved: .gray
        case .notSaved, .noPicture: .orange
        }
    }
}
