//
//  MonitorPlugInTests.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreImage
import CoreMedia
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraMonitorPlugIns

/// Records the monitor overlay providers a plug-in registers.
private actor RecordingOverlayRegistry: MonitorOverlayRegistering {
    /// The registered providers, in order.
    var providers: [any MonitorOverlayProvider] = []

    /// Records the provider.
    func register(_ provider: any MonitorOverlayProvider) async throws {
        providers.append(provider)
    }
}

/// An input seam the plug-in never uses.
private struct UnusedInputs: InputRegistering {
    /// Never called.
    func register(_ input: any Input) async throws {}

    /// Never called.
    func unregister(_ id: InputID) async {}
}

/// An output seam the plug-in never uses.
private struct UnusedOutputs: OutputRegistering {
    /// Never called.
    func register(_ provider: any StreamingServiceProvider) async throws {}

    /// Never called.
    func register(_ provider: any RecordingServiceProvider) async throws {}
}

/// An effect seam the plug-in never uses.
private struct UnusedEffects: EffectRegistering {
    /// Never called.
    func register(_ provider: any AudioEffectProvider) async throws {}

    /// Never called.
    func register(_ provider: any VideoEffectProvider) async throws {}
}

/// A tool seam the plug-in never uses.
private struct UnusedTools: ToolRegistering {
    /// Never called.
    func register(_ tool: any Tool) async throws {}
}

/// A clock that never ticks.
private struct FixedClock: EngineClock {
    /// Always zero.
    var now: CMTime { .zero }

    /// Never ticks.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> { AsyncStream { $0.finish() } }
}

@Suite("MonitorPlugIn")
struct MonitorPlugInTests {
    @Test("activation registers the fourteen first-party overlays in submenu order")
    func registersInOrder() async throws {
        let registry = RecordingOverlayRegistry()
        let context = PlugInContext(
            eventBus: EventBus(), clock: FixedClock(), inputs: UnusedInputs(), outputs: UnusedOutputs(),
            effects: UnusedEffects(), tools: UnusedTools(), media: UnavailableMediaRegistry(),
            monitorOverlays: registry)
        try await MonitorPlugIn().activate(in: context)
        let ids = await registry.providers.map(\.id.rawValue)
        #expect(
            ids == [
                "flipHorizontal", "blueOnly", "zebra", "showAlpha", "tallyBorder", "titleSafe", "actionSafe",
                "crop4x3", "crop1x1", "crop9x16", "centerCross", "centerLines", "ruleOfThirds", "vuMeters",
            ])
        let stages = await registry.providers.map(\.stage)
        #expect(stages == Array(repeating: .picture, count: 4) + Array(repeating: .guide, count: 10))
        #expect(Set(await registry.providers.map(\.name)).count == 14)
        #expect(MonitorPlugIn.overlayIDs.map(\.rawValue) == ids)
    }

    @Test("activation in a host with no monitor succeeds and keeps nothing")
    func activatesWithoutMonitor() async throws {
        let context = PlugInContext(
            eventBus: EventBus(), clock: FixedClock(), inputs: UnusedInputs(), outputs: UnusedOutputs(),
            effects: UnusedEffects(), tools: UnusedTools())
        try await MonitorPlugIn().activate(in: context)
    }

    @Test("the plug-in's identity is stable")
    func identity() {
        #expect(MonitorPlugIn().id == PlugInID(rawValue: "com.moonwink.tingra.monitorOverlays"))
        #expect(MonitorPlugIn().name == "Monitor Overlays")
    }

    @Test("a crop guide is unavailable on a canvas of its own aspect and available on others")
    func cropAvailability() {
        let landscape = CGSize(width: 1920, height: 1080)
        let portrait = CGSize(width: 1080, height: 1920)
        let square = CGSize(width: 1080, height: 1080)
        #expect(CropGuideOverlayProvider.nineBySixteen.isAvailable(onCanvas: landscape))
        #expect(!CropGuideOverlayProvider.nineBySixteen.isAvailable(onCanvas: portrait))
        #expect(!CropGuideOverlayProvider.square.isAvailable(onCanvas: square))
        #expect(CropGuideOverlayProvider.square.isAvailable(onCanvas: portrait))
        #expect(!CropGuideOverlayProvider.fourByThree.isAvailable(onCanvas: CGSize(width: 1440, height: 1080)))
        #expect(CropGuideOverlayProvider.fourByThree.isAvailable(onCanvas: .zero))
    }

    @Test("Show Alpha is available on the input tiles and the layer monitor only")
    func showAlphaAvailability() {
        let provider = ShowAlphaOverlayProvider()
        #expect(!provider.isAvailable(on: .program))
        #expect(!provider.isAvailable(on: .preview))
        #expect(provider.isAvailable(on: .input))
        #expect(provider.isAvailable(on: .layer))
        #expect(FlipHorizontalOverlayProvider().isAvailable(on: .program))
    }

    @Test("the zebra declares a 95 % level and clamps what it is given")
    func zebraParameters() throws {
        let level = try #require(ZebraOverlayProvider().parameters.first)
        #expect(level.key == "level")
        #expect(level.defaultValue == 0.95)
        #expect(level.unit == "%")
        var overlay = ZebraOverlay()
        overlay.setParameters(["level": .double(0.2)])
        #expect(overlay.level == 0.5)
        overlay.setParameters(["level": .string("high")])
        #expect(overlay.level == 0.5)
        overlay.setParameters(["level": .double(0.9)])
        #expect(overlay.level == 0.9)
    }

    @Test("every guide declares its color and line width, and clamps the width")
    func guideStyle() {
        let keys = ["color", "lineWidth"]
        for provider: any MonitorOverlayProvider in [
            SafeAreaOverlayProvider.titleSafe, CropGuideOverlayProvider.square, CenterCrossOverlayProvider(),
            CenterLinesOverlayProvider(), RuleOfThirdsOverlayProvider(),
        ] {
            #expect(Set(keys).isSubset(of: Set(provider.parameters.map(\.key))), "\(provider.id.rawValue)")
        }
        var style = GuideStyle()
        #expect(style.lineWidthPoints == 1)
        style.apply(["lineWidth": .double(9)])
        #expect(style.lineWidthPoints == 4)
        style.apply(["lineWidth": .string("thick")])
        #expect(style.lineWidthPoints == 4)
        style.apply(["lineWidth": .double(2)])
        #expect(style.lineWidthPoints == 2)
        let context = MonitorOverlayContext(
            monitor: .program, tally: .program, canvasSize: .zero, pictureRect: .zero, drawableRect: .zero,
            backingScale: 2)
        #expect(style.lineWidth(in: context) == 4)
        #expect(style == style)
        #expect(style != GuideStyle())
    }

    @Test("the tally border declares a three-point width and clamps what it is given")
    func tallyWidth() throws {
        let width = try #require(TallyBorderOverlayProvider().parameters.first)
        #expect(width.key == "width")
        #expect(width.defaultValue == 3)
        var overlay = TallyBorderOverlay()
        overlay.setParameters(["width": .double(20)])
        #expect(overlay.width == 8)
        overlay.setParameters(["width": .double(0)])
        #expect(overlay.width == 1)
    }

    @Test("the VU meters ask for levels and are unavailable on preview only")
    func vuMetersAvailability() {
        let provider = VUMetersOverlayProvider()
        #expect(provider.usesAudioLevels)
        #expect(!provider.isAvailable(on: .preview))
        #expect(provider.isAvailable(on: .program))
        #expect(provider.isAvailable(on: .input))
        #expect(provider.isAvailable(on: .layer))
        #expect(!SafeAreaOverlayProvider.titleSafe.usesAudioLevels)
    }

    @Test("a level maps onto the meter from the -60 dBFS floor to full scale")
    func vuMeterScale() {
        #expect(VUMetersOverlay.fraction(of: 0) == 0)
        #expect(VUMetersOverlay.fraction(of: 1) == 1)
        #expect(VUMetersOverlay.fraction(of: 2) == 1)
        #expect(VUMetersOverlay.fraction(of: 0.0001) == 0)
        #expect(abs(VUMetersOverlay.fraction(of: 0.1) - 2.0 / 3.0) < 1e-6)
    }

    @Test("the meter tracks sit against the right margin, first channel leftmost, and need room")
    func vuMeterTracks() {
        let picture = CGRect(x: 0, y: 0, width: 160, height: 90)
        let tracks = VUMetersOverlay.tracks(in: picture, count: 2, backingScale: 1)
        #expect(tracks == [CGRect(x: 138, y: 8, width: 6, height: 74), CGRect(x: 146, y: 8, width: 6, height: 74)])
        #expect(VUMetersOverlay.tracks(in: picture, count: 0, backingScale: 1).isEmpty)
        #expect(
            VUMetersOverlay.tracks(in: CGRect(x: 0, y: 0, width: 10, height: 90), count: 2, backingScale: 1).isEmpty)
    }

    @Test("a full meter fills green, then yellow, then red; a quiet one only green")
    func vuMeterSegments() {
        let track = CGRect(x: 0, y: 0, width: 6, height: 60)
        let full = VUMetersOverlay.segments(of: track, filledTo: 1)
        #expect(
            full.map(\.1) == [VUMetersOverlay.safeColor, VUMetersOverlay.cautionColor, VUMetersOverlay.dangerColor])
        #expect(full.first?.0.minY == 0)
        #expect(full.last?.0.maxY == 60)
        let quiet = VUMetersOverlay.segments(of: track, filledTo: 0.25)
        #expect(quiet.map(\.1) == [VUMetersOverlay.safeColor])
        #expect(quiet.first?.0.height == 15)
        #expect(VUMetersOverlay.segments(of: track, filledTo: 0).isEmpty)
    }

    @Test("the zebra kernel compiles")
    func zebraKernelCompiles() {
        #expect(ZebraKernel.compiled != nil)
    }

    @Test("the safe areas declare their SMPTE sizes as defaults")
    func safeAreaDefaults() throws {
        let title = try #require(SafeAreaOverlayProvider.titleSafe.parameters.first)
        let action = try #require(SafeAreaOverlayProvider.actionSafe.parameters.first)
        #expect(title.key == "size")
        #expect(title.defaultValue == 0.9)
        #expect(action.defaultValue == 0.93)
        #expect(title.unit == "%")
        #expect(SafeAreaOverlayProvider.titleSafe.parameters.contains { $0.kind == .color })
    }

    @Test("a safe area clamps its size and ignores ill-shaped values")
    func safeAreaParameters() {
        var overlay = SafeAreaOverlay(size: 0.9)
        overlay.setParameters(["size": .double(2)])
        #expect(overlay.size == 1)
        overlay.setParameters(["size": .double(0.1)])
        #expect(overlay.size == 0.5)
        overlay.setParameters(["size": .string("wide"), "color": .string("red")])
        #expect(overlay.size == 0.5)
        #expect(overlay.style.color == GuideDrawing.defaultColor)
        overlay.setParameters(["color": ParameterColor(red: 1, green: 1, blue: 0).jsonValue])
        #expect(overlay.style.color == ParameterColor(red: 1, green: 1, blue: 0))
    }

    @Test("a crop guide clamps its shading")
    func cropParameters() {
        var overlay = CropGuideOverlay(aspect: 1)
        overlay.setParameters(["shading": .double(3)])
        #expect(overlay.shading == 1)
        overlay.setParameters(["shading": .double(-1)])
        #expect(overlay.shading == 0)
    }

    @Test("the tally border is red on program, green on preview, and absent when unlit")
    func tallyColors() {
        #expect(TallyBorderOverlay.color(for: .program) == TallyBorderOverlay.programColor)
        #expect(TallyBorderOverlay.color(for: .preview) == TallyBorderOverlay.previewColor)
        #expect(TallyBorderOverlay.color(for: .unlit) == nil)
    }
}
