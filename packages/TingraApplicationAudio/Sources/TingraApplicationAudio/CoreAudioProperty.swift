//
//  CoreAudioProperty.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio

/// Typed reads of Core Audio object properties — the handful of shapes this
/// library reads (a scalar, an object list, a string), each returning nil or
/// an empty list rather than a status, because every caller treats an
/// unreadable property as absent.
enum CoreAudioProperty {
    /// The global-scope, main-element address of a property.
    ///
    /// - Parameter selector: The property.
    /// - Returns: Its address.
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// A fixed-size property value.
    ///
    /// - Parameters:
    ///   - object: The object to read.
    ///   - selector: The property.
    ///   - initial: A value of the property's type to read into.
    /// - Returns: The value, or nil when the object does not report it.
    static func scalar<Value: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        initial: Value
    ) -> Value? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Value>.size)
        var value = initial
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// A property holding a list of object identifiers.
    ///
    /// - Parameters:
    ///   - object: The object to read.
    ///   - selector: The property.
    /// - Returns: The identifiers, and the status of the read — `noErr` for
    ///   an empty list that was read successfully.
    static func objectList(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> (objects: [AudioObjectID], status: OSStatus) {
        var address = address(selector)
        var size = UInt32(0)
        let sizeStatus = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard sizeStatus == noErr else { return ([], sizeStatus) }
        guard size > 0 else { return ([], noErr) }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects)
        guard status == noErr else { return ([], status) }
        return (Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)), noErr)
    }

    /// A property holding a `CFString`, which the HAL hands over retained.
    ///
    /// - Parameters:
    ///   - object: The object to read.
    ///   - selector: The property.
    /// - Returns: The string, or nil when the object does not report it.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
