//
//  MonitorOverlayMeters.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraAudio
import TingraPlugInKit

/// Where a monitor's audio levels come from for a monitor overlay that
/// draws them, such as VU Meters: the ``MeterRelay`` the mixer's meters
/// already read, and whose levels to take from it. The program monitor
/// meters the master, an input tile its input's strip, and the layer
/// monitor its layer's input's strip.
///
/// Read once per monitor draw, under the relay's lock, and never through
/// SwiftUI: the monitor's own display-rate refresh is the clock, so the
/// meters need no second one (PLUGINS.md, "Slice 3 as built").
struct MonitorOverlayMeters: Equatable {
    /// The relay holding the latest readings.
    let relay: MeterRelay

    /// Whose levels: the master's, or one strip's.
    let subject: PeakSubject

    /// The latest levels: the master's left and right, or the strip's one
    /// level. None before the strip has metered anything.
    ///
    /// - Returns: One level per channel.
    func levels() -> [MonitorOverlayContext.AudioLevel] {
        switch subject {
        case .master:
            let master = relay.master
            return [
                MonitorOverlayContext.AudioLevel(peak: master.left.peak, rms: master.left.rms),
                MonitorOverlayContext.AudioLevel(peak: master.right.peak, rms: master.right.rms),
            ]
        case .strip(let id):
            guard let reading = relay.latest[id] else { return [] }
            return [MonitorOverlayContext.AudioLevel(peak: reading.peak, rms: reading.rms)]
        }
    }

    /// Two sources are equal when they read the same relay for the same
    /// subject.
    static func == (lhs: MonitorOverlayMeters, rhs: MonitorOverlayMeters) -> Bool {
        lhs.relay === rhs.relay && lhs.subject == rhs.subject
    }
}
