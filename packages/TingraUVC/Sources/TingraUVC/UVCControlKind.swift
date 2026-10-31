//
//  UVCControlKind.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The standard UVC controls the package knows — the camera terminal and
/// processing unit controls a webcam advertises (UVC 1.5, sections 4.2.2.1
/// and 4.2.2.3) — each with where it lives, its selector, the bit that
/// advertises it in the entity's `bmControls`, and its wire layout.
///
/// The declaration order is the order ``UVCCamera/controls`` lists them in.
/// Relative controls, the analog video controls, and vendor extension units
/// are not in the catalog (docs/UVC.md, "Not in this slice").
public enum UVCControlKind: String, Sendable, CaseIterable {
    /// The auto exposure mode, a bitmap of one ``UVCAutoExposureMode``.
    case autoExposureMode

    /// Whether the camera may vary the frame rate to expose (`0` constant,
    /// `1` variable).
    case autoExposurePriority

    /// The exposure time, in units of 100 µs.
    case exposureTime

    /// The gain applied to the sensor signal.
    case gain

    /// The backlight compensation level.
    case backlightCompensation

    /// The brightness.
    case brightness

    /// The contrast.
    case contrast

    /// The saturation.
    case saturation

    /// The sharpness.
    case sharpness

    /// The hue, in hundredths of a degree.
    case hue

    /// The gamma, in hundredths.
    case gamma

    /// Whether the camera sets the white balance temperature itself (`0`
    /// off, `1` on).
    case whiteBalanceTemperatureAuto

    /// The white balance temperature, in kelvin.
    case whiteBalanceTemperature

    /// The power line frequency the camera compensates flicker for (`0`
    /// disabled, `1` 50 Hz, `2` 60 Hz, `3` auto).
    case powerLineFrequency

    /// Whether the camera focuses itself (`0` off, `1` on).
    case focusAuto

    /// The focus distance, in the camera's own units.
    case focus

    /// The zoom, in the camera's own units.
    case zoom

    /// The pan, in arc seconds; shares one control with ``tilt`` on the
    /// wire.
    case pan

    /// The tilt, in arc seconds; shares one control with ``pan`` on the
    /// wire.
    case tilt

    /// The entity a control lives in.
    public enum Entity: Sendable, Equatable {
        /// The camera terminal: the sensor and lens (exposure, focus, zoom,
        /// pan, tilt).
        case cameraTerminal

        /// The processing unit: the image pipeline after the sensor
        /// (brightness, contrast, white balance, ...).
        case processingUnit
    }

    /// What a control's value means, which decides how the camera
    /// describes it.
    public enum Style: Sendable, Equatable {
        /// A number within the range `GET_MIN`…`GET_MAX`, stepping by
        /// `GET_RES`.
        case range

        /// An on/off switch, `0` or `1`; the camera answers no range
        /// requests for it.
        case boolean

        /// A bitmap of options; `GET_RES` reports the supported bits and
        /// the value is exactly one of them.
        case bitmap

        /// A numbered option from the specification's list, starting at
        /// `0`. `GET_MAX` says how far up the list the camera goes, but
        /// `GET_MIN` can understate it: the Razer Kiyo Pro reports `1` for
        /// its power line frequency and takes `0` (docs/UVC.md), so the
        /// control's minimum is always `0`.
        case option
    }

    /// The entity the control lives in.
    public var entity: Entity {
        switch self {
        case .autoExposureMode, .autoExposurePriority, .exposureTime, .focusAuto, .focus, .zoom, .pan, .tilt:
            .cameraTerminal
        case .gain, .backlightCompensation, .brightness, .contrast, .saturation, .sharpness, .hue, .gamma,
            .whiteBalanceTemperatureAuto, .whiteBalanceTemperature, .powerLineFrequency:
            .processingUnit
        }
    }

    /// What the control's value means.
    public var style: Style {
        switch self {
        case .autoExposureMode: .bitmap
        case .autoExposurePriority, .whiteBalanceTemperatureAuto, .focusAuto: .boolean
        case .powerLineFrequency: .option
        default: .range
        }
    }

    /// The control selector within its entity (UVC 1.5, tables A-12 and
    /// A-13).
    var selector: UInt8 {
        switch self {
        case .autoExposureMode: 0x02
        case .autoExposurePriority: 0x03
        case .exposureTime: 0x04
        case .focus: 0x06
        case .focusAuto: 0x08
        case .zoom: 0x0B
        case .pan, .tilt: 0x0D
        case .backlightCompensation: 0x01
        case .brightness: 0x02
        case .contrast: 0x03
        case .gain: 0x04
        case .powerLineFrequency: 0x05
        case .hue: 0x06
        case .saturation: 0x07
        case .sharpness: 0x08
        case .gamma: 0x09
        case .whiteBalanceTemperature: 0x0A
        case .whiteBalanceTemperatureAuto: 0x0B
        }
    }

    /// The bit in the entity's `bmControls` that advertises the control
    /// (UVC 1.5, tables 3-6 and 3-8), counted from bit 0 of the first byte.
    var controlBit: Int {
        switch self {
        case .autoExposureMode: 1
        case .autoExposurePriority: 2
        case .exposureTime: 3
        case .focus: 5
        case .zoom: 9
        case .pan, .tilt: 11
        case .focusAuto: 17
        case .brightness: 0
        case .contrast: 1
        case .hue: 2
        case .saturation: 3
        case .sharpness: 4
        case .gamma: 5
        case .whiteBalanceTemperature: 6
        case .backlightCompensation: 8
        case .gain: 9
        case .powerLineFrequency: 10
        case .whiteBalanceTemperatureAuto: 12
        }
    }

    /// The length of the control's whole payload on the wire, in bytes.
    var payloadLength: Int {
        switch self {
        case .autoExposureMode, .autoExposurePriority, .focusAuto, .whiteBalanceTemperatureAuto,
            .powerLineFrequency:
            1
        case .exposureTime: 4
        case .pan, .tilt: 8
        default: 2
        }
    }

    /// Where the control's own value starts within the payload — non-zero
    /// only for ``tilt``, the second half of the pan/tilt control.
    var fieldOffset: Int { self == .tilt ? 4 : 0 }

    /// The size of the control's own value within the payload, in bytes.
    var fieldSize: Int {
        switch self {
        case .pan, .tilt: 4
        default: payloadLength
        }
    }

    /// Whether the value is a two's-complement signed number.
    var isSigned: Bool {
        switch self {
        case .brightness, .hue, .pan, .tilt: true
        default: false
        }
    }

    /// Reads the control's value out of a payload — little-endian, sign
    /// extended for a signed control.
    ///
    /// - Parameter payload: The bytes a get request returned.
    /// - Returns: The value, or nil when the payload is too short to hold
    ///   the field.
    func decode(_ payload: [UInt8]) -> Int? {
        guard payload.count >= fieldOffset + fieldSize else { return nil }
        var raw: UInt64 = 0
        for byte in 0..<fieldSize {
            raw |= UInt64(payload[fieldOffset + byte]) << (8 * UInt64(byte))
        }
        guard isSigned else { return Int(raw) }
        let shift = UInt64(64 - 8 * fieldSize)
        return Int(Int64(bitPattern: raw << shift) >> Int64(shift))
    }

    /// Writes the control's value into a payload, leaving every other byte
    /// as it was — which is what lets ``pan`` and ``tilt`` each be set
    /// without disturbing the other.
    ///
    /// - Parameters:
    ///   - value: The value to write; truncated to the field's size.
    ///   - payload: The payload to write into, ``payloadLength`` bytes.
    func encode(_ value: Int, into payload: inout [UInt8]) {
        let raw = UInt64(bitPattern: Int64(value))
        for byte in 0..<fieldSize {
            payload[fieldOffset + byte] = UInt8(truncatingIfNeeded: raw >> (8 * UInt64(byte)))
        }
    }
}
