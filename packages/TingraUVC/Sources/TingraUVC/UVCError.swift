//
//  UVCError.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// Everything that can go wrong talking to a UVC camera. Each case's
/// description names the cause and the fix; nothing in the package traps.
public enum UVCError: Error, Equatable, Sendable {
    /// The I/O Registry could not be searched for USB video devices; the
    /// string is the IOKit status.
    case registryUnavailable(String)

    /// The camera is no longer in the I/O Registry — it was unplugged after
    /// it was found.
    case deviceNotFound(name: String)

    /// The camera is present but could not be opened for control requests.
    case openFailed(name: String, reason: String)

    /// The camera's configuration has no VideoControl interface, so it is
    /// not a UVC camera.
    case noVideoControlInterface(name: String)

    /// The configuration descriptor is malformed; the string says where.
    case malformedDescriptor(String)

    /// The camera rejected a control request (a camera stalls a request for
    /// a control it does not implement).
    case requestFailed(UVCRequest, reason: String)

    /// A get request returned fewer bytes than the control's value needs.
    case shortResponse(UVCRequest, received: Int)

    /// The control does not accept `SET_CUR`.
    case controlNotSettable(UVCControlKind)

    /// The value is outside the range the camera reported for the control.
    case valueOutOfRange(UVCControlKind, value: Int, range: ClosedRange<Int>)

    /// The auto exposure mode is not exactly one of the modes the camera
    /// supports.
    case unsupportedAutoExposureMode(Int, supported: UVCAutoExposureMode)
}

extension UVCError: CustomStringConvertible {
    /// A developer-facing explanation of the error and its fix.
    public var description: String {
        switch self {
        case .registryUnavailable(let status):
            return """
                The I/O Registry could not be searched for USB video devices (IOKit status \(status)). \
                This is a system condition, not a camera problem; try again, and restart the Mac if it persists.
                """
        case .deviceNotFound(let name):
            return """
                The camera '\(name)' is no longer connected. Reconnect it, then list the cameras again with \
                `UVCDevice.all()`.
                """
        case .openFailed(let name, let reason):
            return """
                The camera '\(name)' could not be opened for control requests: \(reason). Another process may \
                hold the device exclusively; quit any other camera utility and try again.
                """
        case .noVideoControlInterface(let name):
            return """
                The device '\(name)' has no USB Video Class VideoControl interface, so its controls cannot be \
                reached through UVC. Built-in and Continuity cameras are not UVC devices.
                """
        case .malformedDescriptor(let detail):
            return """
                The camera's configuration descriptor is malformed (\(detail)), so its controls cannot be \
                found. Reconnect the camera; if it persists, its firmware reports descriptors this package \
                cannot read.
                """
        case .requestFailed(let request, let reason):
            return """
                The camera rejected \(Self.name(of: request)) for selector 0x\(String(request.selector, radix: 16)) \
                on entity \(request.entityID): \(reason). A camera stalls a request for a control it does not \
                implement; use only the controls `UVCCamera.controls` lists.
                """
        case .shortResponse(let request, let received):
            return """
                The camera answered \(Self.name(of: request)) for selector 0x\(String(request.selector, radix: 16)) \
                on entity \(request.entityID) with \(received) bytes, fewer than the \(request.length) the control \
                needs, so the value cannot be read.
                """
        case .controlNotSettable(let kind):
            return """
                The camera reports its \(kind.rawValue) control as read-only, so it cannot be set. Check \
                `UVCControl.capabilities` for `.supportsSet` before setting a control.
                """
        case .valueOutOfRange(let kind, let value, let range):
            return """
                \(value) is outside the range the camera reports for its \(kind.rawValue) control \
                (\(range.lowerBound)…\(range.upperBound)). Clamp the value to `UVCControl.range` before setting it.
                """
        case .unsupportedAutoExposureMode(let value, let supported):
            return """
                \(value) is not one of the auto exposure modes the camera supports (bitmap \
                0x\(String(supported.rawValue, radix: 16))). Set exactly one mode from \
                `UVCControl.supportedAutoExposureModes`.
                """
        }
    }

    /// The UVC name of a request's code, e.g. `GET_CUR`.
    ///
    /// - Parameter request: The request to name.
    /// - Returns: The specification's name for its code.
    private static func name(of request: UVCRequest) -> String {
        switch request.code {
        case .setCurrent: "SET_CUR"
        case .getCurrent: "GET_CUR"
        case .getMinimum: "GET_MIN"
        case .getMaximum: "GET_MAX"
        case .getResolution: "GET_RES"
        case .getLength: "GET_LEN"
        case .getInfo: "GET_INFO"
        case .getDefault: "GET_DEF"
        }
    }
}
