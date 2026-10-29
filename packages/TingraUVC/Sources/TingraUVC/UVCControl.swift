//
//  UVCControl.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// One control a camera advertises, described once — its range, step,
/// default, and capabilities as the camera reported them — and read or set
/// on demand.
///
/// A control is obtained from a ``UVCCamera``, never built directly. Every
/// read and write is a blocking USB control transfer of a millisecond or
/// so, bounded by a one-second timeout: call them off the main actor. Each
/// plain call opens the camera for its own exchange; to read or write
/// several controls in one exchange, pass the connection from
/// ``UVCCamera/withConnection(_:)`` to the `on:` variants.
public struct UVCControl: Sendable {
    /// Which control this is.
    public let kind: UVCControlKind

    /// The smallest value the control accepts (`GET_MIN`). `0` for a
    /// boolean; the lowest supported bit for a bitmap.
    public let minimum: Int

    /// The largest value the control accepts (`GET_MAX`). `1` for a
    /// boolean; the highest supported bit for a bitmap.
    public let maximum: Int

    /// The control's step (`GET_RES`), at least `1`. For a bitmap control
    /// it is the bitmap of supported values instead, as the specification
    /// defines it — see ``supportedAutoExposureModes``.
    public let resolution: Int

    /// The factory default (`GET_DEF`), or ``minimum`` when the camera does
    /// not report one.
    public let defaultValue: Int

    /// What the control reported about itself when it was described
    /// (`GET_INFO`). Whether an automatic mode disables it changes at run
    /// time; read that live with ``isDisabledByAutomaticMode()``.
    public let capabilities: UVCControlCapabilities

    /// The ID of the entity the control lives in.
    let entityID: UInt8

    /// The VideoControl interface's number.
    let interfaceNumber: UInt8

    /// The transport each plain call opens its exchange through.
    let transport: any UVCTransport

    /// The values the control accepts, ``minimum`` through ``maximum``.
    public var range: ClosedRange<Int> { minimum...maximum }

    /// The auto exposure modes the camera supports, for the
    /// ``UVCControlKind/autoExposureMode`` control; nil for every other
    /// control.
    public var supportedAutoExposureModes: UVCAutoExposureMode? {
        guard kind == .autoExposureMode else { return nil }
        return UVCAutoExposureMode(rawValue: UInt8(truncatingIfNeeded: resolution))
    }

    /// Reads the control's current value in an exchange of its own.
    ///
    /// Throws a ``UVCError`` when the camera cannot be opened or rejects
    /// the request.
    ///
    /// - Returns: The current value.
    public func value() throws -> Int {
        try transport.withConnection { try value(on: $0) }
    }

    /// Reads the control's current value on an open connection.
    ///
    /// Throws ``UVCError/requestFailed(_:reason:)`` when the camera rejects
    /// the request and ``UVCError/shortResponse(_:received:)`` when it
    /// answers with too few bytes.
    ///
    /// - Parameter connection: A connection from
    ///   ``UVCCamera/withConnection(_:)``.
    /// - Returns: The current value.
    public func value(on connection: any UVCConnection) throws -> Int {
        let request = request(.getCurrent)
        let payload = try connection.send(request, data: [])
        guard let value = kind.decode(payload) else {
            throw UVCError.shortResponse(request, received: payload.count)
        }
        return value
    }

    /// Sets the control's current value in an exchange of its own.
    ///
    /// Throws as ``setValue(_:on:)`` does, and a ``UVCError`` when the
    /// camera cannot be opened.
    ///
    /// - Parameter value: The new value.
    public func setValue(_ value: Int) throws {
        try transport.withConnection { try setValue(value, on: $0) }
    }

    /// Sets the control's current value on an open connection.
    ///
    /// The value is checked before anything is sent: a range or boolean
    /// control throws ``UVCError/valueOutOfRange(_:value:range:)`` for a
    /// value outside ``range``, and the auto exposure mode throws
    /// ``UVCError/unsupportedAutoExposureMode(_:supported:)`` for anything
    /// but exactly one supported mode. A read-only control throws
    /// ``UVCError/controlNotSettable(_:)``. Pan and tilt share one control
    /// on the wire, so setting one reads the pair first and writes the other
    /// half back unchanged.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - connection: A connection from ``UVCCamera/withConnection(_:)``.
    public func setValue(_ value: Int, on connection: any UVCConnection) throws {
        guard capabilities.contains(.supportsSet) else {
            throw UVCError.controlNotSettable(kind)
        }
        try validate(value)

        var payload = [UInt8](repeating: 0, count: kind.payloadLength)
        if kind.fieldSize < kind.payloadLength {
            let current = request(.getCurrent)
            let read = try connection.send(current, data: [])
            guard read.count >= kind.payloadLength else {
                throw UVCError.shortResponse(current, received: read.count)
            }
            payload = Array(read.prefix(kind.payloadLength))
        }
        kind.encode(value, into: &payload)
        _ = try connection.send(request(.setCurrent), data: payload)
    }

    /// Whether an automatic mode disables the control right now — a white
    /// balance temperature while auto white balance is on — read live in an
    /// exchange of its own.
    ///
    /// - Returns: Whether the control is disabled by an automatic mode.
    public func isDisabledByAutomaticMode() throws -> Bool {
        try transport.withConnection { try isDisabledByAutomaticMode(on: $0) }
    }

    /// Whether an automatic mode disables the control right now, read live
    /// on an open connection.
    ///
    /// - Parameter connection: A connection from
    ///   ``UVCCamera/withConnection(_:)``.
    /// - Returns: Whether the control is disabled by an automatic mode.
    public func isDisabledByAutomaticMode(on connection: any UVCConnection) throws -> Bool {
        let request = request(.getInfo)
        guard let info = try connection.send(request, data: []).first else {
            throw UVCError.shortResponse(request, received: 0)
        }
        return UVCControlCapabilities(rawValue: info).contains(.disabledByAutomaticMode)
    }

    /// Checks a value against what the control accepts, by its style.
    ///
    /// - Parameter value: The value to check.
    private func validate(_ value: Int) throws {
        switch kind.style {
        case .range, .boolean:
            guard range.contains(value) else {
                throw UVCError.valueOutOfRange(kind, value: value, range: range)
            }
        case .bitmap:
            let supported = UVCAutoExposureMode(rawValue: UInt8(truncatingIfNeeded: resolution))
            let isSingleBit = value > 0 && value <= Int(UInt8.max) && value & (value - 1) == 0
            guard isSingleBit, supported.contains(UVCAutoExposureMode(rawValue: UInt8(value))) else {
                throw UVCError.unsupportedAutoExposureMode(value, supported: supported)
            }
        }
    }

    /// Builds a request for this control.
    ///
    /// - Parameter code: The request code.
    /// - Returns: The request, one byte long for `GET_INFO` and the
    ///   control's payload length otherwise.
    private func request(_ code: UVCRequestCode) -> UVCRequest {
        Self.request(code, for: kind, entityID: entityID, interfaceNumber: interfaceNumber)
    }

    /// Builds a request for a control kind on an entity.
    ///
    /// - Parameters:
    ///   - code: The request code.
    ///   - kind: The control kind.
    ///   - entityID: The entity's ID.
    ///   - interfaceNumber: The VideoControl interface's number.
    /// - Returns: The request.
    private static func request(
        _ code: UVCRequestCode,
        for kind: UVCControlKind,
        entityID: UInt8,
        interfaceNumber: UInt8
    ) -> UVCRequest {
        UVCRequest(
            code: code,
            selector: kind.selector,
            entityID: entityID,
            interfaceNumber: interfaceNumber,
            length: code == .getInfo ? 1 : UInt16(kind.payloadLength)
        )
    }

    /// Describes a control the topology says is advertised: reads its
    /// capabilities and the range, step, and default its style calls for.
    ///
    /// A camera that advertises a control but cannot describe it — its
    /// range requests stall, or a switch does not answer `GET_CUR` — gets
    /// no control rather than a made-up range (docs/UVC.md). A missing `GET_INFO` answer is read as "get and set",
    /// the specification's mandatory pair; a missing step as `1`; a missing
    /// default as the minimum.
    ///
    /// - Parameters:
    ///   - kind: The control kind.
    ///   - entityID: The ID of the entity it lives in.
    ///   - interfaceNumber: The VideoControl interface's number.
    ///   - connection: The open connection describing the camera.
    ///   - transport: The transport later plain calls open through.
    /// - Returns: The described control, or nil when it cannot be described.
    static func describe(
        _ kind: UVCControlKind,
        entityID: UInt8,
        interfaceNumber: UInt8,
        on connection: any UVCConnection,
        transport: any UVCTransport
    ) -> UVCControl? {
        func read(_ code: UVCRequestCode) -> Int? {
            let request = request(code, for: kind, entityID: entityID, interfaceNumber: interfaceNumber)
            guard let payload = try? connection.send(request, data: []) else { return nil }
            return kind.decode(payload)
        }

        let infoRequest = request(.getInfo, for: kind, entityID: entityID, interfaceNumber: interfaceNumber)
        let info = (try? connection.send(infoRequest, data: []))?.first
        let capabilities = info.map(UVCControlCapabilities.init) ?? [.supportsGet, .supportsSet]

        let minimum: Int
        let maximum: Int
        let resolution: Int
        let defaultValue: Int
        switch kind.style {
        case .range:
            guard let low = read(.getMinimum), let high = read(.getMaximum), low <= high else { return nil }
            minimum = low
            maximum = high
            resolution = read(.getResolution).flatMap { $0 > 0 ? $0 : nil } ?? 1
            defaultValue = read(.getDefault).map { min(high, max(low, $0)) } ?? low
        case .boolean:
            // A switch has no range to read, so its proof of life is an
            // answer to `GET_CUR`.
            guard read(.getCurrent) != nil else { return nil }
            minimum = 0
            maximum = 1
            resolution = 1
            defaultValue = read(.getDefault).map { $0 == 0 ? 0 : 1 } ?? 0
        case .bitmap:
            guard let supported = read(.getResolution), supported & 0xFF != 0 else { return nil }
            let bits = supported & 0xFF
            minimum = bits & -bits
            maximum = 1 << (Int.bitWidth - 1 - bits.leadingZeroBitCount)
            resolution = bits
            defaultValue = read(.getDefault) ?? minimum
        }

        return UVCControl(
            kind: kind,
            minimum: minimum,
            maximum: maximum,
            resolution: resolution,
            defaultValue: defaultValue,
            capabilities: capabilities,
            entityID: entityID,
            interfaceNumber: interfaceNumber,
            transport: transport
        )
    }
}
