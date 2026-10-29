//
//  VideoControlTopology.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// What a camera's configuration descriptor says about its controls: the
/// VideoControl interface's number, and the camera terminal and processing
/// unit with the controls each advertises.
///
/// Parsed once per ``UVCCamera``; a pure function of the descriptor bytes,
/// so it is unit tested with synthetic descriptors.
struct VideoControlTopology: Equatable {
    /// One entity on the VideoControl interface and the controls it
    /// advertises.
    struct Entity: Equatable {
        /// The entity's ID (`bTerminalID` or `bUnitID`).
        let id: UInt8

        /// The entity's `bmControls` bitmap, as many bytes as it declared.
        let controls: [UInt8]

        /// Whether the entity advertises the control at a bit.
        ///
        /// - Parameter bit: The bit, counted from bit 0 of the first byte.
        /// - Returns: Whether the bit is set; false past the bitmap's end.
        func advertises(bit: Int) -> Bool {
            let byte = bit / 8
            guard byte < controls.count else { return false }
            return controls[byte] & (1 << UInt8(bit % 8)) != 0
        }
    }

    /// The VideoControl interface's number, the low byte of every request's
    /// `wIndex`.
    let interfaceNumber: UInt8

    /// The camera terminal, or nil when the descriptor declares none.
    let cameraTerminal: Entity?

    /// The processing unit, or nil when the descriptor declares none.
    let processingUnit: Entity?

    /// The descriptor type of an interface descriptor.
    private static let interfaceDescriptorType: UInt8 = 0x04

    /// The descriptor type of a class-specific interface descriptor.
    private static let classSpecificInterfaceType: UInt8 = 0x24

    /// The video interface class (`CC_VIDEO`).
    private static let videoClass: UInt8 = 0x0E

    /// The VideoControl interface subclass (`SC_VIDEOCONTROL`).
    private static let videoControlSubclass: UInt8 = 0x01

    /// The VideoControl descriptor subtype of an input terminal.
    private static let inputTerminalSubtype: UInt8 = 0x02

    /// The VideoControl descriptor subtype of a processing unit.
    private static let processingUnitSubtype: UInt8 = 0x05

    /// The input terminal type of a camera sensor (`ITT_CAMERA`).
    private static let cameraTerminalType: UInt16 = 0x0201

    /// Parses a configuration descriptor, walking every descriptor in it
    /// and reading the first VideoControl interface's camera terminal and
    /// processing unit.
    ///
    /// Throws ``UVCError/malformedDescriptor(_:)`` when a descriptor's
    /// length is zero or runs past the end, or an entity's declared bitmap
    /// does not fit its descriptor, and ``UVCError/noVideoControlInterface(name:)``
    /// when there is no VideoControl interface at all.
    ///
    /// - Parameters:
    ///   - descriptor: The whole configuration descriptor.
    ///   - deviceName: The camera's name, for the error.
    init(configurationDescriptor descriptor: [UInt8], deviceName: String) throws {
        var interfaceNumber: UInt8?
        var inVideoControl = false
        var cameraTerminal: Entity?
        var processingUnit: Entity?

        var offset = 0
        while offset < descriptor.count {
            let length = Int(descriptor[offset])
            guard length >= 2, offset + length <= descriptor.count else {
                throw UVCError.malformedDescriptor(
                    "the descriptor at byte \(offset) declares length \(length) in a \(descriptor.count)-byte configuration"
                )
            }
            let bytes = Array(descriptor[offset..<offset + length])
            switch bytes[1] {
            case Self.interfaceDescriptorType where length >= 9:
                // Only the first VideoControl interface counts; a later
                // interface of any kind ends it.
                let isVideoControl = bytes[5] == Self.videoClass && bytes[6] == Self.videoControlSubclass
                inVideoControl = isVideoControl && interfaceNumber == nil
                if inVideoControl { interfaceNumber = bytes[2] }
            case Self.classSpecificInterfaceType where inVideoControl && length >= 3:
                if bytes[2] == Self.inputTerminalSubtype, cameraTerminal == nil {
                    cameraTerminal = try Self.cameraTerminal(in: bytes, at: offset)
                } else if bytes[2] == Self.processingUnitSubtype, processingUnit == nil {
                    processingUnit = try Self.processingUnit(in: bytes, at: offset)
                }
            default:
                break
            }
            offset += length
        }

        guard let interfaceNumber else {
            throw UVCError.noVideoControlInterface(name: deviceName)
        }
        self.interfaceNumber = interfaceNumber
        self.cameraTerminal = cameraTerminal
        self.processingUnit = processingUnit
    }

    /// The entity a control kind lives in, when the descriptor declares it.
    ///
    /// - Parameter kind: The control kind.
    /// - Returns: The camera terminal or processing unit, or nil.
    func entity(for kind: UVCControlKind) -> Entity? {
        switch kind.entity {
        case .cameraTerminal: cameraTerminal
        case .processingUnit: processingUnit
        }
    }

    /// Reads a camera terminal out of an input terminal descriptor, or nil
    /// when the terminal is some other kind of input.
    ///
    /// - Parameters:
    ///   - bytes: The input terminal descriptor.
    ///   - offset: Where it starts in the configuration, for the error.
    /// - Returns: The camera terminal, or nil.
    private static func cameraTerminal(in bytes: [UInt8], at offset: Int) throws -> Entity? {
        guard bytes.count >= 6 else { return nil }
        let terminalType = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        guard terminalType == cameraTerminalType else { return nil }
        // bmControls follows bControlSize at byte 14.
        return try entity(id: bytes[3], controlSizeAt: 14, in: bytes, at: offset)
    }

    /// Reads a processing unit descriptor.
    ///
    /// - Parameters:
    ///   - bytes: The processing unit descriptor.
    ///   - offset: Where it starts in the configuration, for the error.
    /// - Returns: The processing unit.
    private static func processingUnit(in bytes: [UInt8], at offset: Int) throws -> Entity {
        // bmControls follows bControlSize at byte 7.
        try entity(id: bytes[3], controlSizeAt: 7, in: bytes, at: offset)
    }

    /// Reads an entity's ID and its `bmControls` bitmap, whose size byte
    /// sits at a position that differs by descriptor type.
    ///
    /// - Parameters:
    ///   - id: The entity's ID.
    ///   - sizeIndex: Where `bControlSize` sits in the descriptor.
    ///   - bytes: The descriptor.
    ///   - offset: Where it starts in the configuration, for the error.
    /// - Returns: The entity.
    private static func entity(id: UInt8, controlSizeAt sizeIndex: Int, in bytes: [UInt8], at offset: Int) throws
        -> Entity
    {
        guard sizeIndex < bytes.count else {
            throw UVCError.malformedDescriptor(
                "entity \(id) at byte \(offset) is \(bytes.count) bytes, too short to declare its controls")
        }
        let size = Int(bytes[sizeIndex])
        let start = sizeIndex + 1
        guard start + size <= bytes.count else {
            throw UVCError.malformedDescriptor(
                "entity \(id) at byte \(offset) declares a \(size)-byte control bitmap that runs past its end")
        }
        return Entity(id: id, controls: Array(bytes[start..<start + size]))
    }
}
