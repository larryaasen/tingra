//
//  GeneratorPlugIn.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraPlugInKit

/// The first party generator plug-in: contributes the SMPTE color bars,
/// alignment, PLUGE calibration, and black video generators, plus the 440 Hz
/// tone audio generator as inputs.
///
/// Generators synthesize their content from the injected clock, so they run
/// anywhere — no camera, no microphone, no TCC authorization. They are the
/// permanent CI test surface (`--video-generator bars`,
/// `--audio-generator tone`; see CLI.md) and the reason full pipeline tests
/// need no hardware.
public struct GeneratorPlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.generators")

    /// The plug-in's user-facing name.
    public let name = "Generators"

    /// Creates the plug-in.
    public init() {}

    /// Registers the built-in generators, reporting each registration as a
    /// `trace` event.
    ///
    /// Throws if the registry rejects an input (a duplicate identifier);
    /// the host's loader reports that as an `error` event and the engine
    /// keeps running.
    ///
    /// **Registration is all or nothing.** A rejection partway through the
    /// list used to leave the generators registered before it in the registry
    /// while the ones after it were never attempted — a half-activated
    /// plug-in, silently, since the throw the loader reports says nothing
    /// about what did land. The already-registered ones are now removed
    /// before the error propagates, so a plug-in that cannot activate leaves
    /// the registry exactly as it found it.
    public func activate(in context: PlugInContext) async throws {
        let generators: [any Input] = [
            BarsGenerator(clock: context.clock, eventBus: context.eventBus),
            AlignmentGenerator(clock: context.clock, eventBus: context.eventBus),
            PlugeGenerator(clock: context.clock, eventBus: context.eventBus),
            PlugeStrictGenerator(clock: context.clock, eventBus: context.eventBus),
            BlackGenerator(clock: context.clock, eventBus: context.eventBus),
            ToneGenerator(clock: context.clock, eventBus: context.eventBus),
        ]
        var registered: [InputID] = []
        do {
            for generator in generators {
                try await context.inputs.register(generator)
                registered.append(generator.id)
                context.eventBus.trace(
                    "input.registered",
                    domain: .capture,
                    params: [
                        "id": .string(generator.id.rawValue),
                        "name": .string(generator.name),
                        "kind": .string(generator.kind.rawValue),
                    ]
                )
            }
        } catch {
            // Unregistering is non-throwing and removing an identifier that
            // is not registered is harmless (InputRegistering), so rollback
            // cannot itself fail and mask the original error.
            for id in registered.reversed() {
                await context.inputs.unregister(id)
            }
            context.eventBus.trace(
                "input.registrationRolledBack",
                domain: .capture,
                params: [
                    "removed": .int(registered.count),
                    "reason": .string(String(describing: error)),
                ]
            )
            throw error
        }
    }
}
