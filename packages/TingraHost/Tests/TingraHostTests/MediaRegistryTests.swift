//
//  MediaRegistryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit
import UniformTypeIdentifiers

@testable import TingraHost

/// A provider opening one family of content types, for the registry tests.
private struct StubProvider: MediaInputProvider {
    let id: MediaProviderID
    let name: String
    let contentTypes: [UTType]

    init(_ id: String, _ contentTypes: [UTType]) {
        self.id = MediaProviderID(rawValue: id)
        self.name = id
        self.contentTypes = contentTypes
    }

    func makeInput(for url: URL, id: InputID) throws -> any Input {
        StubMediaInput(id: id, name: url.lastPathComponent, provider: self.id)
    }
}

/// The input a stub provider vends, remembering which provider made it.
private struct StubMediaInput: Input {
    let id: InputID
    let name: String
    let provider: MediaProviderID
    let kind = InputKind.media
    let media = InputMedia.video
    func start() async throws {}
    func stop() async {}
}

@Suite("MediaRegistry")
struct MediaRegistryTests {
    @Test("A registered provider resolves by any content type conforming to one it declares")
    func resolvesByConformance() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("images", [.image]))
        #expect(await registry.provider(for: UTType.png)?.id == MediaProviderID(rawValue: "images"))
        #expect(await registry.provider(for: UTType.jpeg)?.id == MediaProviderID(rawValue: "images"))
        #expect(await registry.provider(for: UTType.image)?.id == MediaProviderID(rawValue: "images"))
    }

    @Test("A content type no provider declares resolves to nil")
    func unknownTypeResolvesToNil() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("images", [.image]))
        #expect(await registry.provider(for: UTType.plainText) == nil)
        #expect(await registry.provider(for: UTType.movie) == nil)
    }

    @Test("A file resolves through its extension when it does not exist on disk")
    func resolvesAbsentFileByExtension() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("images", [.image]))
        try await registry.register(StubProvider("text", [.plainText]))
        let missing = URL(filePath: "/nonexistent/tingra-media-test/slide.PNG")
        #expect(await registry.provider(for: missing)?.id == MediaProviderID(rawValue: "images"))
        // Markdown conforms to plain text, so a text provider opens it.
        #expect(
            await registry.provider(for: URL(filePath: "/nonexistent/notes.md"))?.id
                == MediaProviderID(rawValue: "text"))
        #expect(
            await registry.provider(for: URL(filePath: "/nonexistent/notes.txt"))?.id
                == MediaProviderID(rawValue: "text"))
        #expect(await registry.provider(for: URL(filePath: "/nonexistent/noextension")) == nil)
    }

    @Test("A file on disk resolves through the type the file system reports")
    func resolvesExistingFileByReportedType() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("text", [.plainText]))
        let folder = URL.temporaryDirectory.appending(path: "tingra-media-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: file)
        #expect(MediaRegistry.contentType(of: file)?.conforms(to: .plainText) == true)
        #expect(await registry.provider(for: file)?.id == MediaProviderID(rawValue: "text"))
    }

    @Test("Resolution consults providers in registration order, so the first declaring a family wins")
    func firstRegisteredWins() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("images", [.image]))
        try await registry.register(StubProvider("png-only", [.png]))
        #expect(await registry.provider(for: UTType.png)?.id == MediaProviderID(rawValue: "images"))
        #expect(await registry.allProviders.map(\.id.rawValue) == ["images", "png-only"])
    }

    @Test("The accepted content types are the union of every provider's, in order and without repeats")
    func acceptedContentTypes() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("images", [.image]))
        try await registry.register(StubProvider("docs", [.plainText, .image]))
        #expect(await registry.acceptedContentTypes == [.image, .plainText])
    }

    @Test("Unregistering removes the provider, and unregistering an unknown identifier does nothing")
    func unregisterRemovesProvider() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("images", [.image]))
        await registry.unregister(MediaProviderID(rawValue: "images"))
        #expect(await registry.provider(for: UTType.png) == nil)
        await registry.unregister(MediaProviderID(rawValue: "images"))
        #expect(await registry.allProviders.isEmpty)
        try await registry.register(StubProvider("images", [.image]))
        #expect(await registry.allProviders.count == 1)
    }

    @Test("Registering a second provider with the same identifier throws duplicateProvider")
    func duplicateProviderThrows() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("images", [.image]))
        await #expect(throws: MediaRegistryError.duplicateProvider(MediaProviderID(rawValue: "images"))) {
            try await registry.register(StubProvider("images", [.movie]))
        }
        #expect(await registry.allProviders.count == 1)
    }

    @Test("makeInput hands the file to the provider that opens it, with the given identifier")
    func makeInputUsesResolvedProvider() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("images", [.image]))
        let input = try await registry.makeInput(
            for: URL(filePath: "/nonexistent/poster.png"), id: InputID(rawValue: "media-1"))
        #expect(input.id == InputID(rawValue: "media-1"))
        #expect(input.kind == .media)
        #expect((input as? StubMediaInput)?.provider == MediaProviderID(rawValue: "images"))
    }

    @Test("makeInput throws unsupportedFile for a type no provider opens and notAFileURL for a remote URL")
    func makeInputErrors() async throws {
        let registry = MediaRegistry()
        try await registry.register(StubProvider("images", [.image]))
        let unsupported = URL(filePath: "/nonexistent/clip.mov")
        await #expect(throws: MediaRegistryError.unsupportedFile(unsupported)) {
            try await registry.makeInput(for: unsupported, id: InputID(rawValue: "m"))
        }
        let remote = try #require(URL(string: "https://example.com/poster.png"))
        await #expect(throws: MediaRegistryError.notAFileURL(remote)) {
            try await registry.makeInput(for: remote, id: InputID(rawValue: "m"))
        }
    }

    @Test("Registry errors describe the cause and the fix, and are equatable both ways")
    func errorDescriptions() {
        let url = URL(filePath: "/nonexistent/clip.mov")
        #expect(MediaRegistryError.duplicateProvider(MediaProviderID(rawValue: "x")).description.contains("'x'"))
        #expect(MediaRegistryError.unsupportedFile(url).description.contains("clip.mov"))
        #expect(MediaRegistryError.notAFileURL(url).description.contains("file URL"))
        #expect(MediaRegistryError.unsupportedFile(url) == .unsupportedFile(url))
        #expect(MediaRegistryError.unsupportedFile(url) != .notAFileURL(url))
    }

    @Test("The registry is the plug-in-facing media seam")
    func conformsToMediaRegistering() async throws {
        let seam: any MediaRegistering = MediaRegistry()
        try await seam.register(StubProvider("images", [.image]))
    }
}
