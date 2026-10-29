//
//  CameraControls.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// A camera's adjustable controls, as the parameters ``CameraInput``
/// declares: what they are, their values now, and a way to write some of
/// them. The production conformer is ``UVCCameraControls``; tests script
/// one, so the input's parameter behavior is tested with no camera.
///
/// Reads and writes are blocking device exchanges of a few milliseconds;
/// callers run them off the main actor.
protocol CameraControls: Sendable {
    /// The parameters the controls declare, in display order.
    var parameters: [Parameter] { get }

    /// Reads every declared parameter's current value from the camera.
    ///
    /// Throws when the camera cannot be reached.
    ///
    /// - Returns: The payload, keyed by ``Parameter/key``.
    func read() throws -> [String: JSONValue]

    /// Writes values to the camera in order, in one exchange.
    ///
    /// - Parameter values: The keys and payload values to write.
    /// - Returns: One failure per value the camera did not take — every
    ///   value when the camera could not be reached at all.
    func write(_ values: [(key: String, value: JSONValue)]) -> [CameraControlFailure]
}

/// A value a camera did not take, with the camera's reason.
struct CameraControlFailure: Error, Equatable {
    /// The parameter's key.
    let key: String

    /// Why the camera did not take it.
    let reason: String
}

extension CameraControlFailure: CustomStringConvertible {
    /// The camera's reason, which is what an error event carries.
    var description: String { reason }
}

/// The pure rules for turning a host's payload into camera writes: which
/// values to write and in what order (docs/UVC.md, "The camera input's
/// parameters").
enum CameraParameterPlan {
    /// The value every declared parameter takes under a payload — the
    /// toggles' booleans and the numbers clamped into range and onto their
    /// step, with omitted keys at their declared defaults (the
    /// `setParameters` contract).
    ///
    /// - Parameters:
    ///   - payload: The host's payload.
    ///   - parameters: The declared parameters.
    /// - Returns: A payload holding every toggle and number parameter.
    static func resolved(_ payload: [String: JSONValue], parameters: [Parameter]) -> [String: JSONValue] {
        var resolved: [String: JSONValue] = [:]
        for parameter in parameters {
            switch parameter.kind {
            case .toggle:
                resolved[parameter.key] = .bool(parameter.isOn(in: payload) ?? false)
            case .number:
                resolved[parameter.key] = .double(parameter.snapped(parameter.value(in: payload)))
            case .color:
                // A camera control is never a color; nothing to resolve.
                continue
            @unknown default:
                // A kind a later kit adds has no camera control behind it.
                continue
            }
        }
        return resolved
    }

    /// The writes a resolved payload calls for: only values that differ
    /// from what the camera is known to hold, toggles before everything
    /// else — so an Auto switch turned off releases its value before a
    /// manual value is written — and never a value whose Auto toggle is on,
    /// because the camera owns it then.
    ///
    /// - Parameters:
    ///   - resolved: The payload from ``resolved(_:parameters:)``.
    ///   - parameters: The declared parameters, in display order.
    ///   - known: The values the camera was last read or written with.
    /// - Returns: The keys and values to write, in order.
    static func writes(
        for resolved: [String: JSONValue],
        parameters: [Parameter],
        known: [String: JSONValue]
    ) -> [(key: String, value: JSONValue)] {
        let toggles = parameters.filter { $0.kind == .toggle }
        let others = parameters.filter { $0.kind != .toggle }
        return (toggles + others).compactMap { parameter in
            guard let value = resolved[parameter.key], value != known[parameter.key],
                !parameter.isControlledAutomatically(in: resolved, among: parameters)
            else { return nil }
            return (parameter.key, value)
        }
    }
}
