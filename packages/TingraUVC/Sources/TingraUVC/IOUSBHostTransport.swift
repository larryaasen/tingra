//
//  IOUSBHostTransport.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import IOKit
import IOUSBHost

/// The production transport: reaches a camera through Apple's `IOUSBHost`,
/// opening its device object for one exchange and destroying it at the end.
///
/// The device is opened without seizing it, so a camera streaming in
/// another process — or held by the system's UVC driver extension — stays
/// untouched; control transfers on the default endpoint need no exclusive
/// access and no TCC authorization (docs/UVC.md, "What the probe measured").
struct IOUSBHostTransport: UVCTransport {
    /// The camera to reach.
    let device: UVCDevice

    /// Finds the device's registry entry, opens it, runs the body, and
    /// destroys the open object before returning.
    ///
    /// - Parameter body: The exchange to run.
    /// - Returns: What the body returns.
    func withConnection<Result>(_ body: (any UVCConnection) throws -> Result) throws -> Result {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(device.id))
        guard service != IO_OBJECT_NULL else {
            throw UVCError.deviceNotFound(name: device.name)
        }
        defer { IOObjectRelease(service) }

        let host: IOUSBHostDevice
        do {
            host = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw UVCError.openFailed(name: device.name, reason: Self.reason(for: error))
        }
        defer { host.destroy() }
        return try body(IOUSBHostConnection(device: host))
    }

    /// An `NSError`'s description with its code, which for `IOUSBHost`
    /// carries the `IOReturn` that says what actually happened (a stall, a
    /// timeout, an exclusive open).
    ///
    /// - Parameter error: The error `IOUSBHost` threw.
    /// - Returns: A one-line reason.
    static func reason(for error: any Error) -> String {
        let nsError = error as NSError
        let hex = String(UInt32(truncatingIfNeeded: nsError.code), radix: 16)
        return "\(nsError.localizedDescription) (IOReturn 0x\(hex))"
    }
}

/// One open `IOUSBHost` device, valid only inside
/// ``IOUSBHostTransport/withConnection(_:)``.
private struct IOUSBHostConnection: UVCConnection {
    /// How long a single control transfer may take before it is abandoned:
    /// generous for a request a camera answers in about a millisecond, short
    /// enough that a wedged camera cannot hang the caller.
    static let timeout: TimeInterval = 1

    /// The open device.
    let device: IOUSBHostDevice

    /// Copies the active configuration descriptor out of the device.
    ///
    /// - Returns: The descriptor's `wTotalLength` bytes.
    func configurationDescriptor() throws -> [UInt8] {
        guard let descriptor = device.configurationDescriptor else {
            throw UVCError.malformedDescriptor("the device reports no active configuration")
        }
        let total = Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))
        return [UInt8](UnsafeRawBufferPointer(start: descriptor, count: total))
    }

    /// Sends one class-specific request on the default control endpoint.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - data: The bytes a set request writes.
    /// - Returns: The bytes a get request read; empty for a set.
    func send(_ request: UVCRequest, data: [UInt8]) throws -> [UInt8] {
        let setup = IOUSBDeviceRequest(
            bmRequestType: request.requestType,
            bRequest: request.code.rawValue,
            wValue: request.value,
            wIndex: request.index,
            wLength: request.length
        )
        let buffer =
            request.code.isGet
            ? NSMutableData(length: Int(request.length)) ?? NSMutableData()
            : NSMutableData(bytes: data, length: data.count)
        var transferred = 0
        do {
            try device.__send(setup, data: buffer, bytesTransferred: &transferred, completionTimeout: Self.timeout)
        } catch {
            throw UVCError.requestFailed(request, reason: IOUSBHostTransport.reason(for: error))
        }
        guard request.code.isGet else { return [] }
        return [UInt8]((buffer as Data).prefix(transferred))
    }
}
