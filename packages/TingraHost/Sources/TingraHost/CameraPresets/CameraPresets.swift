//
//  CameraPresets.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// The operator's camera presets and which of them, if any, is the default
/// applied at launch (docs/UVC.md, "Camera presets").
///
/// A value holding the rules and nothing else — what saving, renaming,
/// updating, and deleting do to the list and to the default — so the rules
/// are the same in every front end and are tested without a file system or
/// a camera. The front end persists it through ``CameraPresetStore``.
///
/// **There is no default until there is a preset.** The first preset saved
/// becomes the default; the operator can make any other one the default
/// instead. Deleting the default hands the role to the first preset left,
/// so while there are presets one of them is always the default, and with
/// none left there is none.
public struct CameraPresets: Codable, Equatable, Sendable {
    /// The presets, in the order they were saved.
    public private(set) var presets: [CameraPreset]

    /// The identity of the default preset, or nil when there are no presets.
    public private(set) var defaultPresetID: UUID?

    /// Creates a preset list.
    ///
    /// - Parameters:
    ///   - presets: The presets, in the order they were saved (none by
    ///     default).
    ///   - defaultPresetID: The default preset's identity. An identity no
    ///     preset has falls back to the first preset, so a list with presets
    ///     always has a default.
    public init(presets: [CameraPreset] = [], defaultPresetID: UUID? = nil) {
        self.presets = presets
        self.defaultPresetID = Self.validDefault(defaultPresetID, in: presets)
    }

    /// The JSON keys.
    enum CodingKeys: String, CodingKey {
        case presets
        case defaultPresetID
    }

    /// Decodes a preset list, holding it to the same default rule as
    /// ``init(presets:defaultPresetID:)``: a file naming a default it does
    /// not hold reads with its first preset as the default.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: A decoding error when `presets` is missing or malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            presets: try container.decode([CameraPreset].self, forKey: .presets),
            defaultPresetID: try container.decodeIfPresent(UUID.self, forKey: .defaultPresetID)
        )
    }

    /// The default preset, or nil when there are no presets.
    public var defaultPreset: CameraPreset? {
        defaultPresetID.flatMap(preset(withID:))
    }

    /// Whether there are no presets.
    public var isEmpty: Bool { presets.isEmpty }

    /// The preset with an identity, or nil.
    ///
    /// - Parameter id: The preset's identity.
    /// - Returns: The preset, or nil.
    public func preset(withID id: UUID) -> CameraPreset? {
        presets.first { $0.id == id }
    }

    /// Whether a preset is the default.
    ///
    /// - Parameter id: The preset's identity.
    /// - Returns: Whether it is the default.
    public func isDefault(_ id: UUID) -> Bool {
        defaultPresetID == id
    }

    /// The name a new preset is offered: a numbered name with the next
    /// number not already taken by a preset of that name, so saving several
    /// in a row never offers the same name twice. The front end supplies the
    /// wording, so the name is in the operator's language.
    ///
    /// - Parameter numberedName: Makes a name from a number, e.g.
    ///   "Preset 3".
    /// - Returns: The suggested name.
    public func suggestedName(_ numberedName: (Int) -> String) -> String {
        let names = Set(presets.map(\.name))
        var number = presets.count + 1
        while names.contains(numberedName(number)) {
            number += 1
        }
        return numberedName(number)
    }

    /// Saves a new preset at the end of the list. The first preset saved
    /// becomes the default.
    ///
    /// The name is trimmed of surrounding whitespace; an empty name saves
    /// nothing, because a preset in a list needs a label — the front end
    /// offers ``suggestedName(_:)`` in its place.
    ///
    /// - Parameters:
    ///   - name: The operator's name for it.
    ///   - cameraID: The identifier of the camera its values are from.
    ///   - cameraName: The name of that camera.
    ///   - values: The camera's control values, keyed by parameter.
    /// - Returns: The new preset, or nil when the trimmed name is empty.
    @discardableResult
    public mutating func save(
        name: String,
        cameraID: String,
        cameraName: String,
        values: [String: JSONValue]
    ) -> CameraPreset? {
        let trimmed = Self.trimmed(name)
        guard !trimmed.isEmpty else { return nil }
        let preset = CameraPreset(name: trimmed, cameraID: cameraID, cameraName: cameraName, values: values)
        presets.append(preset)
        if defaultPresetID == nil {
            defaultPresetID = preset.id
        }
        return preset
    }

    /// Renames a preset. The name is trimmed of surrounding whitespace; an
    /// empty name changes nothing, because a preset in a list needs a label.
    ///
    /// - Parameters:
    ///   - id: The preset's identity.
    ///   - name: The new name.
    /// - Returns: Whether the preset changed, so the caller knows there is
    ///   something to save.
    @discardableResult
    public mutating func rename(_ id: UUID, to name: String) -> Bool {
        let trimmed = Self.trimmed(name)
        guard !trimmed.isEmpty, let index = presets.firstIndex(where: { $0.id == id }),
            presets[index].name != trimmed
        else { return false }
        presets[index].name = trimmed
        return true
    }

    /// Replaces a preset's values with the camera's current ones, keeping
    /// its identity, name, camera, and place in the list.
    ///
    /// - Parameters:
    ///   - id: The preset's identity.
    ///   - values: The camera's control values now, keyed by parameter.
    /// - Returns: Whether the preset changed.
    @discardableResult
    public mutating func update(_ id: UUID, values: [String: JSONValue]) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == id }), presets[index].values != values else {
            return false
        }
        presets[index].values = values
        return true
    }

    /// Makes a preset the default applied at launch.
    ///
    /// - Parameter id: The preset's identity.
    /// - Returns: Whether the default changed — false when it already was
    ///   the default, or no preset has that identity.
    @discardableResult
    public mutating func makeDefault(_ id: UUID) -> Bool {
        guard defaultPresetID != id, preset(withID: id) != nil else { return false }
        defaultPresetID = id
        return true
    }

    /// Deletes a preset. Deleting the default makes the first preset left
    /// the default, or leaves no default when none is left.
    ///
    /// - Parameter id: The preset's identity.
    /// - Returns: The deleted preset, or nil when no preset has that
    ///   identity.
    @discardableResult
    public mutating func delete(_ id: UUID) -> CameraPreset? {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = presets.remove(at: index)
        defaultPresetID = Self.validDefault(defaultPresetID, in: presets)
        return removed
    }

    /// A default identity held to the rule: the given one when a preset has
    /// it, else the first preset's, else nil.
    ///
    /// - Parameters:
    ///   - id: The proposed default.
    ///   - presets: The presets.
    /// - Returns: The default identity.
    private static func validDefault(_ id: UUID?, in presets: [CameraPreset]) -> UUID? {
        if let id, presets.contains(where: { $0.id == id }) {
            return id
        }
        return presets.first?.id
    }

    /// A name trimmed of surrounding whitespace and newlines.
    ///
    /// - Parameter name: The name as typed.
    /// - Returns: The trimmed name.
    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
