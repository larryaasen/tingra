//
//  SystemDefaultInputs.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import TingraPlugInKit

/// The system default camera and microphone, as input identifiers.
///
/// `tingra-cli stream` defaults to the system defaults when `--camera` /
/// `--mic` are not given (CLI.md, "Input selection"); resolving them is
/// this plug-in package's job because only it may import AVFoundation —
/// the CLI consumes the identifiers and resolves them against the registry
/// like any other selector. Reading the defaults is discovery, not
/// capture, so it needs no TCC authorization.
public enum SystemDefaultInputs {
    /// The system default camera's input identifier, or nil when no camera
    /// is connected.
    public static var cameraID: InputID? {
        AVCaptureDevice.default(for: .video).map { InputID(rawValue: $0.uniqueID) }
    }

    /// The system default microphone's input identifier, or nil when no
    /// microphone is connected.
    public static var microphoneID: InputID? {
        AVCaptureDevice.default(for: .audio).map { InputID(rawValue: $0.uniqueID) }
    }
}
