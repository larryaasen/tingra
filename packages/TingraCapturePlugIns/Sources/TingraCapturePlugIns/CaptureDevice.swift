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

/// Errors thrown by the capture inputs.
enum CaptureInputError: Error, Equatable {
    /// `start()` was called on a discovery-only input.
    case captureNotImplemented(InputID)
}

extension CaptureInputError: CustomStringConvertible {
    var description: String {
        switch self {
        case .captureNotImplemented(let id):
            return """
                The input '\(id.rawValue)' was discovered but cannot capture yet — camera and \
                microphone capture arrives with roadmap step 2. Until then this input supports \
                discovery only (`tingra-cli devices`).
                """
        }
    }
}

/// A discovered capture device, registered as an input.
///
/// Discovery-only for now: `start()` throws a descriptive error until
/// capture lands (roadmap step 2), and `frames()` returns an
/// already-finished stream.
struct CaptureDeviceInput: Input {
    /// The discovered device this input wraps.
    private let device: CaptureDevice

    /// Creates an input over a discovered device.
    init(device: CaptureDevice) {
        self.device = device
    }

    /// The stable identifier — the device's unique ID, verbatim, so
    /// `devices --json` output works as a selector across launches.
    var id: InputID { InputID(rawValue: device.uniqueID) }

    /// The user-facing device name.
    var name: String { device.name }

    /// Whether this input is a camera or a microphone.
    var kind: InputKind { device.kind }

    /// Throws ``CaptureInputError/captureNotImplemented(_:)`` — capture
    /// arrives with roadmap step 2.
    func start() async throws {
        throw CaptureInputError.captureNotImplemented(id)
    }

    /// An already-finished stream; frames arrive with roadmap step 2.
    func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { $0.finish() }
    }

    /// Nothing to release while the input is discovery-only.
    func stop() async {}
}
