//
//  UVCCamera.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A UVC camera, described: the controls its configuration descriptor
/// advertises, each with the range, step, and default the camera reported.
///
/// Creating one opens the camera, reads its descriptor and describes every
/// advertised control in one exchange, and closes it again — a camera is
/// never held open (docs/UVC.md). The controls then read and set values on
/// demand:
///
/// ```swift
/// guard let device = try UVCDevice.all().first else { return }
/// let camera = try UVCCamera(device: device)
/// if let zoom = camera.zoom {
///     try zoom.setValue(min(zoom.maximum, zoom.minimum + 25))
/// }
/// ```
///
/// A control the camera does not advertise is absent: its property is nil
/// and it is not in ``controls``.
public struct UVCCamera: Sendable {
    /// The camera's name, as its USB product string reads.
    public let name: String

    /// The controls the camera advertises and could describe, in
    /// ``UVCControlKind`` declaration order.
    public let controls: [UVCControl]

    /// The transport every exchange with the camera opens through.
    private let transport: any UVCTransport

    /// Opens a connected camera through `IOUSBHost` and describes it.
    ///
    /// Throws ``UVCError/deviceNotFound(name:)`` when the camera has been
    /// unplugged, ``UVCError/openFailed(name:reason:)`` when it cannot be
    /// opened, ``UVCError/noVideoControlInterface(name:)`` when it is not a
    /// UVC camera, and ``UVCError/malformedDescriptor(_:)`` when its
    /// descriptor cannot be read.
    ///
    /// - Parameter device: The camera, from ``UVCDevice/all()`` or
    ///   ``UVCDevice/matching(captureDeviceUniqueID:)``.
    public init(device: UVCDevice) throws {
        try self.init(name: device.name, transport: IOUSBHostTransport(device: device))
    }

    /// Describes a camera reached through any transport — the seam a test,
    /// or an app driving a simulated camera, uses.
    ///
    /// Throws as ``init(device:)`` does, as the transport reports.
    ///
    /// - Parameters:
    ///   - name: The camera's name, for errors.
    ///   - transport: The transport to describe the camera through.
    public init(name: String, transport: any UVCTransport) throws {
        self.name = name
        self.transport = transport
        self.controls = try transport.withConnection { connection in
            let topology = try VideoControlTopology(
                configurationDescriptor: connection.configurationDescriptor(),
                deviceName: name
            )
            return UVCControlKind.allCases.compactMap { kind in
                guard let entity = topology.entity(for: kind), entity.advertises(bit: kind.controlBit) else {
                    return nil
                }
                return UVCControl.describe(
                    kind,
                    entityID: entity.id,
                    interfaceNumber: topology.interfaceNumber,
                    on: connection,
                    transport: transport
                )
            }
        }
    }

    /// The control of a kind, or nil when the camera does not have it.
    ///
    /// - Parameter kind: The control kind.
    /// - Returns: The control, or nil.
    public func control(_ kind: UVCControlKind) -> UVCControl? {
        controls.first { $0.kind == kind }
    }

    /// Opens the camera once for several reads and writes, passing the
    /// connection to each control's `on:` call, and closes it when the body
    /// returns.
    ///
    /// Throws whatever opening the camera or the body throws.
    ///
    /// - Parameter body: The exchange to run.
    /// - Returns: What the body returns.
    public func withConnection<Result>(_ body: (any UVCConnection) throws -> Result) throws -> Result {
        try transport.withConnection(body)
    }

    /// The auto exposure mode control, or nil.
    public var autoExposureMode: UVCControl? { control(.autoExposureMode) }

    /// The auto exposure priority control, or nil.
    public var autoExposurePriority: UVCControl? { control(.autoExposurePriority) }

    /// The exposure time control (100 µs units), or nil.
    public var exposureTime: UVCControl? { control(.exposureTime) }

    /// The gain control, or nil.
    public var gain: UVCControl? { control(.gain) }

    /// The backlight compensation control, or nil.
    public var backlightCompensation: UVCControl? { control(.backlightCompensation) }

    /// The brightness control, or nil.
    public var brightness: UVCControl? { control(.brightness) }

    /// The contrast control, or nil.
    public var contrast: UVCControl? { control(.contrast) }

    /// The saturation control, or nil.
    public var saturation: UVCControl? { control(.saturation) }

    /// The sharpness control, or nil.
    public var sharpness: UVCControl? { control(.sharpness) }

    /// The hue control (hundredths of a degree), or nil.
    public var hue: UVCControl? { control(.hue) }

    /// The gamma control, or nil.
    public var gamma: UVCControl? { control(.gamma) }

    /// The white balance temperature auto switch, or nil.
    public var whiteBalanceTemperatureAuto: UVCControl? { control(.whiteBalanceTemperatureAuto) }

    /// The white balance temperature control (kelvin), or nil.
    public var whiteBalanceTemperature: UVCControl? { control(.whiteBalanceTemperature) }

    /// The power line frequency control, or nil.
    public var powerLineFrequency: UVCControl? { control(.powerLineFrequency) }

    /// The focus auto switch, or nil.
    public var focusAuto: UVCControl? { control(.focusAuto) }

    /// The focus control, or nil.
    public var focus: UVCControl? { control(.focus) }

    /// The zoom control, or nil.
    public var zoom: UVCControl? { control(.zoom) }

    /// The pan control (arc seconds), or nil.
    public var pan: UVCControl? { control(.pan) }

    /// The tilt control (arc seconds), or nil.
    public var tilt: UVCControl? { control(.tilt) }
}
