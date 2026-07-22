//
//  RecordingPlugInTests.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraRecordingPlugIns

/// A no-op input registration seam — the recording plug-in never registers
/// inputs.
private struct UnusedInputRegistrar: InputRegistering {
    /// Never called by this plug-in.
    func register(_ input: any Input) async throws {}

    /// Never called by this plug-in.
    func unregister(_ id: InputID) async {}
}

/// A no-op effect registration seam — the recording plug-in never registers
/// effects.
private struct UnusedEffectRegistrar: EffectRegistering {
    /// Never called by this plug-in.
    func register(_ provider: any AudioEffectProvider) async throws {}

    /// Never called by this plug-in.
    func register(_ provider: any VideoEffectProvider) async throws {}
}

/// A no-op tool registration seam — the recording plug-in never registers
/// tools.
private struct UnusedToolRegistrar: ToolRegistering {
    /// Never called by this plug-in.
    func register(_ tool: any Tool) async throws {}
}

/// A fixed clock for contexts that never read time.
private struct FixedClock: EngineClock {
    /// Always zero.
    var now: CMTime { .zero }

    /// Never ticks.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { $0.finish() }
    }
}

/// Collects what a plug-in registers through the output seam, standing in
/// for the host's registry.
private final class RecordingOutputs: OutputRegistering, Sendable {
    /// The recording providers registered, in order.
    let recordingProviders = Mutex<[any RecordingServiceProvider]>([])

    /// Streaming registration is unused here; recording only.
    func register(_ provider: any StreamingServiceProvider) async throws {}

    /// Captures a registered recording provider.
    func register(_ provider: any RecordingServiceProvider) async throws {
        recordingProviders.withLock { $0.append(provider) }
    }
}

@Suite("RecordingPlugIn")
struct RecordingPlugInTests {
    @Test("The provider serves .mov and .mp4 with a stable identifier")
    func providerIdentity() {
        let provider = AVAssetWriterRecordingServiceProvider()
        #expect(provider.id == OutputID(rawValue: "file"))
        #expect(provider.fileExtensions == ["mov", "mp4"])
    }

    @Test("The provider makes a recording service")
    func providerMakesService() {
        let provider = AVAssetWriterRecordingServiceProvider()
        let service = provider.makeRecordingService(configuration: StreamConfiguration())
        #expect(service is AVAssetWriterRecordingService)
    }

    @Test("Activating the plug-in registers the recording provider")
    func activateRegistersProvider() async throws {
        let outputs = RecordingOutputs()
        let context = PlugInContext(
            eventBus: EventBus(),
            clock: FixedClock(),
            inputs: UnusedInputRegistrar(),
            outputs: outputs,
            effects: UnusedEffectRegistrar(),
            tools: UnusedToolRegistrar()
        )
        try await RecordingPlugIn().activate(in: context)
        let registered = outputs.recordingProviders.withLock { $0 }
        #expect(registered.count == 1)
        #expect(registered.first?.id == OutputID(rawValue: "file"))
    }

    @Test("The plug-in carries its stable reverse-DNS identifier")
    func plugInIdentifier() {
        let plugIn = RecordingPlugIn()
        #expect(plugIn.id == PlugInID(rawValue: "com.moonwink.tingra.recording.avassetwriter"))
        #expect(plugIn.name == "Local Recording")
    }
}
