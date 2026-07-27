//
//  AudioMonitor.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// One audio output device the operator can monitor through, as the
/// monitor's device list reports it.
///
/// Identity is the device's **UID** — the stable string Core Audio keys a
/// device by across reconnection and relaunch, the audio-output counterpart
/// of the microphone `InputID`'s `AVCaptureDevice.uniqueID` and the display
/// input's `CGDisplayCreateUUIDFromDisplayID` UUID. A selection persisted
/// under this uid survives the device being unplugged and returning.
public struct AudioMonitorDevice: Sendable, Equatable, Identifiable {
    /// The device's stable Core Audio UID — the persisted identity.
    public let uid: String

    /// The device's user-facing name.
    public let name: String

    /// The device's identity, for `Identifiable` (the ``uid``).
    public var id: String { uid }

    /// Creates a device.
    ///
    /// - Parameters:
    ///   - uid: The device's stable Core Audio UID.
    ///   - name: The device's user-facing name.
    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// What can go wrong opening a monitor device — recoverable every one of
/// them: monitoring is the operator's own path, so a device that will not
/// open leaves the program mix, the stream, and the recording completely
/// untouched (ARCHITECTURE.md, "The monitor path").
public enum AudioMonitorError: Error, Equatable, CustomStringConvertible {
    /// The selected device is not among the system's output devices — it was
    /// unplugged since the picker was drawn, or the persisted selection names
    /// a device this Mac does not have.
    case deviceNotFound(uid: String)

    /// The audio output path could not be started on the device, with the
    /// underlying reason.
    case couldNotStart(uid: String, reason: String)

    /// A developer-facing description naming the cause and the fix.
    public var description: String {
        switch self {
        case .deviceNotFound(let uid):
            return """
                The audio output device "\(uid)" is not available. It may have been \
                disconnected; choose another monitor device, or reconnect this one.
                """
        case .couldNotStart(let uid, let reason):
            return """
                The audio output device "\(uid)" could not start monitoring: \(reason). \
                Another application may have exclusive use of it; choose another \
                monitor device or quit that application.
                """
        }
    }
}

/// The monitor: the engine's audio **output** path — the program mix played
/// to an output device the operator chooses, so they hear what viewers hear
/// (GLOSSARY.md, "Monitor").
///
/// The seam exists for the same reason `ShotRenderer` does one service over:
/// playing audio out is an Apple-framework boundary inside an engine
/// library, so it sits behind a protocol that a test double can stand in for
/// — no audio hardware, no TCC, deterministic under the synthetic clock.
/// It deliberately lives here rather than in `TingraPlugInKit`: a monitor
/// output is the engine's own job, not a capability a third party
/// contributes, and the stability contract should not carry a speculative
/// surface (ARCHITECTURE.md, "The monitor path").
///
/// **The monitor is a sink, not a bus.** It consumes blocks the mixer has
/// already produced — the app tees them from its one `programAudio()` drain
/// — so nothing a monitor does can change the program mix, and nothing is
/// downstream of a monitor to reach. ``setLevel(_:)`` scales only what is
/// played out.
///
/// **The mix tick and the output device run on different clocks** and will
/// diverge over a long session, so an implementation buffers a bounded
/// backlog and drops past it rather than letting monitor latency grow
/// without bound — the audio mirror of the mixer's one-second intake cap.
/// ``play(_:)`` must never apply back-pressure to its caller: the drain
/// hands over a block and moves on.
///
/// Lifecycle and policy stay with the caller, matching the mixer's contract:
/// the monitor plays what it is handed, and *which* device, *whether* to
/// monitor at all, and what to do when the chosen device disappears are the
/// app's decisions — reported by the app on the event bus.
public protocol AudioMonitor: Sendable {
    /// The system's audio output devices, right now.
    ///
    /// - Returns: The available devices, in a stable order.
    func availableDevices() async -> [AudioMonitorDevice]

    /// A stream yielding the full device list whenever the system's output
    /// devices change — a device connected or disconnected. Event-driven:
    /// the caller never polls for device changes (CLAUDE.md). A new call
    /// replaces the previous consumer, finishing its stream — the
    /// one-consumer contract the engine's media streams use.
    ///
    /// - Returns: The device-list stream.
    func deviceUpdates() async -> AsyncStream<[AudioMonitorDevice]>

    /// Starts playing to a device. Idempotent for the same device; starting
    /// on a different device switches to it.
    ///
    /// - Parameters:
    ///   - device: The device to monitor through.
    ///   - format: The format the blocks handed to ``play(_:)`` carry.
    /// - Throws: ``AudioMonitorError`` when the device is gone or will not
    ///   open — recoverable, never fatal to the caller.
    func start(device: AudioMonitorDevice, format: MixFormat) async throws

    /// Stops playing and releases the device. Safe to call when not started.
    func stop() async

    /// Plays one mixed block. Does nothing when not started, and never
    /// blocks the caller: a block arriving while the backlog is full is
    /// dropped.
    ///
    /// - Parameter audio: The mixed program block.
    func play(_ audio: CapturedAudio) async

    /// Sets the monitor level — the operator's own listening volume, which
    /// scales **only** what is played out and never the program mix.
    /// Gesture-rate, like the mixer's `setLevel(_:forInput:)`: it reports no
    /// event.
    ///
    /// - Parameter level: The linear gain, `0` (silent) to `1` (unity).
    ///   Values outside that range are clamped.
    func setLevel(_ level: Double) async
}
