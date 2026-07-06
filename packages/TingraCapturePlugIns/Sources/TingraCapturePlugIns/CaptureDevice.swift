//
//  CaptureDevice.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// One capture device as discovery sees it: the stable identifier, the
/// user-facing name, and the kind — the framework-free reduction of
/// `AVCaptureDevice` the rest of the plug-in (and its tests) work with.
struct CaptureDevice: Sendable, Equatable {
    /// The stable identifier (`AVCaptureDevice.uniqueID` in production):
    /// the same physical device yields the same value across launches
    /// wherever the platform allows.
    let uniqueID: String

    /// The user-facing device name, e.g. "FaceTime HD Camera".
    let name: String

    /// Whether the device is a camera or a microphone.
    let kind: InputKind
}

/// Errors thrown by the capture inputs when they start.
///
/// Public so front ends (the CLI's `stream`) can map the cases to their
/// stable error identifiers. Device disconnection after a successful start
/// is a normal event, never an error (CLAUDE.md, Data Flow Rules).
public enum CaptureInputError: Error, Equatable {
    /// TCC denied access to the device's kind (camera, microphone, or
    /// display — Screen Recording).
    case authorizationDenied(InputKind, InputID)

    /// The device has disconnected since discovery, so capture cannot
    /// start from it.
    case deviceUnavailable(InputID)

    /// The capture framework rejected the configuration; the string names
    /// the rejected step.
    case configurationRejected(InputID, String)
}

extension CaptureInputError {
    /// The stable error identifier this error reports under (see CLI.md,
    /// "Error identifiers").
    public var identifier: ErrorIdentifier {
        switch self {
        case .authorizationDenied: return .authorizationDenied
        case .deviceUnavailable: return .inputNotFound
        case .configurationRejected: return .pipelineError
        }
    }
}

/// The capture errors carry their identifiers so a front end can map them
/// without importing this package (see `IdentifiedError`).
extension CaptureInputError: IdentifiedError {}

extension CaptureInputError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .authorizationDenied(let kind, let id):
            let permission: String
            switch kind {
            case .camera: permission = "Camera"
            case .microphone: permission = "Microphone"
            case .display: permission = "Screen Recording"
            // A generator has no device and is never denied; named for
            // exhaustiveness only.
            case .generator: permission = "Capture"
            }
            return """
                \(permission) access for the input '\(id.rawValue)' was denied. Grant it in \
                System Settings > Privacy & Security > \(permission), or use a generator \
                (`--video-generator bars`, `--audio-generator tone`) to run without hardware.
                """
        case .deviceUnavailable(let id):
            return """
                The input '\(id.rawValue)' is no longer connected. Reconnect the device, or run \
                `tingra-cli devices` to pick one that is currently available.
                """
        case .configurationRejected(let id, let step):
            return """
                The input '\(id.rawValue)' could not be configured for capture: \(step). The device \
                may be in use by another app — close it and try again.
                """
        }
    }
}
