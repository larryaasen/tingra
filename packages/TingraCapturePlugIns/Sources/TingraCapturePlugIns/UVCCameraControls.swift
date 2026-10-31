//
//  UVCCameraControls.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit
import TingraUVC

/// A UVC camera's controls as Tingra parameters: one ``Parameter`` per
/// control the camera advertises and Tingra maps, with the camera's own
/// range and default, in the sections and order docs/UVC.md lays out.
///
/// TingraUVC is imported here and nowhere else in the package, behind the
/// ``CameraControls`` seam — the input knows parameters, never UVC.
struct UVCCameraControls: CameraControls {
    /// How a parameter's payload value relates to its control's raw value.
    enum Conversion: Sendable, Equatable {
        /// A number in display units: raw value ÷ divisor (`10` turns 100 µs
        /// units into milliseconds, `3600` arc seconds into degrees).
        case number(divisor: Double)

        /// On or off: on is the control's maximum, off its minimum.
        case toggle

        /// Auto exposure on or off: on is the given automatic mode, off is
        /// manual.
        case autoExposure(automaticMode: UVCAutoExposureMode)
    }

    /// One mapped control.
    struct Mapping: Sendable {
        /// The parameter it is declared as.
        let parameter: Parameter

        /// The camera control behind it.
        let control: UVCControl

        /// How payload values convert to raw values.
        let conversion: Conversion
    }

    /// The mapped controls, in display order.
    let mappings: [Mapping]

    /// The described camera the mappings' controls belong to.
    private let camera: UVCCamera

    /// The parameters, in display order.
    var parameters: [Parameter] { mappings.map(\.parameter) }

    /// Maps a described camera's controls, or nil when it has none Tingra
    /// maps.
    ///
    /// - Parameter camera: The described UVC camera.
    init?(camera: UVCCamera) {
        let mappings = Self.mappings(for: camera)
        guard !mappings.isEmpty else { return nil }
        self.camera = camera
        self.mappings = mappings
    }

    /// Describes the UVC camera behind a capture device, when there is one.
    ///
    /// Throws a `UVCError` when the device is a UVC camera that cannot be
    /// described (it could not be opened, or its descriptor is malformed).
    ///
    /// - Parameter device: The discovered capture device.
    /// - Returns: Its controls, or nil when it is not a UVC camera or
    ///   advertises nothing Tingra maps.
    static func describe(_ device: CaptureDevice) throws -> (any CameraControls)? {
        guard device.kind == .camera,
            let usbDevice = try UVCDevice.matching(captureDeviceUniqueID: device.uniqueID)
        else { return nil }
        return UVCCameraControls(camera: try UVCCamera(device: usbDevice))
    }

    /// Reads every mapped control's value in one exchange.
    ///
    /// - Returns: The payload, keyed by parameter.
    func read() throws -> [String: JSONValue] {
        try camera.withConnection { connection in
            var payload: [String: JSONValue] = [:]
            for mapping in mappings {
                let raw = try mapping.control.value(on: connection)
                payload[mapping.parameter.key] = Self.payloadValue(raw: raw, for: mapping)
            }
            return payload
        }
    }

    /// Writes values in one exchange, collecting each value the camera does
    /// not take.
    ///
    /// - Parameter values: The keys and payload values to write, in order.
    /// - Returns: The failures.
    func write(_ values: [(key: String, value: JSONValue)]) -> [CameraControlFailure] {
        do {
            return try camera.withConnection { connection in
                var failures: [CameraControlFailure] = []
                for (key, value) in values {
                    guard let mapping = mappings.first(where: { $0.parameter.key == key }) else { continue }
                    do {
                        try mapping.control.setValue(Self.rawValue(for: value, of: mapping), on: connection)
                    } catch {
                        failures.append(CameraControlFailure(key: key, reason: String(describing: error)))
                    }
                }
                return failures
            }
        } catch {
            let reason = String(describing: error)
            return values.map { CameraControlFailure(key: $0.key, reason: reason) }
        }
    }

    /// A raw control value as a payload value.
    ///
    /// - Parameters:
    ///   - raw: The control's raw value.
    ///   - mapping: The mapping it belongs to.
    /// - Returns: The payload value.
    static func payloadValue(raw: Int, for mapping: Mapping) -> JSONValue {
        switch mapping.conversion {
        case .number(let divisor):
            return .double(Double(raw) / divisor)
        case .toggle:
            return .bool(raw != mapping.control.minimum)
        case .autoExposure:
            let mode = UVCAutoExposureMode(rawValue: UInt8(truncatingIfNeeded: raw))
            return .bool(!mode.isDisjoint(with: .automaticExposureTime))
        }
    }

    /// A payload value as the raw value to write: converted, snapped to the
    /// control's step, and clamped into its range.
    ///
    /// - Parameters:
    ///   - value: The payload value.
    ///   - mapping: The mapping it belongs to.
    /// - Returns: The raw value.
    static func rawValue(for value: JSONValue, of mapping: Mapping) -> Int {
        let control = mapping.control
        switch mapping.conversion {
        case .number(let divisor):
            let raw = (value.doubleValue ?? mapping.parameter.defaultValue) * divisor
            let steps = ((raw - Double(control.minimum)) / Double(control.resolution)).rounded()
            let snapped = control.minimum + Int(steps) * control.resolution
            return min(control.maximum, max(control.minimum, snapped))
        case .toggle:
            return mapping.parameter.isOn(in: [mapping.parameter.key: value]) == true
                ? control.maximum : control.minimum
        case .autoExposure(let automaticMode):
            let isOn = mapping.parameter.isOn(in: [mapping.parameter.key: value]) == true
            return Int((isOn ? automaticMode : .manual).rawValue)
        }
    }

    /// Builds the mappings for a camera's controls, in display order.
    ///
    /// - Parameter camera: The described camera.
    /// - Returns: The mappings for the controls it has.
    static func mappings(for camera: UVCCamera) -> [Mapping] {
        var mappings: [Mapping] = []

        let exposureAuto = autoExposureMapping(camera.autoExposureMode)
        if let exposureAuto { mappings.append(exposureAuto) }
        let exposureGovernor = exposureAuto?.parameter.key
        mappings += [
            numberMapping(
                camera.exposureTime, key: "exposureTime", name: "Exposure Time", section: "Exposure",
                unit: "ms", divisor: 10, scale: .logarithmic, governedBy: exposureGovernor),
            numberMapping(
                camera.gain, key: "gain", name: "Gain", section: "Exposure", governedBy: exposureGovernor),
            numberMapping(
                camera.backlightCompensation, key: "backlightCompensation", name: "Backlight Compensation",
                section: "Exposure"),
            powerLineFrequencyMapping(camera.powerLineFrequency),
            numberMapping(camera.brightness, key: "brightness", name: "Brightness", section: "Image"),
            numberMapping(camera.contrast, key: "contrast", name: "Contrast", section: "Image"),
            numberMapping(camera.saturation, key: "saturation", name: "Saturation", section: "Image"),
            numberMapping(camera.sharpness, key: "sharpness", name: "Sharpness", section: "Image"),
            numberMapping(camera.hue, key: "hue", name: "Hue", section: "Image", unit: "°", divisor: 100),
            numberMapping(camera.gamma, key: "gamma", name: "Gamma", section: "Image"),
        ].compactMap { $0 }

        let focusAuto = toggleMapping(camera.focusAuto, key: "focusAuto", name: "Auto Focus", section: "Image")
        mappings += [
            focusAuto,
            numberMapping(
                camera.focus, key: "focus", name: "Focus", section: "Image", governedBy: focusAuto?.parameter.key),
        ].compactMap { $0 }

        let whiteBalanceAuto = toggleMapping(
            camera.whiteBalanceTemperatureAuto, key: "whiteBalanceAuto", name: "Auto White Balance",
            section: "White Balance")
        mappings += [
            whiteBalanceAuto,
            numberMapping(
                camera.whiteBalanceTemperature, key: "whiteBalanceTemperature", name: "Temperature",
                section: "White Balance", unit: "K", governedBy: whiteBalanceAuto?.parameter.key),
        ].compactMap { $0 }

        mappings += [
            numberMapping(camera.zoom, key: "zoom", name: "Zoom", section: "Framing"),
            numberMapping(camera.pan, key: "pan", name: "Pan", section: "Framing", unit: "°", divisor: 3600),
            numberMapping(camera.tilt, key: "tilt", name: "Tilt", section: "Framing", unit: "°", divisor: 3600),
        ].compactMap { $0 }

        return mappings
    }

    /// Maps a range control to a number parameter — or, when its range is
    /// just `0`…`1` (the Razer's backlight compensation), to a toggle, since
    /// a two-position slider is a switch.
    ///
    /// - Parameters:
    ///   - control: The control, or nil when the camera lacks it.
    ///   - key: The parameter's stable payload key.
    ///   - name: The parameter's user-facing name.
    ///   - section: The section heading.
    ///   - unit: The display unit, or nil.
    ///   - divisor: Raw value ÷ divisor = display value.
    ///   - scale: The slider scale.
    ///   - governedBy: The key of the Auto toggle that owns the value while
    ///     on, or nil.
    /// - Returns: The mapping, or nil when the control is missing or has
    ///   nothing to adjust.
    private static func numberMapping(
        _ control: UVCControl?,
        key: String,
        name: String,
        section: String,
        unit: String? = nil,
        divisor: Double = 1,
        scale: Parameter.Scale = .linear,
        governedBy: String? = nil
    ) -> Mapping? {
        guard let control, control.minimum < control.maximum else { return nil }
        if control.minimum == 0, control.maximum == 1 {
            return toggleMapping(control, key: key, name: name, section: section)
        }
        var parameter = Parameter(
            key: key,
            name: name,
            range: Double(control.minimum) / divisor...Double(control.maximum) / divisor,
            defaultValue: Double(control.defaultValue) / divisor,
            unit: unit,
            scale: control.minimum > 0 ? scale : .linear
        )
        .inSection(section)
        // The camera's own step, so a slider lands only on values it takes.
        .stepped(by: Double(control.resolution) / divisor)
        if let governedBy {
            parameter = parameter.controlledAutomatically(whenOn: governedBy)
        }
        return Mapping(parameter: parameter, control: control, conversion: .number(divisor: divisor))
    }

    /// Maps an on/off control to a toggle parameter.
    ///
    /// - Parameters:
    ///   - control: The control, or nil when the camera lacks it.
    ///   - key: The parameter's stable payload key.
    ///   - name: The parameter's user-facing name.
    ///   - section: The section heading.
    /// - Returns: The mapping, or nil when the control is missing.
    private static func toggleMapping(_ control: UVCControl?, key: String, name: String, section: String) -> Mapping? {
        guard let control else { return nil }
        let parameter = Parameter(key: key, name: name, defaultIsOn: control.defaultValue != control.minimum)
            .inSection(section)
        return Mapping(parameter: parameter, control: control, conversion: .toggle)
    }

    /// Maps the power line frequency to a choice of the options the control
    /// takes: Auto only on a camera whose range reaches it.
    ///
    /// - Parameter control: The power line frequency control, or nil.
    /// - Returns: The mapping, or nil when the camera lacks the control or
    ///   leaves nothing to choose between.
    private static func powerLineFrequencyMapping(_ control: UVCControl?) -> Mapping? {
        guard let control else { return nil }
        let choices = [(0, "Disabled"), (1, "50 Hz"), (2, "60 Hz"), (3, "Auto")]
            .filter { control.range.contains($0.0) }
            .map { Parameter.Choice(value: Double($0.0), name: $0.1) }
        guard choices.count > 1 else { return nil }
        let parameter = Parameter(
            key: "powerLineFrequency",
            name: "Power Line Frequency",
            choices: choices,
            defaultValue: Double(control.defaultValue)
        ).inSection("Exposure")
        return Mapping(parameter: parameter, control: control, conversion: .number(divisor: 1))
    }

    /// Maps the auto exposure mode to the Auto Exposure toggle: on is the
    /// camera's own automatic mode (its default when that is automatic,
    /// else aperture priority, else full auto), off is manual.
    ///
    /// - Parameter control: The auto exposure mode control, or nil.
    /// - Returns: The mapping, or nil when the camera lacks the control or
    ///   cannot switch between manual and an automatic mode.
    private static func autoExposureMapping(_ control: UVCControl?) -> Mapping? {
        guard let control, let supported = control.supportedAutoExposureModes, supported.contains(.manual)
        else { return nil }
        let defaultMode = UVCAutoExposureMode(rawValue: UInt8(truncatingIfNeeded: control.defaultValue))
        let automaticMode: UVCAutoExposureMode
        let defaultIsOneAutomaticMode =
            defaultMode.rawValue.nonzeroBitCount == 1 && supported.contains(defaultMode)
            && UVCAutoExposureMode.automaticExposureTime.contains(defaultMode)
        if defaultIsOneAutomaticMode {
            automaticMode = defaultMode
        } else if supported.contains(.aperturePriority) {
            automaticMode = .aperturePriority
        } else if supported.contains(.auto) {
            automaticMode = .auto
        } else {
            return nil
        }
        let parameter = Parameter(
            key: "exposureAuto",
            name: "Auto Exposure",
            defaultIsOn: !defaultMode.isDisjoint(with: .automaticExposureTime)
        ).inSection("Exposure")
        return Mapping(parameter: parameter, control: control, conversion: .autoExposure(automaticMode: automaticMode))
    }
}
