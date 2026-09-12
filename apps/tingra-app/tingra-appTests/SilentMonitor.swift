//
//  SilentMonitor.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAudio
import TingraPlugInKit

/// An audio monitor that plays nothing, so a model under test never opens
/// an output device — shared by every suite that builds an ``EngineModel``.
struct SilentMonitor: AudioMonitor {
    /// No output devices.
    func availableDevices() async -> [AudioMonitorDevice] { [] }

    /// A device list that never changes.
    func deviceUpdates() async -> AsyncStream<[AudioMonitorDevice]> { AsyncStream { $0.finish() } }

    /// Starts nothing.
    func start(device: AudioMonitorDevice, format: MixFormat) async throws {}

    /// Stops nothing.
    func stop() async {}

    /// Plays nothing.
    func play(_ audio: CapturedAudio) async {}

    /// Ignores the level.
    func setLevel(_ level: Double) async {}
}
