//
//  UVCTransport.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The seam every byte to and from a camera crosses: a way to open one
/// connection to the device for the length of an exchange.
///
/// The production transport opens the camera through Apple's `IOUSBHost`
/// (``UVCCamera/init(device:)`` builds it); a test or an app that wants to
/// drive the package without hardware conforms its own, scripting the
/// descriptor and the answers. A transport opens the device for one
/// exchange and closes it when the body returns, so a camera is never held
/// open between calls — another app can adjust it, and a camera that
/// disconnects leaves nothing behind (docs/UVC.md).
public protocol UVCTransport: Sendable {
    /// Opens a connection to the device, runs the body with it, and closes
    /// it again before returning, whether the body returns or throws.
    ///
    /// Throws ``UVCError/deviceNotFound(name:)`` when the device is gone and
    /// ``UVCError/openFailed(name:reason:)`` when it cannot be opened, and
    /// rethrows whatever the body throws.
    ///
    /// - Parameter body: The exchange to run against the open device.
    /// - Returns: What the body returns.
    func withConnection<Result>(_ body: (any UVCConnection) throws -> Result) throws -> Result
}

/// An open connection to a camera, valid only inside
/// ``UVCTransport/withConnection(_:)``.
public protocol UVCConnection {
    /// The device's active configuration descriptor, whole — the
    /// configuration header followed by every interface, endpoint, and
    /// class-specific descriptor, `wTotalLength` bytes in all.
    ///
    /// Throws ``UVCError/malformedDescriptor(_:)`` when the device reports
    /// none.
    func configurationDescriptor() throws -> [UInt8]

    /// Sends one control request on the device's default control endpoint
    /// and waits for it to complete.
    ///
    /// Throws ``UVCError/requestFailed(_:reason:)`` when the device rejects
    /// the request — the specification has a camera stall a request for a
    /// control it does not implement.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - data: The bytes to write for a set request; ignored for a get.
    /// - Returns: The bytes a get request read (possibly fewer than
    ///   ``UVCRequest/length``); empty for a set.
    func send(_ request: UVCRequest, data: [UInt8]) throws -> [UInt8]
}
