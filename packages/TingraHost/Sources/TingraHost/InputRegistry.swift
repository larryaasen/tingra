//
//  InputRegistry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
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

    /// The event bus, for reporting an input that declares no media.
    /// Optional so the many test and fixture sites that need no
    /// observability keep constructing a bare registry.
    private let eventBus: EventBus?

    /// Creates an empty registry. The host owns one per engine.
    ///
    /// - Parameter eventBus: The host's event bus, used only to report an
    ///   input registering with no declared media. Omit it where that
    ///   diagnostic is not wanted (tests, fixtures).
    public init(eventBus: EventBus? = nil) {
        self.eventBus = eventBus
    }

    /// Registers an input contributed by a plug-in.
    ///
    /// Throws ``InputRegistryError/duplicateInput(_:)`` if the identifier is
    /// already taken — a plug-in defect surfaces as a thrown error, never a
    /// trap (CLAUDE.md, never-crash rule).
    ///
    /// An input whose ``Input/media`` is empty registers *successfully* but
    /// is reported as an `error` event: it will be offered for no media role
    /// at all — no layer, no channel strip, no multiview tile — so it would
    /// otherwise vanish silently, which reads as a hang rather than a
    /// reported problem. Refusing it is deliberately not the behavior: a
    /// plug-in's omission must not cost the host a capability, and the input
    /// remains resolvable by identifier.
    public func register(_ input: any Input) throws {
        guard inputs[input.id] == nil else {
            throw InputRegistryError.duplicateInput(input.id)
        }
        inputs[input.id] = input
        if input.media.isEmpty {
            eventBus?.error(
                "input.noMedia",
                domain: .capture,
                params: [
                    "id": .string(input.id.rawValue),
                    "name": .string(input.name),
                    "kind": .string(input.kind.rawValue),
                    "message": .string(
                        "The input declares no media, so it will not be offered as a layer, "
                            + "a channel strip, or a multiview tile. The plug-in contributing it "
                            + "should declare `media` as .video, .audio, or both."
                    ),
                ]
            )
        }
    }

    /// Removes a previously registered input, keeping the registry current
    /// as devices disconnect. Removing an identifier that is not
    /// registered is harmless and does nothing — disconnection is a normal
    /// event, never an error.
    public func unregister(_ id: InputID) {
        inputs[id] = nil
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
