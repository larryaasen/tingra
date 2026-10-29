//
//  UVCControlCapabilities.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// What a control reports about itself in answer to `GET_INFO` (UVC 1.5,
/// table 4-3).
public struct UVCControlCapabilities: OptionSet, Sendable, Hashable {
    /// The bitmap as the camera reported it.
    public let rawValue: UInt8

    /// Creates capabilities from a `GET_INFO` bitmap.
    ///
    /// - Parameter rawValue: The bitmap.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The control answers `GET_CUR`.
    public static let supportsGet = UVCControlCapabilities(rawValue: 1 << 0)

    /// The control accepts `SET_CUR`.
    public static let supportsSet = UVCControlCapabilities(rawValue: 1 << 1)

    /// The control is disabled right now because an automatic mode owns it
    /// (a white balance temperature while auto white balance is on).
    public static let disabledByAutomaticMode = UVCControlCapabilities(rawValue: 1 << 2)

    /// The camera may change the control's value on its own.
    public static let autoUpdate = UVCControlCapabilities(rawValue: 1 << 3)

    /// A set completes asynchronously and is confirmed on the status
    /// interrupt endpoint.
    public static let asynchronous = UVCControlCapabilities(rawValue: 1 << 4)
}
