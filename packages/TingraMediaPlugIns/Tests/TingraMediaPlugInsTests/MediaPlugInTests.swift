//
//  MediaPlugInTests.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraMediaPlugIns

/// A media registry that remembers registrations and can refuse one, for
/// the activation tests.
private actor RecordingMediaRegistry: MediaRegistering {
    var registered: [MediaProviderID] = []
    let refusing: MediaProviderID?

    init(refusing: MediaProviderID? = nil) {
        self.refusing = refusing
    }

    func register(_ provider: any MediaInputProvider) async throws {
        if provider.id == refusing { throw MediaRegisteringError.registryUnavailable(provider.id) }
        registered.append(provider.id)
    }

    func unregister(_ id: MediaProviderID) async {
        registered.removeAll { $0 == id }
    }
}

/// Seam stand-ins the plug-in never touches.
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

// A hung test fails by name after a minute instead of holding a CI runner
// until the job times out with nothing in its log; the suite runs in
// well under a second.
@Suite("MediaPlugIn", .timeLimit(.minutes(1)))
struct MediaPlugInTests {
    /// A context over the given media registry.
    private func context(media: any MediaRegistering) -> PlugInContext {
        PlugInContext(
            eventBus: EventBus(), clock: SyntheticClock(), inputs: NoInputs(), outputs: NoOutputs(),
            effects: NoEffects(), tools: NoTools(), media: media)
    }

    @Test("Activation registers the image, movie, audio, and text providers, in that order")
    func activationRegistersProviders() async throws {
        let registry = RecordingMediaRegistry()
        let plugIn = MediaPlugIn()
        #expect(plugIn.id == MediaPlugIn.plugInID)
        #expect(plugIn.name == "Media")
        try await plugIn.activate(in: context(media: registry))
        #expect(
            await registry.registered == [
                ImageMediaProvider.providerID, MovieMediaProvider.providerID, AudioMediaProvider.providerID,
                TextMediaProvider.providerID,
            ])
    }

    @Test("A refused registration rolls back the providers registered before it and rethrows")
    func activationRollsBack() async throws {
        let registry = RecordingMediaRegistry(refusing: MovieMediaProvider.providerID)
        await #expect(throws: MediaRegisteringError.self) {
            try await MediaPlugIn().activate(in: context(media: registry))
        }
        #expect(await registry.registered.isEmpty)
    }

    @Test("A refused audio provider rolls back the image and movie providers registered before it")
    func activationRollsBackFromTheAudioProvider() async throws {
        let registry = RecordingMediaRegistry(refusing: AudioMediaProvider.providerID)
        await #expect(throws: MediaRegisteringError.registryUnavailable(AudioMediaProvider.providerID)) {
            try await MediaPlugIn().activate(in: context(media: registry))
        }
        #expect(await registry.registered.isEmpty)
    }

    @Test("Activating into a host without a media registry throws registryUnavailable rather than registering silently")
    func activationWithoutRegistryThrows() async {
        let context = PlugInContext(
            eventBus: EventBus(), clock: SyntheticClock(), inputs: NoInputs(), outputs: NoOutputs(),
            effects: NoEffects(), tools: NoTools())
        await #expect(throws: MediaRegisteringError.registryUnavailable(ImageMediaProvider.providerID)) {
            try await MediaPlugIn().activate(in: context)
        }
    }
}
