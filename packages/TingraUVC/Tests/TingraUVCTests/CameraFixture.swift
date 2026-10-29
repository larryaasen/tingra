//
//  CameraFixture.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraUVC

/// A synthetic camera modeled on the Razer Kiyo Pro probed 2026-10-26
/// (docs/UVC.md): its descriptor layout, entity IDs, advertised controls,
/// and the ranges and values it answered with.
enum CameraFixture {
    /// The camera terminal's ID.
    static let cameraTerminalID: UInt8 = 1

    /// The processing unit's ID.
    static let processingUnitID: UInt8 = 3

    /// The VideoControl interface's number.
    static let interfaceNumber: UInt8 = 0

    /// The camera terminal's `bmControls` as the Razer reports it: auto
    /// exposure mode and priority, exposure time, focus, zoom, pan/tilt,
    /// focus auto.
    static let cameraControls: [UInt8] = [0x2E, 0x0A, 0x02]

    /// The processing unit's `bmControls` as the Razer reports it:
    /// brightness, contrast, saturation, sharpness, white balance
    /// temperature, backlight compensation, gain, power line frequency,
    /// white balance temperature auto — no hue, no gamma.
    static let processingControls: [UInt8] = [0x5B, 0x17]

    /// A whole configuration descriptor: header, interface association,
    /// the VideoControl interface with its header, camera terminal,
    /// processing unit, an extension unit, an output terminal, and an
    /// interrupt endpoint, then a VideoStreaming interface.
    ///
    /// - Parameters:
    ///   - cameraControls: The camera terminal's `bmControls`.
    ///   - processingControls: The processing unit's `bmControls`.
    /// - Returns: The descriptor bytes, `wTotalLength` patched.
    static func descriptor(
        cameraControls: [UInt8] = cameraControls,
        processingControls: [UInt8] = processingControls
    ) -> [UInt8] {
        let cameraTerminal: [UInt8] =
            [UInt8(15 + cameraControls.count), 0x24, 0x02, cameraTerminalID, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0]
            + [UInt8(cameraControls.count)] + cameraControls
        let processingUnit: [UInt8] =
            [UInt8(10 + processingControls.count), 0x24, 0x05, processingUnitID, cameraTerminalID, 0, 0]
            + [UInt8(processingControls.count)] + processingControls + [0, 0]
        var bytes: [UInt8] = [9, 0x02, 0, 0, 2, 1, 0, 0x80, 250]
        bytes += [8, 0x0B, 0, 2, 0x0E, 0x03, 0, 0]
        bytes += [9, 0x04, interfaceNumber, 0, 1, 0x0E, 0x01, 0, 0]
        bytes += [13, 0x24, 0x01, 0x00, 0x01, 0, 0, 0, 0x6C, 0xDC, 0x02, 1, 1]
        bytes += cameraTerminal
        bytes += processingUnit
        bytes += [8, 0x24, 0x06, 2, 0, 0, 0, 0]
        bytes += [9, 0x24, 0x03, 4, 0x01, 0x01, 0, processingUnitID, 0]
        bytes += [7, 0x05, 0x83, 0x03, 16, 0, 8]
        bytes += [5, 0x25, 0x03, 16, 0]
        bytes += [9, 0x04, 1, 0, 0, 0x0E, 0x02, 0, 0]
        bytes[2] = UInt8(bytes.count & 0xFF)
        bytes[3] = UInt8(bytes.count >> 8)
        return bytes
    }

    /// A processing unit answer key.
    ///
    /// - Parameters:
    ///   - code: The request code.
    ///   - selector: The control selector.
    /// - Returns: The key.
    static func processing(_ code: UVCRequestCode, _ selector: UInt8) -> ScriptedTransport.Key {
        ScriptedTransport.Key(code: code, selector: selector, entityID: processingUnitID)
    }

    /// A camera terminal answer key.
    ///
    /// - Parameters:
    ///   - code: The request code.
    ///   - selector: The control selector.
    /// - Returns: The key.
    static func camera(_ code: UVCRequestCode, _ selector: UInt8) -> ScriptedTransport.Key {
        ScriptedTransport.Key(code: code, selector: selector, entityID: cameraTerminalID)
    }

    /// A value as `size` little-endian bytes.
    ///
    /// - Parameters:
    ///   - value: The value; negative values are two's complement.
    ///   - size: The byte count.
    /// - Returns: The bytes.
    static func bytes(_ value: Int, size: Int) -> [UInt8] {
        let raw = UInt64(bitPattern: Int64(value))
        return (0..<size).map { UInt8(truncatingIfNeeded: raw >> (8 * UInt64($0))) }
    }

    /// The answers a range control gives: info, minimum, maximum,
    /// resolution, default, and current.
    ///
    /// - Parameters:
    ///   - key: Builds the key for a code.
    ///   - size: The payload size.
    ///   - range: The minimum and maximum.
    ///   - defaultValue: The default.
    ///   - current: The current value.
    ///   - info: The `GET_INFO` byte (default: get and set).
    /// - Returns: The answers.
    static func rangeAnswers(
        _ key: (UVCRequestCode) -> ScriptedTransport.Key,
        size: Int,
        range: ClosedRange<Int>,
        defaultValue: Int,
        current: Int,
        info: UInt8 = 0x03
    ) -> [ScriptedTransport.Key: [UInt8]] {
        [
            key(.getInfo): [info],
            key(.getMinimum): bytes(range.lowerBound, size: size),
            key(.getMaximum): bytes(range.upperBound, size: size),
            key(.getResolution): bytes(1, size: size),
            key(.getDefault): bytes(defaultValue, size: size),
            key(.getCurrent): bytes(current, size: size),
        ]
    }

    /// The Razer's answers, as probed: brightness 0…255 at 87, contrast at
    /// 109, white balance temperature 2000…7500 K at 5101 with auto off,
    /// exposure time 3…2047 under aperture priority, zoom 100…400 at 134,
    /// and pan/tilt ±36000 arc seconds.
    static func razerAnswers() -> [ScriptedTransport.Key: [UInt8]] {
        var answers: [ScriptedTransport.Key: [UInt8]] = [:]
        answers.merge(rangeAnswers({ processing($0, 0x02) }, size: 2, range: 0...255, defaultValue: 128, current: 87)) {
            $1
        }
        answers.merge(rangeAnswers({ processing($0, 0x03) }, size: 2, range: 0...255, defaultValue: 128, current: 109))
        { $1 }
        answers.merge(
            rangeAnswers({ processing($0, 0x0A) }, size: 2, range: 2000...7500, defaultValue: 5000, current: 5101)
        ) { $1 }
        answers[processing(.getInfo, 0x0B)] = [0x03]
        answers[processing(.getDefault, 0x0B)] = [1]
        answers[processing(.getCurrent, 0x0B)] = [0]
        answers[camera(.getInfo, 0x02)] = [0x03]
        answers[camera(.getResolution, 0x02)] = [0x09]
        answers[camera(.getDefault, 0x02)] = [0x08]
        answers[camera(.getCurrent, 0x02)] = [0x08]
        answers.merge(rangeAnswers({ camera($0, 0x04) }, size: 4, range: 3...2047, defaultValue: 156, current: 963)) {
            $1
        }
        answers.merge(rangeAnswers({ camera($0, 0x0B) }, size: 2, range: 100...400, defaultValue: 100, current: 134)) {
            $1
        }
        answers[camera(.getInfo, 0x0D)] = [0x03]
        answers[camera(.getMinimum, 0x0D)] = bytes(-36000, size: 4) + bytes(-36000, size: 4)
        answers[camera(.getMaximum, 0x0D)] = bytes(36000, size: 4) + bytes(36000, size: 4)
        answers[camera(.getResolution, 0x0D)] = bytes(3600, size: 4) + bytes(3600, size: 4)
        answers[camera(.getDefault, 0x0D)] = bytes(0, size: 4) + bytes(0, size: 4)
        answers[camera(.getCurrent, 0x0D)] = bytes(7200, size: 4) + bytes(-3600, size: 4)
        return answers
    }

    /// A scripted Razer.
    ///
    /// - Returns: The transport and the camera described through it.
    static func razer() throws -> (transport: ScriptedTransport, camera: UVCCamera) {
        let transport = ScriptedTransport(descriptor: descriptor(), answers: razerAnswers())
        return (transport, try UVCCamera(name: "Razer Kiyo Pro", transport: transport))
    }
}
