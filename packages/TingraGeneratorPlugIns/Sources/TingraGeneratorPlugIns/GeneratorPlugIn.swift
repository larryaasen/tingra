//
//  GeneratorPlugIn.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The first party generator plug-in: contributes the SMPTE color bars,
/// alignment, and PLUGE calibration video generators, plus the 440 Hz tone
/// audio generator as inputs.
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
    public func activate(in context: PlugInContext) async throws {
        let generators: [any Input] = [
            BarsGenerator(clock: context.clock),
            AlignmentGenerator(clock: context.clock),
            PlugeGenerator(clock: context.clock),
            PlugeStrictGenerator(clock: context.clock),
            ToneGenerator(clock: context.clock),
        ]
        for generator in generators {
            try await context.inputs.register(generator)
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
    }
}
