//
//  MonitorOverlaySeamTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TingraEventBus

@testable import TingraPlugInKit

/// A guide overlay that declares nothing and draws nothing, for the seam
/// tests below.
private struct StubOverlayProvider: MonitorOverlayProvider {
    /// The stub's identifier.
    let id = MonitorOverlayID(rawValue: "test.stub")

    /// The stub's name.
    let name = "Stub"

    /// A guide, like most overlays.
    let stage = MonitorOverlayStage.guide

    /// Makes an overlay that returns the picture unchanged.
    func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        StubOverlay()
    }
}

/// The overlay the stub provider makes: the picture, unchanged.
private struct StubOverlay: MonitorOverlay {
    /// Ignores every parameter.
    mutating func setParameters(_ parameters: [String: JSONValue]) {}

    /// Returns the picture unchanged.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        picture
    }
}

/// A registry that remembers what was registered, standing in for the
/// host's, so a context test can tell it apart from the default.
private actor RecordingOverlayRegistry: MonitorOverlayRegistering {
    /// The registered ids, in order.
    var registered: [MonitorOverlayID] = []

    /// Records the provider's id.
    func register(_ provider: any MonitorOverlayProvider) async throws {
        registered.append(provider.id)
    }
}

/// A clock that never ticks, enough to construct a context.
private struct StoppedClock: EngineClock {
    /// Always zero.
    var now: CMTime { .zero }

    /// Never ticks.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> { AsyncStream { $0.finish() } }
}

/// An input seam that accepts nothing, enough to construct a context.
private struct NoInputs: InputRegistering {
    /// Never called.
    func register(_ input: any Input) async throws {}

    /// Never called.
    func unregister(_ id: InputID) async {}
}

/// An output seam that accepts nothing, enough to construct a context.
private struct NoOutputs: OutputRegistering {
    /// Never called.
    func register(_ provider: any StreamingServiceProvider) async throws {}

    /// Never called.
    func register(_ provider: any RecordingServiceProvider) async throws {}
}

/// An effect seam that accepts nothing, enough to construct a context.
private struct NoEffects: EffectRegistering {
    /// Never called.
    func register(_ provider: any AudioEffectProvider) async throws {}

    /// Never called.
    func register(_ provider: any VideoEffectProvider) async throws {}
}

/// A tool seam that accepts nothing, enough to construct a context.
private struct NoTools: ToolRegistering {
    /// Never called.
    func register(_ tool: any Tool) async throws {}
}

@Suite("Monitor overlay seam")
struct MonitorOverlaySeamTests {
    @Test("Monitor overlay identifiers round-trip through Codable as a bare string")
    func identifierRoundTrips() throws {
        let id = MonitorOverlayID(rawValue: "titleSafe")
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["titleSafe"]"#)
        #expect(try JSONDecoder().decode([MonitorOverlayID].self, from: data) == [id])
        #expect(id == MonitorOverlayID(rawValue: "titleSafe"))
        #expect(id != MonitorOverlayID(rawValue: "actionSafe"))
    }

    @Test("A provider is available on every canvas unless it says otherwise")
    func providerDefaultsToAvailable() {
        let provider = StubOverlayProvider()
        #expect(provider.isAvailable(onCanvas: CGSize(width: 1920, height: 1080)))
        #expect(provider.isAvailable(onCanvas: .zero))
        #expect(provider.parameters.isEmpty)
    }

    @Test("A provider asks for no audio levels unless it says otherwise")
    func providerDefaultsToNoLevels() {
        #expect(!StubOverlayProvider().usesAudioLevels)
    }

    @Test("A context made without levels has none, and levels make contexts differ")
    func contextLevels() {
        let rect = CGRect(x: 0, y: 0, width: 16, height: 9)
        let plain = MonitorOverlayContext(
            monitor: .program, tally: .program, canvasSize: rect.size, pictureRect: rect, drawableRect: rect,
            backingScale: 1)
        #expect(plain.audioLevels.isEmpty)
        let level = MonitorOverlayContext.AudioLevel(peak: 0.5, rms: 0.25)
        let metered = MonitorOverlayContext(
            monitor: .program, tally: .program, canvasSize: rect.size, pictureRect: rect, drawableRect: rect,
            backingScale: 1, audioLevels: [level, level])
        #expect(metered.audioLevels == [level, level])
        #expect(metered != plain)
        #expect(level == MonitorOverlayContext.AudioLevel(peak: 0.5, rms: 0.25))
        #expect(level != MonitorOverlayContext.AudioLevel(peak: 0.5, rms: 0.3))
    }

    @Test("A provider is available on every monitor unless it says otherwise")
    func providerDefaultsToAvailableOnEveryMonitor() {
        let provider = StubOverlayProvider()
        for monitor: MonitorOverlayContext.Monitor in [.program, .preview, .input, .layer] {
            #expect(provider.isAvailable(on: monitor))
        }
    }

    @Test("Picture overlays come before guide overlays in the stage order")
    func stageOrder() {
        #expect(MonitorOverlayStage.allCases == [.picture, .guide])
    }

    @Test("A context keeps every value it was made with and compares by all of them")
    func contextValues() {
        let context = MonitorOverlayContext(
            monitor: .program, tally: .program, canvasSize: CGSize(width: 1920, height: 1080),
            pictureRect: CGRect(x: 0, y: 60, width: 1600, height: 900),
            drawableRect: CGRect(x: 0, y: 0, width: 1600, height: 1020), backingScale: 2)
        #expect(context.monitor == .program)
        #expect(context.tally == .program)
        #expect(context.canvasSize == CGSize(width: 1920, height: 1080))
        #expect(context.pictureRect == CGRect(x: 0, y: 60, width: 1600, height: 900))
        #expect(context.drawableRect == CGRect(x: 0, y: 0, width: 1600, height: 1020))
        #expect(context.backingScale == 2)
        let preview = MonitorOverlayContext(
            monitor: .preview, tally: .preview, canvasSize: context.canvasSize, pictureRect: context.pictureRect,
            drawableRect: context.drawableRect, backingScale: 2)
        #expect(context == context)
        #expect(context != preview)
    }

    @Test("A context constructed without a monitor overlay registry carries the discarding one")
    func contextDefaultsToDiscardingRegistry() async throws {
        let context = PlugInContext(
            eventBus: EventBus(), clock: StoppedClock(), inputs: NoInputs(), outputs: NoOutputs(),
            effects: NoEffects(), tools: NoTools())
        #expect(context.monitorOverlays is DiscardingMonitorOverlayRegistry)
        #expect(context.media is UnavailableMediaRegistry)
        // Accepting, never throwing: an overlay plug-in activates in a host
        // with no monitor.
        try await context.monitorOverlays.register(StubOverlayProvider())
    }

    @Test("A context constructed with a monitor overlay registry hands registrations to it")
    func contextCarriesGivenRegistry() async throws {
        let registry = RecordingOverlayRegistry()
        let context = PlugInContext(
            eventBus: EventBus(), clock: StoppedClock(), inputs: NoInputs(), outputs: NoOutputs(),
            effects: NoEffects(), tools: NoTools(), media: UnavailableMediaRegistry(), monitorOverlays: registry)
        try await context.monitorOverlays.register(StubOverlayProvider())
        #expect(await registry.registered == [MonitorOverlayID(rawValue: "test.stub")])
    }

    @Test("The stub overlay returns the picture it was given")
    func overlayPassesThrough() {
        let picture = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9))
        let context = MonitorOverlayContext(
            monitor: .input, tally: .unlit, canvasSize: CGSize(width: 16, height: 9), pictureRect: picture.extent,
            drawableRect: picture.extent, backingScale: 1)
        var overlay = StubOverlayProvider().makeOverlay(parameters: [:])
        overlay.setParameters(["ignored": .bool(true)])
        #expect(overlay.render(over: picture, in: context).extent == picture.extent)
    }
}
