//
//  GeneratorOptionAgreementTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus
import TingraGeneratorPlugIns
import TingraHost
import TingraPlugInKit

@testable import TingraCLI

/// A no-op output registration seam — the generator plug-in registers none.
private struct UnusedOutputRegistrar: OutputRegistering {
    /// Never called by this plug-in.
    func register(_ provider: any StreamingServiceProvider) async throws {}

    /// Never called by this plug-in.
    func register(_ provider: any RecordingServiceProvider) async throws {}
}

/// A no-op effect registration seam — the generator plug-in registers none.
private struct UnusedEffectRegistrar: EffectRegistering {
    /// Never called by this plug-in.
    func register(_ provider: any AudioEffectProvider) async throws {}

    /// Never called by this plug-in.
    func register(_ provider: any VideoEffectProvider) async throws {}
}

/// A no-op tool registration seam — the generator plug-in registers none.
private struct UnusedToolRegistrar: ToolRegistering {
    /// Never called by this plug-in.
    func register(_ tool: any Tool) async throws {}
}

/// The generators the first-party plug-in actually contributes, keyed by
/// the identifier the CLI's `--video-generator`/`--audio-generator` values
/// resolve against.
private func registeredGenerators() async throws -> [String: any Input] {
    let registry = InputRegistry()
    let context = PlugInContext(
        eventBus: EventBus(),
        clock: HostClock(),
        inputs: registry,
        outputs: UnusedOutputRegistrar(),
        effects: UnusedEffectRegistrar(),
        tools: UnusedToolRegistrar()
    )
    try await GeneratorPlugIn().activate(in: context)
    let inputs = await registry.allInputs
    return Dictionary(uniqueKeysWithValues: inputs.map { ($0.id.rawValue, $0) })
}

/// `VideoGeneratorKind` and `AudioGeneratorKind` hand-duplicate the
/// generator roster so `--help` can list the accepted values and the parser
/// can validate them at compile time (CLI.md, "Input selection"). That
/// duplication was previously uncheckable: `InputKind.generator` says
/// nothing about whether a generator produces video or audio. With
/// ``InputMedia`` on the `Input` seam it is checkable, so drift is caught
/// here rather than in a stream (ARCHITECTURE.md, "The `Input` media
/// capability").
@Suite("Generator option/registry agreement")
struct GeneratorOptionAgreementTests {
    @Test("every --video-generator value names a registered generator producing video")
    func videoOptionsProduceVideo() async throws {
        let generators = try await registeredGenerators()

        for kind in VideoGeneratorKind.allCases {
            let input = try #require(
                generators[kind.rawValue],
                "--video-generator \(kind.rawValue) names no registered generator"
            )
            #expect(
                input.media.contains(.video),
                "--video-generator \(kind.rawValue) resolves an input that produces no video"
            )
        }
    }

    @Test("every --audio-generator value names a registered generator producing audio")
    func audioOptionsProduceAudio() async throws {
        let generators = try await registeredGenerators()

        for kind in AudioGeneratorKind.allCases {
            let input = try #require(
                generators[kind.rawValue],
                "--audio-generator \(kind.rawValue) names no registered generator"
            )
            #expect(
                input.media.contains(.audio),
                "--audio-generator \(kind.rawValue) resolves an input that produces no audio"
            )
        }
    }

    @Test("every registered video generator is offered by --video-generator")
    func everyVideoGeneratorIsOffered() async throws {
        let generators = try await registeredGenerators()
        let offered = Set(VideoGeneratorKind.allCases.map(\.rawValue))

        // The other direction: adding a video generator to the plug-in
        // without adding its case here would leave it unreachable from the
        // CLI, which is exactly the drift the hand-synced enums risk.
        for (id, input) in generators where input.media.contains(.video) {
            #expect(offered.contains(id), "the '\(id)' generator produces video but --video-generator omits it")
        }
    }

    @Test("every registered audio generator is offered by --audio-generator")
    func everyAudioGeneratorIsOffered() async throws {
        let generators = try await registeredGenerators()
        let offered = Set(AudioGeneratorKind.allCases.map(\.rawValue))

        for (id, input) in generators where input.media.contains(.audio) {
            #expect(offered.contains(id), "the '\(id)' generator produces audio but --audio-generator omits it")
        }
    }
}
