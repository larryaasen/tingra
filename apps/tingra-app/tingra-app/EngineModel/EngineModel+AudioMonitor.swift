//
//  EngineModel+AudioMonitor.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAudio
import TingraEventBus

/// The audio monitor: its output device, level, and mute.
extension EngineModel {
    /// Reads the current output devices and begins draining the monitor's
    /// device-update stream, then opens the persisted device if one is
    /// selected. Called once at boot.
    func startMonitorDeviceUpdates() async {
        let updates = await monitor.deviceUpdates()
        monitorDevices = await monitor.availableDevices()
        refreshMonitorDeviceName()
        monitorDeviceTask = Task { [weak self] in
            for await devices in updates {
                await self?.monitorDevicesChanged(devices)
            }
        }
        await monitor.setLevel(Self.playbackLevel(level: monitorLevel, isMuted: isMonitorMuted))
        if let monitorDeviceUID {
            await openMonitor(deviceUID: monitorDeviceUID)
        }
    }

    /// Applies a device-list change from Core Audio: the picker refreshes,
    /// and if the device being monitored through has gone away, monitoring
    /// stops while **keeping the selection** — the device reappearing
    /// resumes it, the dormant-strip semantic one path over. A device coming
    /// and going is a normal event, never an error.
    ///
    /// - Parameter devices: The system's output devices now.
    private func monitorDevicesChanged(_ devices: [AudioMonitorDevice]) async {
        monitorDevices = devices
        refreshMonitorDeviceName()
        guard let uid = monitorDeviceUID else { return }
        let present = devices.contains { $0.uid == uid }
        if present, !isMonitoring {
            await openMonitor(deviceUID: uid)
        } else if !present, isMonitoring {
            await monitor.stop()
            isMonitoring = false
            eventBus.event(
                "monitor.stopped",
                domain: .audio,
                params: ["device": .string(uid), "reason": .string("deviceLost")]
            )
        }
    }

    /// Refreshes ``monitorDeviceName`` from the current device list, so the
    /// picker's label for the selection tracks the device's real name.
    ///
    /// Only ever *upgrades* the cached name: a device that has gone absent
    /// keeps the name it was last seen under, because that is exactly when
    /// the cache is needed. Nothing happens when no device is selected — the
    /// name is cleared by ``setMonitorDevice(_:)`` instead, alongside the
    /// selection it labels.
    private func refreshMonitorDeviceName() {
        guard let uid = monitorDeviceUID,
            let name = monitorDevices.first(where: { $0.uid == uid })?.name,
            name != monitorDeviceName
        else { return }
        monitorDeviceName = name
        monitorPreferences.deviceName = name
    }

    /// Selects the device the operator monitors through, or nil to stop
    /// monitoring. The choice persists in machine-local preferences, never
    /// in the project document.
    ///
    /// - Parameter uid: The device's stable UID, or nil for no monitoring.
    func setMonitorDevice(_ uid: String?) async {
        guard uid != monitorDeviceUID else { return }
        monitorDeviceUID = uid
        monitorPreferences.deviceUID = uid
        monitorDeviceName = uid.flatMap { chosen in monitorDevices.first { $0.uid == chosen }?.name }
        monitorPreferences.deviceName = monitorDeviceName
        guard let uid else {
            guard isMonitoring else { return }
            await monitor.stop()
            isMonitoring = false
            eventBus.event("monitor.stopped", domain: .audio, params: ["reason": .string("deselected")])
            return
        }
        await openMonitor(deviceUID: uid)
    }

    /// Opens the monitor on a device, reporting the outcome. A device that
    /// will not open is a recoverable error: the selection is kept (the
    /// operator may unblock it), and the program mix, the stream, and the
    /// recording are untouched — nothing downstream of the mix is involved.
    ///
    /// - Parameter deviceUID: The device's stable UID.
    private func openMonitor(deviceUID: String) async {
        guard let device = monitorDevices.first(where: { $0.uid == deviceUID }) else {
            // Not connected right now: keep the selection dormant and stay
            // quiet — the device-update stream resumes monitoring if it
            // returns.
            isMonitoring = false
            return
        }
        do {
            try await monitor.start(device: device, format: MixFormat())
            isMonitoring = true
            eventBus.event(
                "monitor.started",
                domain: .audio,
                params: ["device": .string(device.uid), "deviceName": .string(device.name)]
            )
        } catch {
            isMonitoring = false
            eventBus.error(
                "monitor.start",
                domain: .audio,
                params: [
                    "device": .string(device.uid),
                    "error": .string(String(describing: error)),
                ]
            )
        }
    }

    /// Sets the monitor level — the operator's listening volume. Gesture-rate
    /// like the strip faders, so it reports no event (the `setLevel` rule);
    /// the slider's drag-end `tap` carries the observability. It scales only
    /// what the monitor plays: the program mix, the stream, and the
    /// recording are provably unaffected.
    ///
    /// - Parameter level: The linear gain, `0`...`1`.
    func setMonitorLevel(_ level: Double) async {
        monitorLevel = level
        monitorPreferences.level = level
        await monitor.setLevel(Self.playbackLevel(level: level, isMuted: isMonitorMuted))
    }

    /// Mutes or unmutes the monitor — the control room cut. The device and
    /// the level are kept; the monitor's playback gain goes to silence and
    /// back, instantly and with no device restart, so a cut during a break
    /// comes back to the same setup with one click. Discrete like a strip's
    /// mute and, like it, carried by the toggle's own `tap`; it changes
    /// nothing the program, the stream, or the recording receive.
    ///
    /// - Parameter isMuted: Whether the monitor is muted.
    func setMonitorMuted(_ isMuted: Bool) async {
        isMonitorMuted = isMuted
        monitorPreferences.isMuted = isMuted
        await monitor.setLevel(Self.playbackLevel(level: monitorLevel, isMuted: isMuted))
    }

    /// The gain the monitor actually plays at: the operator's level, or
    /// silence while the monitor is muted. The one place the two combine,
    /// so a level set while muted stays silent and an unmute restores
    /// exactly the level shown.
    ///
    /// - Parameters:
    ///   - level: The operator's monitor level, `0`...`1`.
    ///   - isMuted: Whether the monitor is muted.
    /// - Returns: The playback gain.
    nonisolated static func playbackLevel(level: Double, isMuted: Bool) -> Double {
        isMuted ? 0 : level
    }
}
