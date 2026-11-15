//
//  MonitorOverlayRegistryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import Testing
import TingraPlugInKit

@testable import TingraHost

/// An overlay that returns the picture unchanged.
private struct PassthroughOverlay: MonitorOverlay {
    /// Ignores every payload.
    mutating func setParameters(_ parameters: [String: JSONValue]) {}

    /// Returns the picture unchanged.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        picture
    }
}

/// A stub provider with a configurable identity.
private struct StubOverlayProvider: MonitorOverlayProvider {
    /// The provider's identifier.
    let id: MonitorOverlayID

    /// The provider's name.
    let name: String

    /// A guide.
    let stage = MonitorOverlayStage.guide

    /// Makes a pass-through overlay.
    func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        PassthroughOverlay()
    }
}

@Suite("MonitorOverlayRegistry")
struct MonitorOverlayRegistryTests {
    @Test("A registered provider is found by id and listed in registration order")
    func registersAndLists() async throws {
        let registry = MonitorOverlayRegistry()
        try await registry.register(StubOverlayProvider(id: MonitorOverlayID(rawValue: "b"), name: "B"))
        try await registry.register(StubOverlayProvider(id: MonitorOverlayID(rawValue: "a"), name: "A"))
        #expect(await registry.allProviders.map(\.id.rawValue) == ["b", "a"])
        #expect(await registry.provider(withID: MonitorOverlayID(rawValue: "a"))?.name == "A")
    }

    @Test("An unknown id finds no provider, and an empty registry lists none")
    func unknownIDFindsNothing() async {
        let registry = MonitorOverlayRegistry()
        #expect(await registry.provider(withID: MonitorOverlayID(rawValue: "missing")) == nil)
        #expect(await registry.allProviders.isEmpty)
    }

    @Test("A second provider with the same id throws duplicateOverlay and leaves the first in place")
    func duplicateThrows() async throws {
        let registry = MonitorOverlayRegistry()
        let id = MonitorOverlayID(rawValue: "titleSafe")
        try await registry.register(StubOverlayProvider(id: id, name: "First"))
        await #expect(throws: MonitorOverlayRegistryError.duplicateOverlay(id)) {
            try await registry.register(StubOverlayProvider(id: id, name: "Second"))
        }
        #expect(await registry.allProviders.map(\.name) == ["First"])
    }

    @Test("Registering through the seam reaches the registry")
    func registersThroughSeam() async throws {
        let registry = MonitorOverlayRegistry()
        let seam: any MonitorOverlayRegistering = registry
        try await seam.register(StubOverlayProvider(id: MonitorOverlayID(rawValue: "seam"), name: "Seam"))
        #expect(await registry.allProviders.count == 1)
    }

    @Test("The duplicate error names the id and the fix, and compares by id")
    func errorDescription() {
        let error = MonitorOverlayRegistryError.duplicateOverlay(MonitorOverlayID(rawValue: "titleSafe"))
        #expect(error.description.contains("'titleSafe'"))
        #expect(error.description.contains("prefix ids with their own domain"))
        #expect(error == .duplicateOverlay(MonitorOverlayID(rawValue: "titleSafe")))
        #expect(error != .duplicateOverlay(MonitorOverlayID(rawValue: "actionSafe")))
    }
}
