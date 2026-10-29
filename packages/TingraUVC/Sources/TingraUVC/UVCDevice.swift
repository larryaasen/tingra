//
//  UVCDevice.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import IOKit
import IOUSBHost

/// A connected UVC camera, as the I/O Registry lists it — a USB device with
/// a VideoControl interface. Finding one opens nothing; describe it with
/// ``UVCCamera/init(device:)``.
public struct UVCDevice: Sendable, Hashable, Identifiable {
    /// The device's I/O Registry entry ID, stable while it stays connected.
    public let id: UInt64

    /// The device's USB product string, e.g. "Razer Kiyo Pro".
    public let name: String

    /// The USB vendor ID (`idVendor`).
    public let vendorID: UInt16

    /// The USB product ID (`idProduct`).
    public let productID: UInt16

    /// The USB location ID: which port on which bus, unique among the
    /// connected devices.
    public let locationID: UInt32

    /// Creates a device description — what ``all()`` builds from the
    /// registry, public so an app can describe a device it found itself.
    ///
    /// - Parameters:
    ///   - id: The I/O Registry entry ID.
    ///   - name: The USB product string.
    ///   - vendorID: The USB vendor ID.
    ///   - productID: The USB product ID.
    ///   - locationID: The USB location ID.
    public init(id: UInt64, name: String, vendorID: UInt16, productID: UInt16, locationID: UInt32) {
        self.id = id
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
    }

    /// Lists the connected UVC cameras: every USB device with a
    /// VideoControl interface (class `0x0E`, subclass `0x01`).
    ///
    /// Reads the registry only — no device is opened. Throws
    /// ``UVCError/registryUnavailable(_:)`` when the registry cannot be
    /// searched.
    ///
    /// - Returns: The cameras, one per device, in registry order.
    public static func all() throws -> [UVCDevice] {
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil,
            productID: nil,
            bcdDevice: nil,
            interfaceNumber: nil,
            configurationValue: nil,
            interfaceClass: 0x0E,
            interfaceSubclass: 0x01,
            interfaceProtocol: nil,
            speed: nil,
            productIDArray: nil
        ).takeRetainedValue()
        var iterator: io_iterator_t = IO_OBJECT_NULL
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS else {
            throw UVCError.registryUnavailable(String(status))
        }
        defer { IOObjectRelease(iterator) }

        var devices: [UVCDevice] = []
        var seen: Set<UInt64> = []
        var interface = IOIteratorNext(iterator)
        while interface != IO_OBJECT_NULL {
            // A camera with several VideoControl interfaces (rare) is still
            // one device.
            if let device = device(owning: interface), seen.insert(device.id).inserted {
                devices.append(device)
            }
            IOObjectRelease(interface)
            interface = IOIteratorNext(iterator)
        }
        return devices
    }

    /// Finds the UVC camera behind an `AVCaptureDevice`, from its unique ID.
    ///
    /// AVFoundation names a USB camera `0x` followed by its USB location ID
    /// in hex, then its vendor and product IDs as four hex digits each —
    /// `0x211100015320e05` is location `0x02111000`, vendor `0x1532`,
    /// product `0x0E05` (observed 2026-10-26, docs/UVC.md). A unique ID of
    /// any other shape (a built-in or Continuity camera's UUID) is not a USB
    /// camera and matches nothing.
    ///
    /// Throws ``UVCError/registryUnavailable(_:)`` as ``all()`` does.
    ///
    /// - Parameter captureDeviceUniqueID: The capture device's `uniqueID`.
    /// - Returns: The matching camera, or nil.
    public static func matching(captureDeviceUniqueID: String) throws -> UVCDevice? {
        guard let address = CaptureDeviceAddress(uniqueID: captureDeviceUniqueID) else { return nil }
        return try all().first { address.matches($0) }
    }

    /// Reads the USB device that owns a VideoControl interface.
    ///
    /// - Parameter interface: The interface's registry entry.
    /// - Returns: The device, or nil when its parent is not a USB device or
    ///   lacks its IDs.
    private static func device(owning interface: io_service_t) -> UVCDevice? {
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(interface, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(parent) }
        guard IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 else { return nil }

        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(parent, &entryID) == KERN_SUCCESS,
            let vendorID = number(RegistryKey.vendorID, of: parent),
            let productID = number(RegistryKey.productID, of: parent),
            let locationID = number(RegistryKey.locationID, of: parent)
        else { return nil }
        let name =
            string(RegistryKey.productString, of: parent) ?? string(RegistryKey.productName, of: parent)
            ?? "USB Video Camera"
        return UVCDevice(
            id: entryID,
            name: name,
            vendorID: UInt16(truncatingIfNeeded: vendorID.intValue),
            productID: UInt16(truncatingIfNeeded: productID.intValue),
            locationID: UInt32(truncatingIfNeeded: locationID.int64Value)
        )
    }

    /// The I/O Registry property keys of a USB device. IOKit's own names
    /// for them (`kUSBVendorID`, ...) are C macros Swift cannot import.
    private enum RegistryKey {
        /// The USB vendor ID.
        static let vendorID = "idVendor"

        /// The USB product ID.
        static let productID = "idProduct"

        /// The USB location ID.
        static let locationID = "locationID"

        /// The product string the device reports.
        static let productString = "kUSBProductString"

        /// The product name the USB family records, the fallback when the
        /// device reports no product string.
        static let productName = "USB Product Name"
    }

    /// Reads a numeric registry property.
    ///
    /// - Parameters:
    ///   - key: The property key.
    ///   - entry: The registry entry.
    /// - Returns: The number, or nil when absent or not a number.
    private static func number(_ key: String, of entry: io_registry_entry_t) -> NSNumber? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
    }

    /// Reads a string registry property.
    ///
    /// - Parameters:
    ///   - key: The property key.
    ///   - entry: The registry entry.
    /// - Returns: The string, or nil when absent or not a string.
    private static func string(_ key: String, of entry: io_registry_entry_t) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

/// The USB address AVFoundation encodes in a USB camera's unique ID — the
/// bridge from a discovered capture device to its ``UVCDevice``.
struct CaptureDeviceAddress: Equatable {
    /// The USB location ID.
    let locationID: UInt32

    /// The USB vendor ID.
    let vendorID: UInt16

    /// The USB product ID.
    let productID: UInt16

    /// Parses a capture device's unique ID: `0x`, the location ID in hex
    /// without leading zeros, then the vendor and product IDs as four hex
    /// digits each.
    ///
    /// - Parameter uniqueID: The capture device's `uniqueID`.
    /// - Returns: The address, or nil for an ID of any other shape.
    init?(uniqueID: String) {
        guard uniqueID.hasPrefix("0x") else { return nil }
        let hex = uniqueID.dropFirst(2)
        // At least one location digit, at most eight, before the eight ID
        // digits.
        guard hex.count > 8, hex.count <= 16, hex.allSatisfy(\.isHexDigit),
            let locationID = UInt32(hex.dropLast(8), radix: 16),
            let vendorID = UInt16(hex.suffix(8).prefix(4), radix: 16),
            let productID = UInt16(hex.suffix(4), radix: 16)
        else { return nil }
        self.locationID = locationID
        self.vendorID = vendorID
        self.productID = productID
    }

    /// Whether a device is the one at this address.
    ///
    /// - Parameter device: A connected UVC device.
    /// - Returns: Whether its location, vendor, and product IDs all match.
    func matches(_ device: UVCDevice) -> Bool {
        device.locationID == locationID && device.vendorID == vendorID && device.productID == productID
    }
}
