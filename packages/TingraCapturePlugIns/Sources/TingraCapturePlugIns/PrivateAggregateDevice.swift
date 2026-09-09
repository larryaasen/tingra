//
//  PrivateAggregateDevice.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio
import Foundation
import TingraEventBus

/// macOS's **private aggregate audio devices** — the
/// `CADefaultDeviceAggregate-<pid>-0` device Core Audio builds inside any
/// process the moment an `AVAudioEngine` runs against the default devices,
/// Tingra's own monitor included — and the rules that keep them out of the
/// input registry and out of a project document.
///
/// A private aggregate combines the default input and output devices, so it
/// carries input channels, and AVFoundation duly reports it as a microphone:
/// it fires `AVCaptureDevice.wasConnectedNotification` and appears in the
/// microphone discovery session (verified on the development Mac 2026-09-09,
/// with a live run loop — an earlier probe without one saw neither, which is
/// how the 2026-07-28 record came to say it could not reach the registry;
/// ARCHITECTURE.md, "Private aggregate audio devices in the monitor
/// picker"). Left in, every launch that starts the monitor authored a new
/// muted channel strip named after that launch's process id into the active
/// preset, which then outlived the device forever as a dormant strip.
///
/// Two rules, because a device is met in two states:
/// - ``isPrivate(uid:)`` for a **live** device, at discovery and on connect:
///   the authoritative test is the aggregate's own composition, whose
///   `private` flag macOS sets and a user's Audio MIDI Setup aggregate lacks
///   — so a user-authored aggregate, a legitimate thing to record from, stays
///   a microphone.
/// - ``matches(uid:)`` for a **dead** device, whose UID is all a document
///   keeps: the `CADefaultDeviceAggregate-` prefix macOS gives every one of
///   them. The composition is gone with the device, so the name is the only
///   evidence left, and it is what the mixer's merge drops authored channels
///   by.
///
/// The composition rule is written a second time in `TingraAudio`'s monitor
/// (`AVAudioEngineMonitor.isPrivateComposition`), which keeps the same
/// devices out of the monitor picker: the two packages are seam-only peers
/// that depend on the protocol package alone and cannot import each other,
/// so each carries — and unit-tests — its own copy.
public enum PrivateAggregateDevice {
    /// The UID prefix macOS gives its private default aggregates; the process
    /// id and an index follow it.
    public static let uidPrefix = "CADefaultDeviceAggregate-"

    /// Whether a device UID names a private default aggregate — the rule that
    /// works on the UID alone, which is all a document keeps of a device that
    /// no longer exists.
    ///
    /// - Parameter uid: The device's UID (an input identifier's raw value).
    /// - Returns: Whether the UID carries macOS's private-aggregate prefix.
    public static func matches(uid: String) -> Bool {
        uid.hasPrefix(uidPrefix)
    }

    /// Whether a live device is one of macOS's private aggregates, by its
    /// composition's `private` flag — the authoritative test at discovery and
    /// on connect. A UID the HAL can no longer resolve (the device vanished
    /// between the notification and the lookup) falls back to ``matches(uid:)``,
    /// so a private aggregate is never admitted for having died quickly.
    ///
    /// - Parameter uid: The device's UID.
    /// - Returns: Whether the device is a private aggregate.
    static func isPrivate(uid: String) -> Bool {
        guard let deviceID = deviceID(forUID: uid) else { return matches(uid: uid) }
        return isPrivateAggregate(deviceID) || matches(uid: uid)
    }

    /// Reports a private aggregate the plug-in declined, as an
    /// `input.ignored` trace in the `capture` domain — so a strip that fails
    /// to appear is explained in the log, and so a change in macOS's naming
    /// or flagging would show up as ignores stopping rather than as strips
    /// quietly returning.
    ///
    /// - Parameters:
    ///   - device: The device declined.
    ///   - change: The notification that carried it, or nil at discovery.
    ///   - eventBus: The host's event bus.
    static func reportIgnored(_ device: CaptureDevice, change: DeviceChange.Kind? = nil, on eventBus: EventBus) {
        var params: [String: EventValue] = [
            "id": .string(device.uniqueID),
            "name": .string(device.name),
            "kind": .string(device.kind.rawValue),
            "reason": .string("privateAggregate"),
        ]
        if let change {
            params["change"] = .string(change == .connected ? "connected" : "disconnected")
        }
        eventBus.trace("input.ignored", domain: .capture, params: params)
    }

    /// Whether an aggregate device's composition marks it private.
    ///
    /// Split out from the HAL read so the rule itself is unit-testable
    /// without any audio hardware — which matters because it is the rule that
    /// must **not** catch a user's own aggregate: macOS's private aggregate
    /// carries `private = 1`, while an aggregate created the way Audio MIDI
    /// Setup creates one carries no `private` key at all, so absence means
    /// public. The flag is read as an `Int`, a `Bool`, or an `NSNumber` — a
    /// bridged `CFDictionary` value can arrive as any of the three, and
    /// reading only one would silently stop filtering.
    ///
    /// - Parameter composition: The device's
    ///   `kAudioAggregateDevicePropertyComposition` dictionary.
    /// - Returns: Whether the aggregate is one of macOS's private ones.
    static func isPrivateComposition(_ composition: [String: Any]) -> Bool {
        switch composition[kAudioAggregateDeviceIsPrivateKey as String] {
        case let flag as Int: return flag != 0
        case let flag as Bool: return flag
        case let flag as NSNumber: return flag.boolValue
        default: return false
        }
    }

    /// Whether a HAL device is a private aggregate: reads its composition and
    /// applies ``isPrivateComposition(_:)``. A device with no composition at
    /// all is not an aggregate — every real microphone takes this path.
    ///
    /// - Parameter deviceID: The device to test.
    /// - Returns: Whether the device is a private aggregate.
    private static func isPrivateAggregate(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFDictionary? = nil
        var dataSize = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let composition = value as? [String: Any] else { return false }
        return isPrivateComposition(composition)
    }

    /// The HAL device carrying `uid`, through Core Audio's own UID
    /// translation, or nil when no present device has it.
    ///
    /// - Parameter uid: The device UID to resolve.
    /// - Returns: The device's object id, or nil.
    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &dataSize,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
