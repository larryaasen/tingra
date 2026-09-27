//
//  DestinationTemplateTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraPlugInKit

/// A streaming provider that declares no templates, standing in for any
/// provider written before the requirement joined the protocol.
private struct TemplatelessProvider: StreamingServiceProvider {
    let id = OutputID(rawValue: "templateless")
    let name = "Templateless"
    let schemes = ["plain"]

    func makeStreamingService(configuration: StreamConfiguration) -> any StreamingService {
        IdleService()
    }
}

/// A streaming provider that declares two templates, standing in for the
/// RTMP output.
private struct TemplatedProvider: StreamingServiceProvider {
    let id = OutputID(rawValue: "templated")
    let name = "Templated"
    let schemes = ["rtmp"]
    let destinationTemplates: [DestinationTemplate]

    func makeStreamingService(configuration: StreamConfiguration) -> any StreamingService {
        IdleService()
    }
}

/// A streaming service the tests never start.
private struct IdleService: StreamingService {
    var events: AsyncStream<StreamingServiceEvent> { AsyncStream { $0.finish() } }
    func start(to destination: Destination) async throws {}
    func send(video frame: CapturedFrame) async {}
    func send(audio buffer: CapturedAudio) async {}
    func statistics() async -> StreamingStatistics {
        StreamingStatistics(bytesSent: 0, bytesPerSecond: 0, framesPerSecond: 0)
    }
    func stop() async {}
}

@Suite("DestinationTemplate")
struct DestinationTemplateTests {
    /// A template the tests compare against.
    private static func template(
        id: String = "example",
        name: String = "Example",
        url: String = "rtmp://live.example.com/app",
        page: String? = "https://example.com/key"
    ) throws -> DestinationTemplate {
        DestinationTemplate(
            id: id,
            name: name,
            url: try #require(URL(string: url)),
            streamKeyPageURL: try page.map { try #require(URL(string: $0)) }
        )
    }

    @Test("a template keeps what it was created with")
    func storesItsFields() throws {
        let template = try Self.template()
        #expect(template.id == "example")
        #expect(template.name == "Example")
        #expect(template.url.absoluteString == "rtmp://live.example.com/app")
        #expect(template.streamKeyPageURL?.absoluteString == "https://example.com/key")
    }

    @Test("a template made without a stream-key page has none")
    func streamKeyPageDefaultsToNil() throws {
        let url = try #require(URL(string: "rtmp://live.example.com/app"))
        #expect(DestinationTemplate(id: "example", name: "Example", url: url).streamKeyPageURL == nil)
    }

    @Test("templates compare equal when every field matches")
    func equalWhenMatching() throws {
        #expect(try Self.template() == Self.template())
        #expect(try Set([Self.template(), Self.template()]).count == 1)
    }

    @Test("templates compare unequal when any field differs")
    func unequalWhenAnyFieldDiffers() throws {
        let base = try Self.template()
        #expect(try base != Self.template(id: "other"))
        #expect(try base != Self.template(name: "Other"))
        #expect(try base != Self.template(url: "rtmps://live.example.com/app"))
        #expect(try base != Self.template(page: nil))
    }

    @Test("a streaming provider offers no templates unless it declares some")
    func providerDefaultsToNone() {
        #expect(TemplatelessProvider().destinationTemplates.isEmpty)
    }

    @Test("a streaming provider's declared templates are reported in order")
    func providerReportsDeclaredTemplates() throws {
        let first = try Self.template(id: "first", name: "First")
        let second = try Self.template(id: "second", name: "Second")
        let provider = TemplatedProvider(destinationTemplates: [first, second])
        #expect(provider.destinationTemplates.map(\.id) == ["first", "second"])
    }
}
