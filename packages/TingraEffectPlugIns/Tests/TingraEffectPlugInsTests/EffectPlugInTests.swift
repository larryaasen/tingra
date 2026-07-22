//
//  EffectPlugInTests.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraEffectPlugIns

/// Records the effect providers a plug-in registers.
private final class MockEffectRegistrar: EffectRegistering {
    /// The registered audio providers, in registration order.
    let audioProviders = Mutex<[any AudioEffectProvider]>([])

    /// The registered video providers, in registration order.
    let videoProviders = Mutex<[any VideoEffectProvider]>([])

    /// Records an audio provider.
    func register(_ provider: any AudioEffectProvider) async throws {
        audioProviders.withLock { $0.append(provider) }
    }

    /// Records a video provider.
    func register(_ provider: any VideoEffectProvider) async throws {
        videoProviders.withLock { $0.append(provider) }
    }
}

/// A no-op input registration seam — the effect plug-in never registers
/// inputs.
private struct UnusedInputRegistrar: InputRegistering {
    /// Never called by this plug-in.
    func register(_ input: any Input) async throws {}

    /// Never called by this plug-in.
    func unregister(_ id: InputID) async {}
}

/// A no-op output registration seam — the effect plug-in never registers
/// outputs.
private struct UnusedOutputRegistrar: OutputRegistering {
    /// Never called by this plug-in.
    func register(_ provider: any StreamingServiceProvider) async throws {}

    /// Never called by this plug-in.
    func register(_ provider: any RecordingServiceProvider) async throws {}
}

/// A no-op tool registration seam — the effect plug-in never registers
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

@Suite("EffectPlugIn")
struct EffectPlugInTests {
    @Test("activation registers the built-in audio effects with their stable identifiers")
    func activationRegistersAudioEffects() async throws {
        let registrar = MockEffectRegistrar()
        let context = PlugInContext(
            eventBus: EventBus(),
            clock: FixedClock(),
            inputs: UnusedInputRegistrar(),
            outputs: UnusedOutputRegistrar(),
            effects: registrar,
            tools: UnusedToolRegistrar()
        )

        try await EffectPlugIn().activate(in: context)

        let registered = registrar.audioProviders.withLock { $0 }
        #expect(
            registered.map(\.id) == [
                GainEffectProvider.effectID,
                HighPassEffectProvider.effectID,
                LowPassEffectProvider.effectID,
            ])
        #expect(registered.map(\.id.rawValue) == ["gain", "highPass", "lowPass"])

        let video = registrar.videoProviders.withLock { $0 }
        #expect(
            video.map(\.id) == [
                ColorAdjustEffectProvider.effectID,
                BlurEffectProvider.effectID,
            ])
        #expect(video.map(\.id.rawValue) == ["colorAdjust", "blur"])
    }

    @Test("every built-in effect declares its parameters for the host's generic controls")
    func providersDeclareParameters() {
        let gain = GainEffectProvider().parameters
        #expect(gain.map(\.key) == ["gainDecibels"])
        #expect(gain.first?.defaultValue == 0)
        #expect(gain.first?.unit == "dB")

        let highPass = HighPassEffectProvider().parameters
        #expect(highPass.map(\.key) == ["cutoffHertz"])
        #expect(highPass.first?.defaultValue == 80)
        #expect(highPass.first?.scale == .logarithmic)

        let lowPass = LowPassEffectProvider().parameters
        #expect(lowPass.map(\.key) == ["cutoffHertz"])
        #expect(lowPass.first?.defaultValue == 12000)
        #expect(lowPass.first?.scale == .logarithmic)

        let colorAdjust = ColorAdjustEffectProvider().parameters
        #expect(colorAdjust.map(\.key) == ["brightness", "contrast", "saturation"])
        // Every video parameter is neutral at its default, so a freshly
        // added effect never changes the picture until it is adjusted.
        #expect(colorAdjust.map(\.defaultValue) == [0, 1, 1])

        let blur = BlurEffectProvider().parameters
        #expect(blur.map(\.key) == ["radiusPixels"])
        #expect(blur.first?.defaultValue == 0)
        #expect(blur.first?.unit == "px")
    }
}
