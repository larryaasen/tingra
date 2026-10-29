//
//  UVCAutoExposureMode.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The auto exposure modes (UVC 1.5, section 4.2.2.1.2): the value of the
/// ``UVCControlKind/autoExposureMode`` control is exactly one of them, and
/// its `GET_RES` answer is the set the camera supports.
public struct UVCAutoExposureMode: OptionSet, Sendable, Hashable {
    /// The bitmap.
    public let rawValue: UInt8

    /// Creates modes from a bitmap.
    ///
    /// - Parameter rawValue: The bitmap.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Exposure time and iris both set by hand.
    public static let manual = UVCAutoExposureMode(rawValue: 1 << 0)

    /// Exposure time and iris both set by the camera.
    public static let auto = UVCAutoExposureMode(rawValue: 1 << 1)

    /// Exposure time set by hand, iris by the camera.
    public static let shutterPriority = UVCAutoExposureMode(rawValue: 1 << 2)

    /// Exposure time set by the camera, iris by hand — the automatic mode
    /// most webcams, which have no iris, default to.
    public static let aperturePriority = UVCAutoExposureMode(rawValue: 1 << 3)

    /// The modes in which the camera chooses the exposure time itself.
    public static let automaticExposureTime: UVCAutoExposureMode = [.auto, .aperturePriority]
}
