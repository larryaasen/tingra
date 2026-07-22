//
//  EffectRegistryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import Testing
import TingraPlugInKit

@testable import TingraHost

/// A minimal audio effect that passes samples through unchanged.
private struct PassthroughAudioEffect: AudioEffect {
    /// Ignores every payload.
    func setParameters(_ parameters: [String: JSONValue]) {}

    /// Leaves the block unchanged.
    func process(_ channels: inout [[Float]], sampleRate: Double) {}
}

/// A stub audio effect provider with a configurable identity.
private struct StubAudioProvider: AudioEffectProvider {
    let id: EffectID
    let name: String

    /// Declares no parameters.
    var parameters: [EffectParameter] { [] }

    /// Creates a pass-through instance.
    func makeEffect(parameters: [String: JSONValue]) -> any AudioEffect {
        PassthroughAudioEffect()
    }
}

/// A minimal video effect that passes the image through unchanged.
private struct PassthroughVideoEffect: VideoEffect {
    /// Ignores every payload.
    func setParameters(_ parameters: [String: JSONValue]) {}

    /// Returns the input unchanged.
    func process(_ image: CIImage) -> CIImage { image }
}

/// A stub video effect provider with a configurable identity.
private struct StubVideoProvider: VideoEffectProvider {
    let id: EffectID
    let name: String

    /// Declares no parameters.
    var parameters: [EffectParameter] { [] }

    /// Creates a pass-through instance.
    func makeEffect(parameters: [String: JSONValue]) -> any VideoEffect {
        PassthroughVideoEffect()
    }
}

@Suite("EffectRegistry")
struct EffectRegistryTests {
    @Test("registered audio and video providers resolve by id")
    func registersAndResolvesProviders() async throws {
        let registry = EffectRegistry()
        try await registry.register(StubAudioProvider(id: EffectID(rawValue: "gain"), name: "Gain"))
        try await registry.register(StubVideoProvider(id: EffectID(rawValue: "blur"), name: "Blur"))

        #expect(await registry.audioProvider(withID: EffectID(rawValue: "gain"))?.name == "Gain")
        #expect(await registry.videoProvider(withID: EffectID(rawValue: "blur"))?.name == "Blur")
        #expect(await registry.audioProvider(withID: EffectID(rawValue: "blur")) == nil)
        #expect(await registry.videoProvider(withID: EffectID(rawValue: "gain")) == nil)
    }

    @Test("a duplicate audio effect id is rejected with a descriptive error")
    func duplicateAudioIDThrows() async throws {
        let registry = EffectRegistry()
        try await registry.register(StubAudioProvider(id: EffectID(rawValue: "gain"), name: "Gain"))
        await #expect(throws: EffectRegistryError.duplicateAudioEffect(EffectID(rawValue: "gain"))) {
            try await registry.register(StubAudioProvider(id: EffectID(rawValue: "gain"), name: "Other Gain"))
        }
    }

    @Test("a duplicate video effect id is rejected with a descriptive error")
    func duplicateVideoIDThrows() async throws {
        let registry = EffectRegistry()
        try await registry.register(StubVideoProvider(id: EffectID(rawValue: "blur"), name: "Blur"))
        await #expect(throws: EffectRegistryError.duplicateVideoEffect(EffectID(rawValue: "blur"))) {
            try await registry.register(StubVideoProvider(id: EffectID(rawValue: "blur"), name: "Other Blur"))
        }
    }

    @Test("an audio and a video effect may share an id without colliding")
    func mediaKindsHaveSeparateIDTables() async throws {
        let registry = EffectRegistry()
        try await registry.register(StubAudioProvider(id: EffectID(rawValue: "invert"), name: "Audio Invert"))
        try await registry.register(StubVideoProvider(id: EffectID(rawValue: "invert"), name: "Video Invert"))
        #expect(await registry.audioProvider(withID: EffectID(rawValue: "invert"))?.name == "Audio Invert")
        #expect(await registry.videoProvider(withID: EffectID(rawValue: "invert"))?.name == "Video Invert")
    }

    @Test("provider listings keep registration order for stable effect menus")
    func listingsKeepRegistrationOrder() async throws {
        let registry = EffectRegistry()
        try await registry.register(StubAudioProvider(id: EffectID(rawValue: "gain"), name: "Gain"))
        try await registry.register(StubAudioProvider(id: EffectID(rawValue: "highPass"), name: "High-Pass Filter"))
        try await registry.register(StubAudioProvider(id: EffectID(rawValue: "lowPass"), name: "Low-Pass Filter"))
        let listed = await registry.allAudioProviders
        #expect(listed.map(\.id.rawValue) == ["gain", "highPass", "lowPass"])
    }
}
