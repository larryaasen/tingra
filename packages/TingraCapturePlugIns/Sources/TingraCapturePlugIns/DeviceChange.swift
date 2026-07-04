//
//  DeviceChange.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

@preconcurrency import AVFoundation
import TingraEventBus
import TingraPlugInKit

/// One device connection or disconnection, as observed by the capture
/// plug-in — a normal event, never an error (CLAUDE.md, Data Flow Rules).
struct DeviceChange: Sendable, Equatable {
    /// Which way the device went.
    enum Kind: Sendable {
        /// The device appeared.
        case connected

        /// The device went away.
        case disconnected
    }

    /// Whether the device connected or disconnected.
    let kind: Kind

    /// The device that changed.
    let device: CaptureDevice
}

/// Keeps the input registry current as devices come and go, and reports
/// each change as a `device.connected` / `device.disconnected` event on
/// the bus — the events `stream` sessions and `devices --watch` both
/// consume (CLI.md). Event driven end to end: the production stream is
/// AVFoundation's connect/disconnect notifications, never polling
/// (CLAUDE.md, General Guidelines).
struct DeviceEventReporter: Sendable {
    /// The changes to report; injected so tests script the timeline.
    private let changes: AsyncStream<DeviceChange>

    /// Builds the input for a newly connected device (the plug-in's
    /// camera/microphone factory).
    private let makeInput: @Sendable (CaptureDevice) -> any Input

    /// Creates a reporter over a change stream and an input factory.
    init(changes: AsyncStream<DeviceChange>, makeInput: @escaping @Sendable (CaptureDevice) -> any Input) {
        self.changes = changes
        self.makeInput = makeInput
    }

    /// For each change until the stream finishes: updates the registry
    /// first (register on connect, unregister on disconnect), then emits
    /// the event — so a listener reacting to the event always sees the
    /// registry already reflecting it.
    func run(on eventBus: EventBus, inputs: any InputRegistering) async {
        for await change in changes {
            switch change.kind {
            case .connected:
                do {
                    try await inputs.register(makeInput(change.device))
                } catch {
                    // Already registered (a device both discovered at
                    // launch and announced by a notification): the
                    // connection is still a normal event, but leave a
                    // trace for debugging.
                    eventBus.trace(
                        "input.register.skipped",
                        domain: .capture,
                        params: [
                            "id": .string(change.device.uniqueID),
                            "reason": .string(String(describing: error)),
                        ]
                    )
                }
            case .disconnected:
                await inputs.unregister(InputID(rawValue: change.device.uniqueID))
            }
            eventBus.event(
                change.kind == .connected ? "device.connected" : "device.disconnected",
                domain: .capture,
                params: [
                    "id": .string(change.device.uniqueID),
                    "name": .string(change.device.name),
                    "kind": .string(change.device.kind.rawValue),
                ]
            )
        }
    }

    /// The production change stream: AVFoundation's device connect and
    /// disconnect notifications, mapped to framework-free changes. The
    /// stream stays open for the life of the process (or until the
    /// consumer cancels).
    static func liveChanges() -> AsyncStream<DeviceChange> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let connections = NotificationCenter.default.notifications(
                            named: AVCaptureDevice.wasConnectedNotification
                        )
                        for await notification in connections {
                            if let device = captureDevice(from: notification) {
                                continuation.yield(DeviceChange(kind: .connected, device: device))
                            }
                        }
                    }
                    group.addTask {
                        let disconnections = NotificationCenter.default.notifications(
                            named: AVCaptureDevice.wasDisconnectedNotification
                        )
                        for await notification in disconnections {
                            if let device = captureDevice(from: notification) {
                                continuation.yield(DeviceChange(kind: .disconnected, device: device))
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Extracts the framework-free device from a connect/disconnect
    /// notification, or nil if the notification carries something other
    /// than a camera or microphone.
    private static func captureDevice(from notification: Notification) -> CaptureDevice? {
        guard let device = notification.object as? AVCaptureDevice else { return nil }
        return CaptureDevice(
            uniqueID: device.uniqueID,
            name: device.localizedName,
            kind: device.hasMediaType(.video) ? .camera : .microphone
        )
    }
}
