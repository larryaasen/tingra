//
//  OutputRegistryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
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

    /// The destination templates the provider contributes (none by default).
    var destinationTemplates: [DestinationTemplate] = []

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

    // MARK: - Destination templates

    /// A template for the registry tests.
    ///
    /// - Parameters:
    ///   - id: The template's identifier.
    ///   - name: The service's name.
    ///   - url: The template's URL.
    /// - Returns: The template.
    private static func template(id: String, name: String, url: String) throws -> DestinationTemplate {
        DestinationTemplate(id: id, name: name, url: try #require(URL(string: url)))
    }

    @Test("An empty registry offers no destination templates")
    func emptyRegistryOffersNoTemplates() async {
        #expect(await OutputRegistry().destinationTemplates.isEmpty)
    }

    @Test("Templates from every provider are listed by name, each provider once however many schemes it serves")
    func templatesListedByNameOncePerProvider() async throws {
        let registry = OutputRegistry()
        try await registry.register(
            StubProvider(
                id: OutputID(rawValue: "rtmp"), name: "RTMP", schemes: ["rtmp", "rtmps"],
                destinationTemplates: [
                    try Self.template(id: "youtube", name: "YouTube", url: "rtmps://a.example.com/live2"),
                    try Self.template(id: "twitch", name: "Twitch", url: "rtmp://live.example.tv/app"),
                ]
            )
        )
        try await registry.register(
            StubProvider(
                id: OutputID(rawValue: "srt"), name: "SRT", schemes: ["srt"],
                destinationTemplates: [
                    try Self.template(id: "relay", name: "relay", url: "srt://relay.example.com:9000")
                ]
            )
        )
        #expect(await registry.destinationTemplates.map(\.id) == ["relay", "twitch", "youtube"])
    }

    @Test("Templates with the same name list in URL order, so the order never depends on registration")
    func sameNamedTemplatesOrderByURL() async throws {
        let registry = OutputRegistry()
        try await registry.register(
            StubProvider(
                id: OutputID(rawValue: "srt"), name: "SRT", schemes: ["srt"],
                destinationTemplates: [try Self.template(id: "b", name: "Service", url: "srt://service.example.com")]
            )
        )
        try await registry.register(
            StubProvider(
                id: OutputID(rawValue: "rtmp"), name: "RTMP", schemes: ["rtmp"],
                destinationTemplates: [try Self.template(id: "a", name: "Service", url: "rtmp://service.example.com")]
            )
        )
        #expect(await registry.destinationTemplates.map(\.id) == ["a", "b"])
    }

    @Test("A template's scheme matches the provider's schemes case-insensitively")
    func templateSchemeMatchesCaseInsensitively() async throws {
        let registry = OutputRegistry()
        try await registry.register(
            StubProvider(
                id: OutputID(rawValue: "rtmp"), name: "RTMP", schemes: ["rtmp"],
                destinationTemplates: [try Self.template(id: "loud", name: "Loud", url: "RTMP://live.example.tv/app")]
            )
        )
        #expect(await registry.destinationTemplates.map(\.id) == ["loud"])
    }

    @Test("A template on a scheme its provider does not serve throws templateSchemeNotServed and registers nothing")
    func unservedTemplateSchemeThrows() async throws {
        let registry = OutputRegistry()
        await #expect(
            throws: OutputRegistryError.templateSchemeNotServed(
                templateID: "stray", scheme: "srt", provider: OutputID(rawValue: "rtmp"))
        ) {
            try await registry.register(
                StubProvider(
                    id: OutputID(rawValue: "rtmp"), name: "RTMP", schemes: ["rtmp"],
                    destinationTemplates: [
                        try Self.template(id: "stray", name: "Stray", url: "srt://relay.example.com")
                    ]
                )
            )
        }
        #expect(await registry.provider(forScheme: "rtmp") == nil)
        #expect(await registry.destinationTemplates.isEmpty)
    }

    @Test("The unserved-template error names the template and scheme and is equatable both ways")
    func templateErrorDescriptionAndEquality() {
        let error = OutputRegistryError.templateSchemeNotServed(
            templateID: "stray", scheme: "srt", provider: OutputID(rawValue: "rtmp"))
        let description = String(describing: error)
        #expect(description.contains("stray"))
        #expect(description.contains("srt"))
        #expect(
            error
                == OutputRegistryError.templateSchemeNotServed(
                    templateID: "stray", scheme: "srt", provider: OutputID(rawValue: "rtmp")))
        #expect(
            error
                != OutputRegistryError.templateSchemeNotServed(
                    templateID: "other", scheme: "srt", provider: OutputID(rawValue: "rtmp")))
    }
}
