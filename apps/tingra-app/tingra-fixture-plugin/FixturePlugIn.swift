//
//  FixturePlugIn.swift
//  tingra-fixture-plugin
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
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

    /// Registers the input and the monitor overlay the fixture contributes
    /// and reports that it ran, on the host's own bus.
    func activate(in context: PlugInContext) async throws {
        try await context.inputs.register(FixtureInput())
        try await context.monitorOverlays.register(FixtureOverlayProvider())
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

    /// Video, so the host's registry accepts the input without reporting
    /// `input.noMedia`: a fixture should load as quietly as a well-made
    /// plug-in does.
    let media = InputMedia.video

    /// Nothing to start.
    func start() async throws {}

    /// An empty stream that ends at once.
    func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { $0.finish() }
    }

    /// Nothing to stop.
    func stop() async {}
}

/// The fixture's monitor overlay: a guide that draws nothing. Its only job
/// is to cross the boundary into the host's `MonitorOverlayRegistry`, the
/// proof that a third-party overlay loads and reaches the Overlays submenus
/// (PLUGINS.md, Decision 53).
struct FixtureOverlayProvider: MonitorOverlayProvider {
    /// The id the app's test looks for in the registry.
    let id = MonitorOverlayID(rawValue: "com.moonwink.tingra.fixture.overlay")

    /// The display name.
    let name = "Fixture Overlay"

    /// A guide.
    let stage = MonitorOverlayStage.guide

    /// Makes the overlay.
    func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        FixtureOverlay()
    }
}

/// The fixture overlay: the picture, unchanged.
struct FixtureOverlay: MonitorOverlay {
    /// Nothing to read.
    mutating func setParameters(_ parameters: [String: JSONValue]) {}

    /// Returns the picture unchanged.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        picture
    }
}
