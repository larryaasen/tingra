//
//  HaishinKitOutputPlugInTests.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraOutputPlugIns

/// A recording output registration seam, standing in for the host's
/// registry.
private final class RecordingOutputRegistry: OutputRegistering {
    /// The providers registered through the seam.
    private let providers = Mutex<[any StreamingServiceProvider]>([])

    /// Registers by recording.
    func register(_ provider: any StreamingServiceProvider) async throws {
        providers.withLock { $0.append(provider) }
    }

    /// The streaming output plug-in never registers a recording provider.
    func register(_ provider: any RecordingServiceProvider) async throws {}

    /// The recorded providers.
    var registered: [any StreamingServiceProvider] {
        providers.withLock { $0 }
    }
}

/// A no-op input registration seam for contexts that never register inputs.
private struct UnusedInputRegistry: InputRegistering {
    /// Never called in these tests.
    func register(_ input: any Input) async throws {}

    /// Never called in these tests.
    func unregister(_ id: InputID) async {}
}

/// A no-op tool registration seam for contexts that never register tools.
private struct UnusedToolRegistrar: ToolRegistering {
    /// Never called in these tests.
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

/// Tests for the output plug-in's registration path.
struct HaishinKitOutputPlugInTests {
    @Test("Activation registers the RTMP provider serving rtmp and rtmps")
    func activationRegistersProvider() async throws {
        let registry = RecordingOutputRegistry()
        let context = PlugInContext(
            eventBus: EventBus(),
            clock: FixedClock(),
            inputs: UnusedInputRegistry(),
            outputs: registry,
            tools: UnusedToolRegistrar()
        )
        try await HaishinKitOutputPlugIn().activate(in: context)

        let providers = registry.registered
        #expect(providers.count == 1)
        let provider = try #require(providers.first)
        #expect(provider.id == OutputID(rawValue: "rtmp"))
        #expect(provider.schemes == ["rtmp", "rtmps"])
    }

    @Test("The provider creates a fresh service per stream")
    func providerCreatesFreshServices() throws {
        let provider = RTMPStreamingServiceProvider()
        let first = try #require(
            provider.makeStreamingService(configuration: StreamConfiguration()) as? HaishinKitStreamingService
        )
        let second = try #require(
            provider.makeStreamingService(configuration: StreamConfiguration()) as? HaishinKitStreamingService
        )
        #expect(first !== second)
    }
}
