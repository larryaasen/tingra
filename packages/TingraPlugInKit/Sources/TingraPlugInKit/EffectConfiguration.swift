//
//  EffectConfiguration.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// One effect as a document persists it: the effect's stable ``EffectID``
/// plus its parameter payload — the effect seam's one persisted parameter
/// shape, shared by audio and video chains (ARCHITECTURE.md, "The effect
/// seam"). A chain persists as an ordered list of these on the document
/// that owns it (an authored audio channel, a layer); order is signal
/// order — the chain *is* its array.
///
/// A plain `Codable` value on the project/scripting contract: stable
/// camelCase keys, exact round-trip. The parameter payload is arbitrary
/// JSON (``JSONValue``) keyed by the effect's declared parameter keys; a
/// key the payload omits takes the parameter's declared default, so an
/// empty payload is the effect at its neutral settings.
///
/// The id is deliberately *not* validated at decode: a document may name
/// an effect this build has no provider for (a third-party effect not
/// installed, a newer first-party effect). The configuration survives the
/// round trip untouched; resolution happens — and can recoverably fail —
/// when the engine instantiates the chain.
public struct EffectConfiguration: Sendable, Equatable, Codable {
    /// The effect's stable identifier.
    public let effect: EffectID

    /// The effect's parameter values, keyed by its declared parameter
    /// keys. Keys the payload omits take their declared defaults.
    public let parameters: [String: JSONValue]

    /// Creates an effect configuration.
    ///
    /// - Parameters:
    ///   - effect: The effect's stable identifier.
    ///   - parameters: The parameter payload (default empty — the
    ///     effect at its neutral settings).
    public init(effect: EffectID, parameters: [String: JSONValue] = [:]) {
        self.effect = effect
        self.parameters = parameters
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case effect
        case parameters
    }

    /// Decodes a configuration. `effect` is required — a chain entry
    /// without its effect identity is meaningless; a missing `parameters`
    /// key decodes forgivingly to the empty payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effect = try container.decode(EffectID.self, forKey: .effect)
        parameters = try container.decodeIfPresent([String: JSONValue].self, forKey: .parameters) ?? [:]
    }

    /// Encodes a configuration, always writing both fields so the
    /// document round-trips exactly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(effect, forKey: .effect)
        try container.encode(parameters, forKey: .parameters)
    }
}
