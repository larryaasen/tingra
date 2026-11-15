//
//  MonitorOverlayTests.swift
//  tingra-app
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
import TingraAudio
import TingraComposition
import TingraEventBus
import TingraMonitorPlugIns
import TingraPlugInKit

@testable import TingraApp

/// An overlay that paints the whole drawable one color, so a test can see
/// whether it ran.
private struct FillOverlay: MonitorOverlay {
    /// The fill.
    let color: CIColor

    /// Ignores every parameter.
    mutating func setParameters(_ parameters: [String: JSONValue]) {}

    /// Paints the drawable, over the picture.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        CIImage(color: color).cropped(to: context.drawableRect).composited(over: picture)
    }
}

/// A provider with a configurable identity, stage, and canvas rule.
private struct StubProvider: MonitorOverlayProvider {
    /// The overlay's identifier.
    let id: MonitorOverlayID

    /// The overlay's name.
    let name: String

    /// The overlay's stage.
    var stage = MonitorOverlayStage.guide

    /// Whether the overlay draws on a square canvas.
    var drawsOnSquare = true

    /// Available everywhere but, when ``drawsOnSquare`` is false, a square.
    func isAvailable(onCanvas canvasSize: CGSize) -> Bool {
        drawsOnSquare || canvasSize.width != canvasSize.height
    }

    /// Makes a red fill.
    func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        FillOverlay(color: CIColor(red: 1, green: 0, blue: 0))
    }
}

/// The catalog, the lineups a monitor draws, and the model's per-bus
/// choices (ARCHITECTURE.md, "Monitor overlays"; PLUGINS.md, Decisions
/// 55 and 57).
@Suite("Monitor overlays")
@MainActor
struct MonitorOverlayTests {
    /// A model over throwaway preferences and a silent monitor.
    private func makeModel(suiteName: String) throws -> EngineModel {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return EngineModel(
            monitor: SilentMonitor(), snapshotPreferences: SnapshotPreferences(defaults: defaults),
            recordingPreferences: RecordingPreferences(defaults: defaults))
    }

    /// A fresh suite name for one test.
    private func makeSuiteName() -> String { "MonitorOverlayTests-\(UUID().uuidString)" }

    /// The first-party providers, by activating the first-party plug-in
    /// into a registry.
    private func firstPartyProviders() async throws -> [any MonitorOverlayProvider] {
        let registry = MonitorOverlayRecorder()
        try await MonitorPlugIn().activate(in: registry.context)
        return await registry.providers
    }

    @Test("the catalog lists first-party overlays in their fixed order, then the rest by name")
    func catalogOrder() async throws {
        let firstParty = try await firstPartyProviders()
        let third = StubProvider(id: MonitorOverlayID(rawValue: "com.example.zebra"), name: "Zebra")
        let other = StubProvider(id: MonitorOverlayID(rawValue: "com.example.alpha"), name: "alpha guide")
        let catalog = MonitorOverlayCatalog(providers: [third] + firstParty.reversed() + [other])
        #expect(
            catalog.providers.map(\.id) == MonitorPlugIn.overlayIDs + [other.id, third.id])
    }

    @Test("the catalog's sections put picture overlays before guides and leave out an empty stage")
    func catalogSections() {
        let guide = StubProvider(id: MonitorOverlayID(rawValue: "g"), name: "G")
        let picture = StubProvider(id: MonitorOverlayID(rawValue: "p"), name: "P", stage: .picture)
        let catalog = MonitorOverlayCatalog(providers: [guide, picture], firstPartyOrder: [])
        #expect(catalog.sections.map(\.stage) == [.picture, .guide])
        #expect(MonitorOverlayCatalog(providers: [guide], firstPartyOrder: []).sections.map(\.stage) == [.guide])
        #expect(MonitorOverlayCatalog.empty.sections.isEmpty)
    }

    @Test("a monitor's overlays follow drawing order, skip unknown ids, and carry their stored values")
    func catalogOverlays() {
        let guide = StubProvider(id: MonitorOverlayID(rawValue: "g"), name: "G")
        let picture = StubProvider(id: MonitorOverlayID(rawValue: "p"), name: "P", stage: .picture)
        let catalog = MonitorOverlayCatalog(providers: [guide, picture], firstPartyOrder: [])
        let entries = catalog.overlays(
            for: [guide.id, MonitorOverlayID(rawValue: "missing"), picture.id],
            parameters: ["g": ["size": .double(0.5)]])
        #expect(entries.map(\.provider.id) == [picture.id, guide.id])
        #expect(entries.last?.parameters == ["size": .double(0.5)])
        #expect(entries.first?.parameters == [:])
        #expect(catalog.provider(withID: guide.id)?.name == "G")
        #expect(catalog.provider(withID: MonitorOverlayID(rawValue: "missing")) == nil)
    }

    @Test("lineups are equal when they draw the same overlays with the same values on the same monitor")
    func lineupEquality() {
        let guide = StubProvider(id: MonitorOverlayID(rawValue: "g"), name: "G")
        let catalog = MonitorOverlayCatalog(providers: [guide], firstPartyOrder: [])
        let base = MonitorOverlayLineup(
            entries: catalog.overlays(for: [guide.id], parameters: [:]), monitor: .program, tally: .program)
        let same = MonitorOverlayLineup(
            entries: catalog.overlays(for: [guide.id], parameters: [:]), monitor: .program, tally: .program)
        let otherValues = MonitorOverlayLineup(
            entries: catalog.overlays(for: [guide.id], parameters: ["g": ["size": .double(0.5)]]),
            monitor: .program, tally: .program)
        let otherMonitor = MonitorOverlayLineup(
            entries: catalog.overlays(for: [guide.id], parameters: [:]), monitor: .preview, tally: .preview)
        #expect(base == same)
        #expect(base != otherValues)
        #expect(base != otherMonitor)
        #expect(base != .none)
        #expect(MonitorOverlayLineup.none.isEmpty)
    }

    @Test("a lineup skips an overlay unavailable on the canvas and keeps the drawable's extent")
    func lineupRendering() {
        let squareShy = StubProvider(id: MonitorOverlayID(rawValue: "s"), name: "S", drawsOnSquare: false)
        let catalog = MonitorOverlayCatalog(providers: [squareShy], firstPartyOrder: [])
        let lineup = MonitorOverlayLineup(
            entries: catalog.overlays(for: [squareShy.id], parameters: [:]), monitor: .program, tally: .program)
        let drawable = CGRect(x: 0, y: 0, width: 32, height: 18)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: drawable)
        let context = CIContext()
        /// The red byte at the drawable's center.
        func centerRed(_ image: CIImage) -> UInt8 {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(
                image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 16, y: 9, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return bytes[0]
        }
        let wide = lineup.render(
            over: black, canvasSize: CGSize(width: 1920, height: 1080), pictureRect: drawable,
            drawableRect: drawable, backingScale: 2)
        let square = lineup.render(
            over: black, canvasSize: CGSize(width: 1080, height: 1080), pictureRect: drawable,
            drawableRect: drawable, backingScale: 2)
        #expect(centerRed(wide) == 255)
        #expect(centerRed(square) == 0)
        #expect(wide.extent == drawable)
        #expect(
            MonitorOverlayLineup.none.render(
                over: black, canvasSize: .zero, pictureRect: drawable, drawableRect: drawable, backingScale: 1
            ).extent == drawable)
    }

    @Test("a new project shows the tally border on both bus monitors and nothing else")
    func defaults() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        #expect(model.monitorOverlaySettings == nil)
        #expect(model.isMonitorOverlayOn(TallyBorderOverlayProvider.overlayID, on: .program))
        #expect(model.isMonitorOverlayOn(TallyBorderOverlayProvider.overlayID, on: .preview))
        #expect(!model.isMonitorOverlayOn(SafeAreaOverlayProvider.titleSafeID, on: .program))
    }

    @Test("turning an overlay on for one monitor leaves the other alone, and off removes it")
    func toggling() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        let title = SafeAreaOverlayProvider.titleSafeID
        model.setMonitorOverlay(title, on: .program, isOn: true)
        #expect(model.isMonitorOverlayOn(title, on: .program))
        #expect(!model.isMonitorOverlayOn(title, on: .preview))
        #expect(model.monitorOverlaySettings?.program == [TallyBorderOverlayProvider.overlayID, title])
        #expect(model.monitorOverlaySettings?.preview == [TallyBorderOverlayProvider.overlayID])

        model.setMonitorOverlay(title, on: .program, isOn: true)
        #expect(model.monitorOverlaySettings?.program.count == 2)

        model.setMonitorOverlay(TallyBorderOverlayProvider.overlayID, on: .preview, isOn: false)
        #expect(model.monitorOverlaySettings?.preview == [])
        #expect(!model.isMonitorOverlayOn(TallyBorderOverlayProvider.overlayID, on: .preview))
    }

    @Test("a setting that changes nothing leaves the project's key absent")
    func noChangeKeepsDefaults() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        model.setMonitorOverlay(TallyBorderOverlayProvider.overlayID, on: .program, isOn: true)
        model.setMonitorOverlay(SafeAreaOverlayProvider.titleSafeID, on: .preview, isOn: false)
        #expect(model.monitorOverlaySettings == nil)
    }

    @Test("a bus monitor's lineup is made from the catalog, with its monitor and tally")
    func modelLineup() async throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        #expect(model.monitorOverlayLineup(for: .program).isEmpty)

        model.fillMonitorOverlayCatalog(with: try await firstPartyProviders())
        model.setMonitorOverlay(CenterCrossOverlayProvider.overlayID, on: .program, isOn: true)
        let program = model.monitorOverlayLineup(for: .program)
        #expect(program.ids == [TallyBorderOverlayProvider.overlayID, CenterCrossOverlayProvider.overlayID])
        #expect(program.monitor == .program)
        #expect(program.tally == .program)
        let preview = model.monitorOverlayLineup(for: .preview)
        #expect(preview.ids == [TallyBorderOverlayProvider.overlayID])
        #expect(preview.tally == .preview)
        #expect(preview != program)
    }

    @Test("every crop guide is available on the default 16:9 program")
    func availabilityFollowsFormat() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        // The default program is 1920x1080.
        #expect(model.isMonitorOverlayAvailable(CropGuideOverlayProvider.nineBySixteen, on: .program))
        #expect(model.isMonitorOverlayAvailable(CropGuideOverlayProvider.fourByThree, on: .preview))
    }

    @Test("Show Alpha is available on the input tiles and the layer monitor, not the bus monitors")
    func availabilityFollowsMonitor() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        let alpha = ShowAlphaOverlayProvider()
        #expect(!model.isMonitorOverlayAvailable(alpha, on: .program))
        #expect(!model.isMonitorOverlayAvailable(alpha, on: .preview))
        #expect(model.isMonitorOverlayAvailable(alpha, on: .input))
        #expect(model.isMonitorOverlayAvailable(alpha, on: .layer))
    }

    @Test("a crop guide stays available on an input tile, whose canvas each draw checks")
    func inputTilesSkipTheProgramCanvasCheck() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        let crop = CropGuideOverlayProvider.square
        #expect(model.isMonitorOverlayAvailable(crop, on: .input))
        #expect(model.isMonitorOverlayAvailable(crop, on: .layer))
    }

    @Test("the input tiles and the layer monitor keep their own lists, empty by default")
    func inputAndLayerLists() async throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        model.fillMonitorOverlayCatalog(with: try await firstPartyProviders())
        #expect(model.monitorOverlayLineup(for: .input).isEmpty)
        #expect(model.monitorOverlayLineup(for: .layer).isEmpty)

        let alpha = ShowAlphaOverlayProvider.overlayID
        model.setMonitorOverlay(alpha, on: .input, isOn: true)
        #expect(model.isMonitorOverlayOn(alpha, on: .input))
        #expect(!model.isMonitorOverlayOn(alpha, on: .layer))
        #expect(model.monitorOverlaySettings?.input == [alpha])
        #expect(model.monitorOverlaySettings?.program == [TallyBorderOverlayProvider.overlayID])

        let onAir = model.monitorOverlayLineup(for: .input, tally: .program)
        #expect(onAir.ids == [alpha])
        #expect(onAir.monitor == .input)
        #expect(onAir.tally == .program)
        #expect(model.monitorOverlayLineup(for: .input).tally == .unlit)
        #expect(onAir != model.monitorOverlayLineup(for: .input))

        model.setMonitorOverlay(alpha, on: .layer, isOn: true)
        #expect(model.monitorOverlayLineup(for: .layer).monitor == .layer)
        #expect(model.monitorOverlaySettings?.layer == [alpha])
    }

    @Test("a monitor is mirrored only while Flip Horizontal is on there and loaded")
    func mirroring() async throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        let flip = FlipHorizontalOverlayProvider.overlayID
        model.setMonitorOverlay(flip, on: .preview, isOn: true)
        #expect(!model.isMonitorMirrored(.preview))
        model.fillMonitorOverlayCatalog(with: try await firstPartyProviders())
        #expect(model.isMonitorMirrored(.preview))
        #expect(!model.isMonitorMirrored(.program))
        model.setMonitorOverlay(flip, on: .preview, isOn: false)
        #expect(!model.isMonitorMirrored(.preview))
    }

    @Test("a lineup skips an overlay unavailable on its monitor")
    func lineupSkipsUnavailableMonitor() async throws {
        let catalog = MonitorOverlayCatalog(providers: try await firstPartyProviders())
        let drawable = CGRect(x: 0, y: 0, width: 40, height: 20)
        let clear = CIImage(color: .clear).cropped(to: drawable)
        let entries = catalog.overlays(for: [ShowAlphaOverlayProvider.overlayID], parameters: [:])
        let onProgram = MonitorOverlayLineup(entries: entries, monitor: .program, tally: .program)
        let onLayer = MonitorOverlayLineup(entries: entries, monitor: .layer, tally: .unlit)
        let drawnOnProgram = onProgram.render(
            over: clear, canvasSize: drawable.size, pictureRect: drawable, drawableRect: drawable, backingScale: 1)
        let drawnOnLayer = onLayer.render(
            over: clear, canvasSize: drawable.size, pictureRect: drawable, drawableRect: drawable, backingScale: 1)
        #expect(alpha(of: drawnOnProgram) == 0)
        #expect(alpha(of: drawnOnLayer) == 255)
    }

    @Test("every monitor that takes a snapshot has its own overlay list")
    func targetFromSubject() {
        #expect(MonitorOverlayTarget(subject: .program) == .program)
        #expect(MonitorOverlayTarget(subject: .preview) == .preview)
        #expect(MonitorOverlayTarget(subject: .layer) == .layer)
        #expect(MonitorOverlayTarget(subject: .input(InputID(rawValue: "cam"))) == .input)
        #expect(MonitorOverlayTarget.program.eventValue == .string("program"))
        #expect(MonitorOverlayTarget.input.monitor == .input)
        #expect(MonitorOverlayTarget.layer.defaultTally == .unlit)
        #expect(MonitorOverlayTarget.preview.defaultTally == .preview)
        #expect(MonitorOverlayTarget.program.showsProgramCanvas)
        #expect(!MonitorOverlayTarget.input.showsProgramCanvas)
    }

    @Test("a multiview tile's tally maps to the overlay tally colors")
    func tileTally() {
        #expect(MultiviewTile.Tally.onAir.monitorOverlayTally == .program)
        #expect(MultiviewTile.Tally.staged.monitorOverlayTally == .preview)
        #expect(MultiviewTile.Tally.idle.monitorOverlayTally == .unlit)
    }

    @Test("an overlay value is stored per overlay, changes nothing when equal, and resets to the defaults")
    func parameterValues() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        let title = SafeAreaOverlayProvider.titleSafeID
        #expect(model.monitorOverlayParameterValues(for: title).isEmpty)

        model.setMonitorOverlayParameter(.double(0.85), forKey: "size", ofOverlay: title)
        #expect(model.monitorOverlayParameterValues(for: title) == ["size": .double(0.85)])
        #expect(model.monitorOverlaySettings?.parameters["titleSafe"] == ["size": .double(0.85)])
        #expect(model.monitorOverlaySettings?.program == [TallyBorderOverlayProvider.overlayID])

        model.resetMonitorOverlayParameters(ofOverlay: title)
        #expect(model.monitorOverlayParameterValues(for: title).isEmpty)
        #expect(model.monitorOverlaySettings?.parameters.isEmpty == true)
    }

    @Test("a changed overlay value reaches every monitor's lineup and changes its equality")
    func parameterValuesReachLineups() async throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        model.fillMonitorOverlayCatalog(with: try await firstPartyProviders())
        let before = model.monitorOverlayLineup(for: .program)
        model.setMonitorOverlayParameter(.double(5), forKey: "width", ofOverlay: TallyBorderOverlayProvider.overlayID)
        let after = model.monitorOverlayLineup(for: .program)
        #expect(after != before)
        #expect(after.entries.first?.parameters == ["width": .double(5)])
        #expect(model.monitorOverlayLineup(for: .preview).entries.first?.parameters == ["width": .double(5)])
    }

    @Test("VU meters read the master on program, an input's strip on its tile, and nothing on preview")
    func meterSubjects() async throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        model.fillMonitorOverlayCatalog(with: try await firstPartyProviders())
        #expect(model.monitorOverlayLineup(for: .program).meters == nil)

        let meters = VUMetersOverlayProvider.overlayID
        for target in MonitorOverlayTarget.allCases {
            model.setMonitorOverlay(meters, on: target, isOn: true)
        }
        let camera = InputID(rawValue: "cam")
        #expect(model.monitorOverlayLineup(for: .program).meters?.subject == .master)
        #expect(model.monitorOverlayLineup(for: .input, input: camera).meters?.subject == .strip(camera))
        #expect(model.monitorOverlayLineup(for: .input).meters == nil)
        #expect(model.monitorOverlayLineup(for: .preview).meters == nil)
        #expect(model.monitorOverlayLineup(for: .layer).meters == nil)

        model.meterRelay.fold(
            MeterBlock(
                time: .zero, strips: [camera: MeterReading(peak: 0.5, rms: 0.25)],
                master: StereoMeterReading(
                    left: MeterReading(peak: 0.8, rms: 0.4), right: MeterReading(peak: 0.6, rms: 0.3))))
        #expect(
            model.monitorOverlayLineup(for: .program).audioLevels() == [
                MonitorOverlayContext.AudioLevel(peak: 0.8, rms: 0.4),
                MonitorOverlayContext.AudioLevel(peak: 0.6, rms: 0.3),
            ])
        #expect(
            model.monitorOverlayLineup(for: .input, input: camera).audioLevels() == [
                MonitorOverlayContext.AudioLevel(peak: 0.5, rms: 0.25)
            ])
        #expect(
            model.monitorOverlayLineup(for: .input, input: InputID(rawValue: "quiet")).audioLevels().isEmpty)
    }

    @Test("a lineup without meters reads no levels, and meters make lineups differ by subject")
    func lineupLevels() async throws {
        let catalog = MonitorOverlayCatalog(providers: try await firstPartyProviders())
        let relay = MeterRelay()
        relay.fold(
            MeterBlock(
                time: .zero, strips: [:],
                master: StereoMeterReading(
                    left: MeterReading(peak: 1, rms: 1), right: MeterReading(peak: 1, rms: 1))))
        var guides = MonitorOverlayLineup(
            entries: catalog.overlays(for: [CenterCrossOverlayProvider.overlayID], parameters: [:]),
            monitor: .program, tally: .program)
        guides.meters = MonitorOverlayMeters(relay: relay, subject: .master)
        #expect(!guides.usesAudioLevels)
        #expect(guides.audioLevels().isEmpty)

        var master = MonitorOverlayLineup(
            entries: catalog.overlays(for: [VUMetersOverlayProvider.overlayID], parameters: [:]),
            monitor: .program, tally: .program)
        master.meters = MonitorOverlayMeters(relay: relay, subject: .master)
        #expect(master.usesAudioLevels)
        #expect(master.audioLevels().count == 2)
        var strip = master
        strip.meters = MonitorOverlayMeters(relay: relay, subject: .strip(InputID(rawValue: "cam")))
        #expect(strip != master)
        var otherRelay = master
        otherRelay.meters = MonitorOverlayMeters(relay: MeterRelay(), subject: .master)
        #expect(otherRelay != master)
    }

    /// The alpha of the bottom-left pixel of an image.
    ///
    /// - Parameter image: The image to read.
    /// - Returns: The pixel's alpha, 0 to 255.
    private func alpha(of image: CIImage) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes[3]
    }
}

/// A registry that records what a plug-in registers, with a context to
/// activate it in.
private actor MonitorOverlayRecorder: MonitorOverlayRegistering {
    /// The registered providers, in order.
    var providers: [any MonitorOverlayProvider] = []

    /// Records the provider.
    func register(_ provider: any MonitorOverlayProvider) async throws {
        providers.append(provider)
    }

    /// A context whose monitor overlay seam is this recorder and whose
    /// other seams accept nothing.
    nonisolated var context: PlugInContext {
        PlugInContext(
            eventBus: EventBus(), clock: StoppedClock(), inputs: NoInputs(), outputs: NoOutputs(),
            effects: NoEffects(), tools: NoTools(), media: UnavailableMediaRegistry(), monitorOverlays: self)
    }
}

/// A clock that never ticks, enough to construct a context.
private struct StoppedClock: EngineClock {
    /// Always zero.
    var now: CMTime { .zero }

    /// Never ticks.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> { AsyncStream { $0.finish() } }
}

/// An input seam that accepts nothing.
private struct NoInputs: InputRegistering {
    /// Never called.
    func register(_ input: any Input) async throws {}

    /// Never called.
    func unregister(_ id: InputID) async {}
}

/// An output seam that accepts nothing.
private struct NoOutputs: OutputRegistering {
    /// Never called.
    func register(_ provider: any StreamingServiceProvider) async throws {}

    /// Never called.
    func register(_ provider: any RecordingServiceProvider) async throws {}
}

/// An effect seam that accepts nothing.
private struct NoEffects: EffectRegistering {
    /// Never called.
    func register(_ provider: any AudioEffectProvider) async throws {}

    /// Never called.
    func register(_ provider: any VideoEffectProvider) async throws {}
}

/// A tool seam that accepts nothing.
private struct NoTools: ToolRegistering {
    /// Never called.
    func register(_ tool: any Tool) async throws {}
}
