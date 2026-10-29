//
//  UVCRequest.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The request codes of the UVC class-specific control requests (UVC 1.5,
/// table A-8): one set request and the get requests a control answers.
public enum UVCRequestCode: UInt8, Sendable, CaseIterable {
    /// `SET_CUR`: writes a control's current setting.
    case setCurrent = 0x01

    /// `GET_CUR`: reads a control's current setting.
    case getCurrent = 0x81

    /// `GET_MIN`: reads the smallest setting a control accepts.
    case getMinimum = 0x82

    /// `GET_MAX`: reads the largest setting a control accepts.
    case getMaximum = 0x83

    /// `GET_RES`: reads a control's step size — or, for a bitmap control
    /// such as the auto exposure mode, the bits it supports.
    case getResolution = 0x84

    /// `GET_LEN`: reads the length of a control's payload.
    case getLength = 0x85

    /// `GET_INFO`: reads a control's capabilities (``UVCControlCapabilities``).
    case getInfo = 0x86

    /// `GET_DEF`: reads a control's factory default setting.
    case getDefault = 0x87

    /// Whether the request reads from the device (every code but
    /// ``setCurrent``).
    public var isGet: Bool { rawValue & 0x80 != 0 }
}

/// One class-specific control request addressed to an entity — a camera
/// terminal or processing unit — on a camera's VideoControl interface: the
/// unit of every exchange a ``UVCConnection`` carries.
public struct UVCRequest: Sendable, Hashable {
    /// The request code.
    public let code: UVCRequestCode

    /// The control selector within the entity (e.g. `0x02` for a processing
    /// unit's brightness).
    public let selector: UInt8

    /// The entity's ID from the configuration descriptor (`bTerminalID` or
    /// `bUnitID`).
    public let entityID: UInt8

    /// The VideoControl interface's number (`bInterfaceNumber`).
    public let interfaceNumber: UInt8

    /// The length of the data phase in bytes: what a get request reads, or
    /// what a set request writes.
    public let length: UInt16

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - code: The request code.
    ///   - selector: The control selector.
    ///   - entityID: The entity's ID.
    ///   - interfaceNumber: The VideoControl interface's number.
    ///   - length: The length of the data phase in bytes.
    public init(code: UVCRequestCode, selector: UInt8, entityID: UInt8, interfaceNumber: UInt8, length: UInt16) {
        self.code = code
        self.selector = selector
        self.entityID = entityID
        self.interfaceNumber = interfaceNumber
        self.length = length
    }

    /// The setup packet's `bmRequestType`: class-specific, addressed to an
    /// interface, device-to-host for a get (`0xA1`) and host-to-device for a
    /// set (`0x21`).
    public var requestType: UInt8 { code.isGet ? 0xA1 : 0x21 }

    /// The setup packet's `wValue`: the control selector in the high byte.
    public var value: UInt16 { UInt16(selector) << 8 }

    /// The setup packet's `wIndex`: the entity ID in the high byte and the
    /// interface number in the low byte.
    public var index: UInt16 { UInt16(entityID) << 8 | UInt16(interfaceNumber) }
}
