//
//  StreamHealth.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition

/// Whether a stream that is on air is being delivered well — what the status
/// bar shows beside Live in place of the delivery figures
/// (``StatusBarView``).
///
/// **Why a verdict rather than the figures.** A bitrate and a frame rate are
/// only news when they are wrong, and an operator working the switcher does
/// not hold the targets in their head to compare against. So the bar stays
/// quiet while delivery is healthy and names the trouble when it is not; the
/// figures themselves stay in the streaming panel, and in the reading's
/// tooltip.
///
/// **A low bitrate is not trouble.** The compressor spends what the picture
/// needs: a still program is delivered correctly at a small fraction of the
/// target rate. The two things a reading can honestly say are wrong are
/// *nothing* leaving at all — the program's audio alone keeps the rate above
/// zero — and frames leaving slower than the program makes them.
///
/// **Trouble must last to be named.** The readings arrive once a second and
/// one of them dipping is ordinary, so a condition is reported only once it
/// has held for ``sustainedReadings`` in a row, and is dropped by the first
/// healthy reading.
///
/// A plain value fed by ``record(_:frameRate:)``, so the whole rule is
/// unit-testable with no session and no window — the ``StatusBarItem``
/// pattern.
struct StreamHealth: Equatable {
    /// What is wrong with a stream that is on air.
    enum Trouble: Equatable {
        /// Nothing is reaching the destination: the delivery rate has been
        /// zero.
        case stalled

        /// Some destinations are not being streamed to while others are —
        /// reconnecting, lost past the reconnect budget, or having refused
        /// the connection.
        case destinationsOffAir(count: Int, total: Int)

        /// Frames are leaving slower than the program makes them.
        case framesBehind(fps: Int, target: Int)
    }

    /// How many consecutive once-a-second readings a condition must hold
    /// for before it is reported.
    static let sustainedReadings = 3

    /// The latest reading's frame rate, or nil before the first.
    private(set) var fps: Int?

    /// The program's frame rate at the latest reading.
    private(set) var targetFrameRate = 0

    /// How many readings in a row delivered nothing.
    private(set) var stalledReadings = 0

    /// How many readings in a row ran behind the program's frame rate.
    private(set) var slowReadings = 0

    /// Whether a delivered frame rate is behind the program's: under nine
    /// tenths of it, which leaves room for the reading's own jitter around a
    /// rate that is being met.
    ///
    /// - Parameters:
    ///   - fps: The delivered frame rate.
    ///   - target: The program's frame rate.
    /// - Returns: Whether frames are falling behind.
    static func isBehind(fps: Int, target: Int) -> Bool {
        fps * 10 < target * 9
    }

    /// Takes one reading of the stream's delivery.
    ///
    /// - Parameters:
    ///   - stats: The reading.
    ///   - frameRate: The program's frame rate.
    mutating func record(_ stats: EngineModel.StreamStats, frameRate: Int) {
        fps = stats.fps
        targetFrameRate = frameRate
        stalledReadings = stats.bitrateKbps == 0 ? stalledReadings + 1 : 0
        slowReadings = Self.isBehind(fps: stats.fps, target: frameRate) ? slowReadings + 1 : 0
    }

    /// Forgets every reading — the stream ended, is stopping, or lost its
    /// connection, and the next readings describe a new run of delivery.
    mutating func reset() {
        self = StreamHealth()
    }

    /// What is wrong, or nil while delivery is healthy.
    ///
    /// The worst first: nothing being delivered outranks a destination that
    /// is off air while another carries the program, which outranks frames
    /// running behind.
    ///
    /// - Parameter destinationStates: Each destination's state from its own
    ///   events.
    /// - Returns: The trouble to show.
    func trouble(
        destinationStates: [ProjectDestinationID: EngineModel.DestinationState]
    ) -> Trouble? {
        if stalledReadings >= Self.sustainedReadings { return .stalled }
        let offAir = destinationStates.values.count { $0 != .live }
        if offAir > 0 { return .destinationsOffAir(count: offAir, total: destinationStates.count) }
        if slowReadings >= Self.sustainedReadings, let fps {
            return .framesBehind(fps: fps, target: targetFrameRate)
        }
        return nil
    }
}
