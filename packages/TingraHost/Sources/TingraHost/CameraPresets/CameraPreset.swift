//
//  CameraPreset.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// One saved camera preset: a name, the camera it was saved from, and that
/// camera's control values — brightness, white balance, exposure, focus,
/// pan, tilt, zoom — as the camera input's parameter payload (docs/UVC.md,
/// "Camera presets").
///
/// Recalling a preset selects its camera and writes the values back through
/// `Input.setParameters(_:)`, which writes the Auto switches first and skips
/// a value its Auto switch owns, so a payload read from the camera is always
/// safe to write back whole.
///
/// The JSON keys are spelled out, so the file's shape is the contract.
public struct CameraPreset: Codable, Equatable, Identifiable, Sendable {
    /// The preset's identity, stable across renames and updates.
    public let id: UUID

    /// The operator's name for the preset.
    public var name: String

    /// The identifier of the camera the preset was saved from — the camera
    /// input's id (`AVCaptureDevice.uniqueID`).
    public let cameraID: String

    /// The name of the camera the preset was saved from, kept so the preset
    /// still finds its camera when the id changes — a USB camera's id
    /// includes the port it is plugged into — and so the preset can say
    /// which camera it is for while that camera is away.
    public let cameraName: String

    /// The camera's control values, keyed by parameter.
    public var values: [String: JSONValue]

    /// Creates a preset.
    ///
    /// - Parameters:
    ///   - id: The preset's identity (a fresh one by default).
    ///   - name: The operator's name for it.
    ///   - cameraID: The identifier of the camera it was saved from.
    ///   - cameraName: The name of the camera it was saved from.
    ///   - values: The camera's control values, keyed by parameter.
    public init(
        id: UUID = UUID(),
        name: String,
        cameraID: String,
        cameraName: String,
        values: [String: JSONValue]
    ) {
        self.id = id
        self.name = name
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.values = values
    }

    /// The JSON keys.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case cameraID
        case cameraName
        case values
    }

    /// The camera among those connected that this preset is for: the one
    /// with its camera's id, else the first with its camera's name — the
    /// same camera plugged into another port — else nil, when its camera is
    /// not connected.
    ///
    /// - Parameters:
    ///   - cameras: The connected cameras.
    ///   - id: A camera's identifier.
    ///   - name: A camera's name.
    /// - Returns: The preset's camera, or nil.
    public func camera<Camera>(
        among cameras: [Camera],
        id: (Camera) -> String,
        name: (Camera) -> String
    ) -> Camera? {
        cameras.first { id($0) == cameraID } ?? cameras.first { name($0) == cameraName }
    }
}
