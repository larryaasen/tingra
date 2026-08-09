//
//  StatusBarItem.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// What one reading on the window's status bar looks like: the lamp's state
/// and the symbol beside it (``StatusBarView``).
///
/// A plain value derived by ``streaming(_:)`` and ``recording(_:)``, pure
/// functions of the session status the engine already reports — the
/// ``MultiviewTile`` and ``MixerStrip`` pattern, so the whole rule that
/// decides which lamp lights is unit-testable with no window and no engine.
struct StatusBarItem: Equatable {
    /// How a session reads at a glance.
    ///
    /// Four states rather than a boolean, because a status bar's job is to be
    /// read without being studied: the operator has to be able to tell
    /// "nothing is happening" from "something is being set up" from "this is
    /// going out to viewers" from "this went wrong" in one look, and each of
    /// those wants a different color.
    enum Light: Equatable {
        /// Nothing is running — including a session that ran and ended
        /// cleanly, which is the same fact for a bar this size.
        case off

        /// Starting, finishing, or reconnecting: something is in flight and
        /// the operator should wait rather than act.
        case pending

        /// Live: the program is going out, or going to disk.
        case on

        /// The session ended on a failure, or could not start.
        case fault
    }

    /// The lamp's state.
    let light: Light

    /// The SF Symbol drawn before the label.
    let systemImage: String

    /// The status bar's reading for the stream (``EngineModel/StreamStatus``).
    ///
    /// **Idle and stopped read the same**, which is the one place this loses
    /// information on purpose: a bar that is always on screen answers "am I on
    /// air right now", and a stream that ended cleanly ten minutes ago is not
    /// a different answer from one that never started. The streaming panel
    /// still distinguishes the two.
    ///
    /// - Parameter status: The live stream status.
    /// - Returns: The bar's reading.
    static func streaming(_ status: EngineModel.StreamStatus) -> StatusBarItem {
        switch status {
        case .idle, .stopped:
            StatusBarItem(light: .off, systemImage: "antenna.radiowaves.left.and.right.slash")
        case .starting, .reconnecting:
            StatusBarItem(light: .pending, systemImage: "antenna.radiowaves.left.and.right")
        case .live:
            StatusBarItem(light: .on, systemImage: "antenna.radiowaves.left.and.right")
        case .error:
            StatusBarItem(light: .fault, systemImage: "exclamationmark.triangle.fill")
        }
    }

    /// The status bar's reading for the recording
    /// (``EngineModel/RecordingStatus``).
    ///
    /// **Finalizing is pending, not off**, and the distinction is the one that
    /// matters most on this bar: a file that is still being closed is not yet
    /// playable, so an operator who reads "not recording" and pulls the drive
    /// loses the take.
    ///
    /// - Parameter status: The live recording status.
    /// - Returns: The bar's reading.
    static func recording(_ status: EngineModel.RecordingStatus) -> StatusBarItem {
        switch status {
        case .idle:
            StatusBarItem(light: .off, systemImage: "record.circle")
        case .starting, .finalizing:
            StatusBarItem(light: .pending, systemImage: "record.circle")
        case .recording:
            StatusBarItem(light: .on, systemImage: "record.circle.fill")
        case .error:
            StatusBarItem(light: .fault, systemImage: "exclamationmark.triangle.fill")
        }
    }
}

extension StatusBarItem.Light {
    /// The reading's tint.
    ///
    /// **Red for on and red for fault**, matching the streaming and recording
    /// panels above: red is already what this app means by "on air", and a
    /// second red is not a collision because the symbol differs — a fault
    /// draws a warning triangle where a live session draws its own symbol.
    /// The idle reading is `.secondary` rather than a gray of its own, so it
    /// recedes the way a status bar's quiet text should.
    var tint: Color {
        switch self {
        case .off: .secondary
        case .pending: .orange
        case .on: .red
        case .fault: .red
        }
    }

    /// Whether the reading is emphasized — the two states an operator must
    /// not miss are the ones that carry weight.
    var isProminent: Bool {
        switch self {
        case .on, .fault: true
        case .off, .pending: false
        }
    }
}
