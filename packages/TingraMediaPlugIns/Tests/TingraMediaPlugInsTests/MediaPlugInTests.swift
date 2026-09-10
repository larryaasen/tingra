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

@Suite("MediaPlugIn")
struct MediaPlugInTests {
    /// A context over the given media registry.
    private func context(media: any MediaRegistering) -> PlugInContext {
        PlugInContext(
            eventBus: EventBus(), clock: SyntheticClock(), inputs: NoInputs(), outputs: NoOutputs(),
            effects: NoEffects(), tools: NoTools(), media: media)
    }

    @Test("Activation registers the image, movie, and text providers, in that order")
    func activationRegistersProviders() async throws {
        let registry = RecordingMediaRegistry()
        let plugIn = MediaPlugIn()
        #expect(plugIn.id == MediaPlugIn.plugInID)
        #expect(plugIn.name == "Media")
        try await plugIn.activate(in: context(media: registry))
        #expect(
            await registry.registered == [
                ImageMediaProvider.providerID, MovieMediaProvider.providerID, TextMediaProvider.providerID,
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
