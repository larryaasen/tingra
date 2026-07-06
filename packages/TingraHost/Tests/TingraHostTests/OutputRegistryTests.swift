//
//  OutputRegistryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraPlugInKit

@testable import TingraHost

/// A minimal provider for registry tests.
private struct StubProvider: StreamingServiceProvider {
    /// The provider's identifier.
    let id: OutputID

    /// The provider's name.
    let name: String

    /// The schemes the provider serves.
    let schemes: [String]

    /// Creates a mock service; registry tests never start it.
    func makeStreamingService(configuration: StreamConfiguration) -> any StreamingService {
        MockStreamingService()
    }
}

/// A minimal recording provider for registry tests.
private struct StubRecordingProvider: RecordingServiceProvider {
    /// The provider's identifier.
    let id: OutputID

    /// The provider's name.
    let name: String

    /// The file extensions the provider serves.
    let fileExtensions: [String]

    /// Creates a mock service; registry tests never start it.
    func makeRecordingService(configuration: StreamConfiguration) -> any RecordingService {
        MockRecordingService()
    }
}

@Suite("OutputRegistry")
struct OutputRegistryTests {
    @Test("A registered provider resolves by each of its schemes, case-insensitively")
    func registeredProviderResolvesByScheme() async throws {
        let registry = OutputRegistry()
        let provider = StubProvider(id: OutputID(rawValue: "rtmp"), name: "RTMP", schemes: ["rtmp", "rtmps"])
        try await registry.register(provider)

        #expect(await registry.provider(forScheme: "rtmp")?.id == provider.id)
        #expect(await registry.provider(forScheme: "RTMPS")?.id == provider.id)
    }

    @Test("An unregistered scheme resolves to nil")
    func unknownSchemeResolvesToNil() async throws {
        let registry = OutputRegistry()
        try await registry.register(
            StubProvider(id: OutputID(rawValue: "rtmp"), name: "RTMP", schemes: ["rtmp"])
        )
        #expect(await registry.provider(forScheme: "srt") == nil)
    }

    @Test("Registering a second provider for a served scheme throws duplicateScheme")
    func duplicateSchemeThrows() async throws {
        let registry = OutputRegistry()
        try await registry.register(
            StubProvider(id: OutputID(rawValue: "rtmp"), name: "RTMP", schemes: ["rtmp", "rtmps"])
        )
        await #expect(throws: OutputRegistryError.duplicateScheme("rtmps", existing: OutputID(rawValue: "rtmp"))) {
            try await registry.register(
                StubProvider(id: OutputID(rawValue: "other"), name: "Other", schemes: ["rtmps"])
            )
        }
        // The rejected provider's schemes must not be partially registered.
        #expect(await registry.provider(forScheme: "rtmp")?.id == OutputID(rawValue: "rtmp"))
    }

    @Test("A rejected registration leaves none of the provider's schemes behind")
    func rejectedRegistrationIsAtomic() async throws {
        let registry = OutputRegistry()
        try await registry.register(
            StubProvider(id: OutputID(rawValue: "rtmp"), name: "RTMP", schemes: ["rtmp"])
        )
        // "srt" comes before the colliding "rtmp" in this provider's list;
        // the failed registration must not leave "srt" registered.
        await #expect(throws: OutputRegistryError.self) {
            try await registry.register(
                StubProvider(id: OutputID(rawValue: "multi"), name: "Multi", schemes: ["srt", "rtmp"])
            )
        }
        #expect(await registry.provider(forScheme: "srt") == nil)
    }

    @Test("Registry errors describe the collision and are equatable both ways")
    func errorDescriptionAndEquality() {
        let error = OutputRegistryError.duplicateScheme("rtmp", existing: OutputID(rawValue: "rtmp"))
        #expect(String(describing: error).contains("rtmp"))
        #expect(error == OutputRegistryError.duplicateScheme("rtmp", existing: OutputID(rawValue: "rtmp")))
        #expect(error != OutputRegistryError.duplicateScheme("rtmps", existing: OutputID(rawValue: "rtmp")))
    }

    @Test("A registered recording provider resolves by each of its extensions, case-insensitively")
    func recordingProviderResolvesByExtension() async throws {
        let registry = OutputRegistry()
        let provider = StubRecordingProvider(
            id: OutputID(rawValue: "file"), name: "File", fileExtensions: ["mov", "mp4"])
        try await registry.register(provider)

        #expect(await registry.recordingProvider(forFileExtension: "mov")?.id == provider.id)
        #expect(await registry.recordingProvider(forFileExtension: "MP4")?.id == provider.id)
        #expect(await registry.recordingProvider(forFileExtension: "mkv") == nil)
    }

    @Test("Streaming and recording providers share one registry without colliding")
    func streamingAndRecordingCoexist() async throws {
        let registry = OutputRegistry()
        try await registry.register(
            StubProvider(id: OutputID(rawValue: "rtmp"), name: "RTMP", schemes: ["rtmp"])
        )
        try await registry.register(
            StubRecordingProvider(id: OutputID(rawValue: "file"), name: "File", fileExtensions: ["mov"])
        )
        #expect(await registry.provider(forScheme: "rtmp")?.id == OutputID(rawValue: "rtmp"))
        #expect(await registry.recordingProvider(forFileExtension: "mov")?.id == OutputID(rawValue: "file"))
    }

    @Test("Registering a second recording provider for a served extension throws duplicateFileExtension")
    func duplicateFileExtensionThrows() async throws {
        let registry = OutputRegistry()
        try await registry.register(
            StubRecordingProvider(id: OutputID(rawValue: "file"), name: "File", fileExtensions: ["mov", "mp4"])
        )
        await #expect(
            throws: OutputRegistryError.duplicateFileExtension("mp4", existing: OutputID(rawValue: "file"))
        ) {
            try await registry.register(
                StubRecordingProvider(id: OutputID(rawValue: "other"), name: "Other", fileExtensions: ["mp4"])
            )
        }
    }
}
