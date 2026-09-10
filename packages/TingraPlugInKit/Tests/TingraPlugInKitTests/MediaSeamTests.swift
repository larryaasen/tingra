//
//  MediaSeamTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Testing
import TingraEventBus
import UniformTypeIdentifiers

@testable import TingraPlugInKit

/// A provider that opens images and vends a video-only input, for the seam
/// tests below.
private struct StubMediaProvider: MediaInputProvider {
    let id = MediaProviderID(rawValue: "test.image")
    let name = "Stub Image"
    let contentTypes: [UTType] = [.image]

    func makeInput(for url: URL, id: InputID) throws -> any Input {
        StubMediaInput(id: id, name: url.lastPathComponent)
    }
}

/// The input the stub provider vends.
private struct StubMediaInput: Input {
    let id: InputID
    let name: String
    let kind = InputKind.media
    let media = InputMedia.video
    func start() async throws {}
    func stop() async {}
}

/// A registry that remembers what was registered, standing in for the
/// host's, so a context test can tell it apart from the default.
private actor RecordingMediaRegistry: MediaRegistering {
    var registered: [MediaProviderID] = []
    func register(_ provider: any MediaInputProvider) async throws {
        registered.append(provider.id)
    }
    func unregister(_ id: MediaProviderID) async {
        registered.removeAll { $0 == id }
    }
}

/// A clock that never ticks, enough to construct a context.
private struct StoppedClock: EngineClock {
    var now: CMTime { .zero }
    func tick(every duration: CMTime) -> AsyncStream<CMTime> { AsyncStream { $0.finish() } }
}

/// Seam stand-ins that accept nothing, enough to construct a context.
private struct NoInputs: InputRegistering {
    func register(_ input: any Input) async throws {}
    func unregister(_ id: InputID) async {}
}
private struct NoOutputs: OutputRegistering {
    func register(_ provider: any StreamingServiceProvider) async throws {}
    func register(_ provider: any RecordingServiceProvider) async throws {}
}
private struct NoEffects: EffectRegistering {
    func register(_ provider: any AudioEffectProvider) async throws {}
    func register(_ provider: any VideoEffectProvider) async throws {}
}
private struct NoTools: ToolRegistering {
    func register(_ tool: any Tool) async throws {}
}

@Suite("Media seam")
struct MediaSeamTests {
    @Test("Media provider identifiers round-trip through Codable and compare by raw value")
    func providerIdentifierRoundTrip() throws {
        let id = MediaProviderID(rawValue: "com.moonwink.tingra.media.image")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(MediaProviderID.self, from: data)
        #expect(decoded == id)
        #expect(String(decoding: data, as: UTF8.self) == "\"com.moonwink.tingra.media.image\"")
        #expect(id != MediaProviderID(rawValue: "com.moonwink.tingra.media.movie"))
    }

    @Test("A media input reports the media kind and the identifier it was made with")
    func providerMakesInputWithGivenIdentifier() throws {
        let input = try StubMediaProvider().makeInput(
            for: URL(filePath: "/tmp/poster.png"), id: InputID(rawValue: "media-1"))
        #expect(input.id == InputID(rawValue: "media-1"))
        #expect(input.kind == .media)
        #expect(input.media == .video)
        #expect(input.name == "poster.png")
    }

    @Test("The unavailable registry throws registryUnavailable naming the provider, never discarding it")
    func unavailableRegistryThrows() async {
        await #expect(throws: MediaRegisteringError.registryUnavailable(MediaProviderID(rawValue: "test.image"))) {
            try await UnavailableMediaRegistry().register(StubMediaProvider())
        }
    }

    @Test("The registry-unavailable error describes the fix and is equatable both ways")
    func unavailableErrorDescription() {
        let error = MediaRegisteringError.registryUnavailable(MediaProviderID(rawValue: "test.image"))
        #expect(error.description.contains("test.image"))
        #expect(error.description.contains("PlugInContext"))
        #expect(error == .registryUnavailable(MediaProviderID(rawValue: "test.image")))
        #expect(error != .registryUnavailable(MediaProviderID(rawValue: "other")))
    }

    @Test("A context constructed without a media registry carries the unavailable one")
    func contextDefaultsToUnavailableMedia() async {
        let context = PlugInContext(
            eventBus: EventBus(), clock: StoppedClock(), inputs: NoInputs(), outputs: NoOutputs(),
            effects: NoEffects(), tools: NoTools())
        #expect(context.media is UnavailableMediaRegistry)
        await #expect(throws: MediaRegisteringError.self) {
            try await context.media.register(StubMediaProvider())
        }
    }

    @Test("A context constructed with a media registry hands registrations to it")
    func contextCarriesGivenMediaRegistry() async throws {
        let registry = RecordingMediaRegistry()
        let context = PlugInContext(
            eventBus: EventBus(), clock: StoppedClock(), inputs: NoInputs(), outputs: NoOutputs(),
            effects: NoEffects(), tools: NoTools(), media: registry)
        try await context.media.register(StubMediaProvider())
        #expect(await registry.registered == [MediaProviderID(rawValue: "test.image")])
        await context.media.unregister(MediaProviderID(rawValue: "test.image"))
        #expect(await registry.registered.isEmpty)
    }

    @Test("Unregistering through the unavailable registry is harmless")
    func unavailableRegistryUnregisterDoesNothing() async {
        await UnavailableMediaRegistry().unregister(MediaProviderID(rawValue: "test.image"))
    }

    @Test("The media kind is a distinct case with a stable raw value")
    func mediaKindRawValue() {
        #expect(InputKind.media.rawValue == "media")
        #expect(InputKind.allCases.contains(.media))
        #expect(InputKind.media != .generator)
    }
}
