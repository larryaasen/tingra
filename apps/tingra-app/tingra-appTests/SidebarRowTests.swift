//
//  SidebarRowTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraAudio
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

@Suite("SidebarRow")
struct SidebarRowTests {
    /// A discovered input, as the model's device lists carry it.
    @MainActor
    private static func choice(_ id: String, _ name: String, _ kind: InputKind) -> EngineModel.InputChoice {
        EngineModel.InputChoice(id: InputID(rawValue: id), name: name, kind: kind)
    }

    /// An input id.
    private static func input(_ id: String) -> InputID {
        InputID(rawValue: id)
    }

    /// A shot with one full-frame layer, named after it.
    private static func shot(_ id: String, _ name: String) -> Shot {
        Shot(id: ShotID(rawValue: id), name: name, layers: [Layer(input: input(id))])
    }

    /// The video inputs the app discovers once the first-party plug-ins are
    /// active: a camera among the video generators and a display.
    @MainActor
    private static var videoChoices: [EngineModel.InputChoice] {
        [
            choice("bars", "SMPTE Bars", .generator),
            choice("cam", "FaceTime HD Camera", .camera),
            choice("display", "Built-in Display", .display),
        ]
    }

    /// The audio inputs the app discovers: a microphone beside the tone
    /// generator, which is not a device.
    @MainActor
    private static var audioChoices: [EngineModel.InputChoice] {
        [
            choice("tone", "440 Hz Tone", .generator),
            choice("mic", "MacBook Pro Microphone", .microphone),
        ]
    }

    // MARK: Shot rows

    @Test("a shot on program reads on air, and the staged shot reads staged")
    func shotRowsCarryTheirTally() {
        let rows = SidebarRow.rows(
            shots: [Self.shot("a", "Wide"), Self.shot("b", "Close"), Self.shot("c", "Bars")],
            onProgram: ShotID(rawValue: "a"),
            onPreview: ShotID(rawValue: "b")
        )

        #expect(rows.map(\.tally) == [.onAir, .staged, .idle])
    }

    @Test("a shot both on program and staged reads on air")
    func programWinsOverStagedForShots() {
        let rows = SidebarRow.rows(
            shots: [Self.shot("a", "Wide")],
            onProgram: ShotID(rawValue: "a"),
            onPreview: ShotID(rawValue: "a")
        )

        // Red wins over green: what viewers see is the more urgent fact, and
        // the switcher reaches this state whenever a take leaves the shot
        // staged.
        #expect(rows.map(\.tally) == [.onAir])
    }

    @Test("shot rows keep switcher order and carry the shot's identity and name")
    func shotRowsKeepOrderAndIdentity() {
        let rows = SidebarRow.rows(
            shots: [Self.shot("b", "Close"), Self.shot("a", "Wide")],
            onProgram: nil,
            onPreview: nil
        )

        #expect(rows.map(\.id) == ["b", "a"])
        #expect(rows.map(\.name) == ["Close", "Wide"])
    }

    @Test("a preset with no shots yields no rows")
    func noShotsYieldsNoRows() {
        #expect(SidebarRow.rows(shots: [], onProgram: nil, onPreview: nil).isEmpty)
    }

    @Test("the shots section lists the operator's shots and leaves out the app's")
    func shotRowsExcludeAutomaticShots() {
        let automatic = Shot(
            id: ShotID(rawValue: "auto"),
            name: "Razer Kiyo Pro",
            layers: [Layer(input: Self.input("cam"))],
            origin: .automatic
        )

        let rows = SidebarRow.rows(
            shots: [Self.shot("a", "Wide"), automatic, Self.shot("b", "Close")],
            onProgram: nil,
            onPreview: nil
        )

        #expect(rows.map(\.id) == ["a", "b"])
    }

    @Test("an automatic shot on program still does not appear")
    func automaticShotOnProgramStillHidden() {
        let automatic = Shot(id: ShotID(rawValue: "auto"), name: "Razer Kiyo Pro", origin: .automatic)

        // Being on air makes it visible on the switcher and the monitors,
        // which is where an operator looks for what is live — never a reason
        // to add it to a list of the shots they made.
        #expect(SidebarRow.rows(shots: [automatic], onProgram: ShotID(rawValue: "auto"), onPreview: nil).isEmpty)
    }

    @Test("a preset of only automatic shots yields no rows")
    func onlyAutomaticShotsYieldsNoRows() {
        let automatic = Shot(id: ShotID(rawValue: "auto"), name: "Razer Kiyo Pro", origin: .automatic)

        #expect(SidebarRow.rows(shots: [automatic], onProgram: nil, onPreview: nil).isEmpty)
    }

    // MARK: Camera rows

    @Test("camera rows carry the input's tally")
    @MainActor
    func cameraRowsCarryTheirTally() {
        let rows = SidebarRow.rows(
            from: Self.videoChoices,
            ofKind: .camera,
            onProgram: [Self.input("cam")],
            onPreview: []
        )

        #expect(rows.map(\.name) == ["FaceTime HD Camera"])
        #expect(rows.map(\.tally) == [.onAir])
    }

    @Test("the generator section lists the patterns, not the cameras or displays")
    @MainActor
    func generatorRowsListOnlyGenerators() {
        let rows = SidebarRow.rows(from: Self.videoChoices, ofKind: .generator, onProgram: [], onPreview: [])

        #expect(rows.map(\.name) == ["SMPTE Bars"])
    }

    @Test("generator rows carry the input's tally")
    @MainActor
    func generatorRowsCarryTheirTally() {
        let rows = SidebarRow.rows(
            from: Self.videoChoices,
            ofKind: .generator,
            onProgram: [],
            onPreview: [Self.input("bars")]
        )

        #expect(rows.map(\.tally) == [.staged])
    }

    @Test("a camera on neither bus is unlit")
    @MainActor
    func idleCameraIsUnlit() {
        let rows = SidebarRow.rows(from: Self.videoChoices, ofKind: .camera, onProgram: [], onPreview: [])

        #expect(rows.map(\.tally) == [.idle])
    }

    // MARK: Inert device rows

    @Test("a section lists its own kind and nothing else")
    @MainActor
    func sectionListsOnlyItsOwnKind() {
        let rows = SidebarRow.rows(from: Self.videoChoices, ofKind: .camera)

        #expect(rows.map(\.name) == ["FaceTime HD Camera"])
    }

    @Test("the audio input section excludes the tone generator")
    @MainActor
    func audioSectionExcludesGenerators() {
        let rows = SidebarRow.rows(from: Self.audioChoices, ofKind: .microphone)

        // The section is a device list: a generator synthesizes its content
        // and is attached to no hardware, so it is not something plugged in.
        #expect(rows.map(\.id) == ["mic"])
    }

    @Test("an inert row carries no tally")
    @MainActor
    func inertRowsCarryNoTally() {
        #expect(SidebarRow.rows(from: Self.audioChoices, ofKind: .microphone).allSatisfy { $0.tally == nil })
        #expect(SidebarRow.rows(from: [AudioMonitorDevice(uid: "u", name: "n")]).allSatisfy { $0.tally == nil })
    }

    @Test("input rows keep the order they were given")
    @MainActor
    func inputRowsKeepCallerOrder() {
        let cameras = [
            Self.choice("b", "Studio Camera", .camera),
            Self.choice("a", "Continuity Camera", .camera),
        ]

        // The model sorts its device lists; the sidebar must not re-sort them
        // into a different order than the pickers show.
        #expect(SidebarRow.rows(from: cameras, ofKind: .camera).map(\.id) == ["b", "a"])
    }

    @Test("a row carries the device's identifier and name")
    @MainActor
    func rowCarriesIdentityAndName() {
        let rows = SidebarRow.rows(from: Self.videoChoices, ofKind: .display)

        #expect(rows == [SidebarRow(id: "display", name: "Built-in Display", tally: nil)])
    }

    @Test("no device of a kind yields no rows")
    @MainActor
    func missingKindYieldsNoRows() {
        #expect(SidebarRow.rows(from: Self.videoChoices, ofKind: .microphone).isEmpty)
    }

    @Test("an empty discovery list yields no rows")
    @MainActor
    func emptyDiscoveryYieldsNoRows() {
        #expect(SidebarRow.rows(from: [], ofKind: .camera).isEmpty)
        #expect(SidebarRow.rows(from: [AudioMonitorDevice]()).isEmpty)
    }

    // MARK: Output rows

    @Test("output rows come back in name order, not Core Audio's order")
    func outputRowsAreNameSorted() {
        let devices = [
            AudioMonitorDevice(uid: "uid-speakers", name: "MacBook Pro Speakers"),
            AudioMonitorDevice(uid: "uid-display", name: "Studio Display"),
            AudioMonitorDevice(uid: "uid-buds", name: "AirPods Pro"),
        ]

        let rows = SidebarRow.rows(from: devices)

        #expect(rows.map(\.name) == ["AirPods Pro", "MacBook Pro Speakers", "Studio Display"])
        #expect(rows.map(\.id) == ["uid-buds", "uid-speakers", "uid-display"])
    }

    @Test("an output row is identified by its Core Audio UID")
    func outputRowIsIdentifiedByUID() {
        let rows = SidebarRow.rows(from: [AudioMonitorDevice(uid: "uid-buds", name: "AirPods Pro")])

        #expect(rows == [SidebarRow(id: "uid-buds", name: "AirPods Pro", tally: nil)])
    }

    // MARK: Equality

    @Test("two rows are equal only when identifier, name, and tally all match")
    func equalityComparesEveryField() {
        let row = SidebarRow(id: "mic", name: "MacBook Pro Microphone", tally: nil)

        #expect(row == SidebarRow(id: "mic", name: "MacBook Pro Microphone", tally: nil))
        // A renamed device is a changed row — the sidebar redraws the name.
        #expect(row != SidebarRow(id: "mic", name: "External Microphone", tally: nil))
        #expect(row != SidebarRow(id: "mic-2", name: "MacBook Pro Microphone", tally: nil))
        // A lamp lighting is a changed row too, or it would never redraw.
        #expect(row != SidebarRow(id: "mic", name: "MacBook Pro Microphone", tally: .idle))
    }
}
