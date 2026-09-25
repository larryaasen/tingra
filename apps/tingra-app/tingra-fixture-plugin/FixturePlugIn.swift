//
//  FixturePlugIn.swift
//  tingra-fixture-plugin
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraPlugInKit

/// The fixture host-tier plug-in bundle: the smallest real
/// `FixturePlugIn.tingraplugin`, built for the app's tests and never embedded
/// in the shipping app (PLUGINS.md, Decision 27).
///
/// It is compiled apart from the app and links the kit without embedding it,
/// exactly as a third-party bundle does, so the app's test target can load
/// it through the production ``PlugInBundleLoader`` and prove what fakes
/// cannot: that the principal class casts to the host's `BundledPlugIn`, and
/// that what it registers is accepted by the host's registries — one copy of
/// the kit's types on both sides of the boundary.
final class FixturePlugIn: BundledPlugIn {
    /// The id the bundle's Info.plist also declares.
    let id = PlugInID(rawValue: "com.moonwink.tingra.fixture")

    /// The display name.
    let name = "Fixture"

    /// Creates the plug-in; the loader calls this once.
    init() {}

    /// Registers the one input the fixture contributes and reports that it
    /// ran, on the host's own bus.
    func activate(in context: PlugInContext) async throws {
        try await context.inputs.register(FixtureInput())
        context.eventBus.trace("fixture.activated", domain: .plugIn, params: ["id": .string(id.rawValue)])
    }
}

/// The fixture's input: a generator that delivers no frames. Its only job is
/// to cross the boundary into the host's `InputRegistry`.
struct FixtureInput: Input {
    /// The id the app's test looks for in the registry.
    let id = InputID(rawValue: "com.moonwink.tingra.fixture.input")

    /// The display name.
    let name = "Fixture Input"

    /// A generator: no device, no authorization.
    let kind = InputKind.generator

    /// Nothing to start.
    func start() async throws {}

    /// An empty stream that ends at once.
    func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { $0.finish() }
    }

    /// Nothing to stop.
    func stop() async {}
}
