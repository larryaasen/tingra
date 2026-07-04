//
//  InputRegistry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// Errors thrown by ``InputRegistry``.
public enum InputRegistryError: Error, Equatable {
    /// An input with the same identifier is already registered. The fix is
    /// for the plug-in to give every input it contributes a distinct,
    /// stable identifier.
    case duplicateInput(InputID)
}

extension InputRegistryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateInput(let id):
            return """
                An input with the identifier '\(id.rawValue)' is already registered. \
                Each input must have a distinct, stable identifier; the plug-in \
                contributing this input should derive its identifiers from the \
                underlying device or generator so they never collide.
                """
        }
    }
}

/// The seam where input plug-ins attach: plug-ins register the inputs they
/// contribute, and the engine resolves inputs from here — by identifier
/// (from `devices --json` selectors) or as the full discovery list.
///
/// One registry instance per host; plug-ins receive it through the
/// registration path, never as a global.
public actor InputRegistry {
    /// The registered inputs, keyed by their stable identifiers.
    private var inputs: [InputID: any Input] = [:]

    /// Creates an empty registry. The host owns one per engine.
    public init() {}

    /// Registers an input contributed by a plug-in.
    ///
    /// Throws ``InputRegistryError/duplicateInput(_:)`` if the identifier is
    /// already taken — a plug-in defect surfaces as a thrown error, never a
    /// trap (CLAUDE.md, never-crash rule).
    public func register(_ input: any Input) throws {
        guard inputs[input.id] == nil else {
            throw InputRegistryError.duplicateInput(input.id)
        }
        inputs[input.id] = input
    }

    /// The input with the given identifier, if one is registered.
    public func input(withID id: InputID) -> (any Input)? {
        inputs[id]
    }

    /// Every registered input, for input discovery. Order is not defined
    /// here; discovery output sorts for presentation.
    public var allInputs: [any Input] {
        Array(inputs.values)
    }
}

/// The registry is the concrete `InputRegistering` seam the host hands
/// plug-ins through `PlugInContext.inputs`.
extension InputRegistry: InputRegistering {}
