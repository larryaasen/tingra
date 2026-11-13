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

    // MARK: Preset rows

    @Test("preset rows keep switcher order and carry the preset's identity and name")
    func presetRowsKeepOrderAndIdentity() {
        let rows = SidebarRow.rows(
            presets: [
                Preset(id: PresetID(rawValue: "b"), name: "Interview"),
                Preset(id: PresetID(rawValue: "a"), name: "Intro"),
            ],
            active: nil
        )

        #expect(rows.map(\.id) == ["b", "a"])
        #expect(rows.map(\.name) == ["Interview", "Intro"])
    }

    @Test("the active preset is the checked row, and it is the only one")
    func activePresetIsMarkedCurrent() {
        let rows = SidebarRow.rows(
            presets: [
                Preset(id: PresetID(rawValue: "a"), name: "Intro"),
                Preset(id: PresetID(rawValue: "b"), name: "Interview"),
                Preset(id: PresetID(rawValue: "c"), name: "Outro"),
            ],
            active: PresetID(rawValue: "b")
        )

        #expect(rows.map(\.isCurrent) == [false, true, false])
    }

    @Test("a preset row carries no tally")
    func presetRowsCarryNoTally() {
        let rows = SidebarRow.rows(
            presets: [Preset(id: PresetID(rawValue: "a"), name: "Intro")], active: PresetID(rawValue: "a"))

        // A preset is not on a bus: the active one is checked, never lit, so
        // red keeps meaning on program everywhere in the app.
        #expect(rows.map(\.tally) == [nil])
    }

    @Test("an unknown active preset leaves every row unchecked")
    func unmatchedActivePresetChecksNothing() {
        let rows = SidebarRow.rows(
            presets: [Preset(id: PresetID(rawValue: "a"), name: "Intro")],
            active: PresetID(rawValue: "gone")
        )

        #expect(rows.allSatisfy { !$0.isCurrent })
    }

    @Test("a project with no presets yields no rows")
    func noPresetsYieldsNoRows() {
        #expect(SidebarRow.rows(presets: [], active: nil).isEmpty)
    }

    // MARK: Destination rows

    @Test("destination rows keep panel order and carry the destination's identity")
    @MainActor
    func destinationRowsKeepOrderAndIdentity() {
        let rows = SidebarRow.rows(destinations: [
            DestinationEdit(id: ProjectDestinationID(rawValue: "b"), urlText: "rtmp://a.example/live", name: "Twitch"),
            DestinationEdit(
                id: ProjectDestinationID(rawValue: "a"), urlText: "rtmps://b.example/live", name: "YouTube"),
        ])

        #expect(rows.map(\.id) == ["b", "a"])
        #expect(rows.map(\.name) == ["Twitch", "YouTube"])
    }

    @Test("an unnamed destination is labeled by its URL")
    @MainActor
    func unnamedDestinationIsLabeledByURL() {
        let rows = SidebarRow.rows(destinations: [
            DestinationEdit(id: ProjectDestinationID(rawValue: "a"), urlText: "rtmp://a.example/live")
        ])

        // The panel's own label rule, reused rather than re-derived, so one
        // destination cannot read as two different things in two places.
        #expect(rows.map(\.name) == ["rtmp://a.example/live"])
    }

    @Test("a destination with neither name nor URL still has a label")
    @MainActor
    func emptyDestinationStillHasALabel() {
        let rows = SidebarRow.rows(destinations: [DestinationEdit()])

        // A brand new row is a real row, and a row with no label at all would
        // be a target the operator cannot identify or right-click with intent.
        #expect(rows.count == 1)
        #expect(rows[0].name.isEmpty == false)
    }

    @Test("a destination row carries no tally and no check")
    @MainActor
    func destinationRowsAreUnmarked() {
        let rows = SidebarRow.rows(destinations: [
            DestinationEdit(id: ProjectDestinationID(rawValue: "a"), urlText: "rtmp://a.example/live", name: "Twitch")
        ])

        // Live, reconnecting, rejected, and lost are four states a two-colour
        // lamp would flatten; the streaming panel reports them.
        #expect(rows.map(\.tally) == [nil])
        #expect(rows.allSatisfy { !$0.isCurrent })
    }

    @Test("a project with no destinations yields no rows")
    @MainActor
    func noDestinationsYieldsNoRows() {
        #expect(SidebarRow.rows(destinations: []).isEmpty)
    }

    @Test("an enabled destination with a streamable URL reads ready")
    @MainActor
    func enabledDestinationWithURLIsReady() {
        let rows = SidebarRow.rows(destinations: [
            DestinationEdit(id: ProjectDestinationID(rawValue: "a"), urlText: "rtmp://a.example/live", name: "Twitch")
        ])

        #expect(rows.map(\.destinationReadiness) == [.ready])
    }

    @Test("a destination turned off reads off, even with a streamable URL")
    @MainActor
    func disabledDestinationIsOff() {
        let rows = SidebarRow.rows(destinations: [
            DestinationEdit(
                id: ProjectDestinationID(rawValue: "a"),
                urlText: "rtmp://a.example/live",
                name: "Twitch",
                isEnabled: false
            )
        ])

        // The case that prompted the state: a fully configured destination
        // whose switch was off looked ready while Start Streaming sat gray.
        #expect(rows.map(\.destinationReadiness) == [.off])
    }

    @Test("an enabled destination with an empty or unsupported URL reads needs-URL")
    @MainActor
    func enabledDestinationWithoutURLNeedsURL() {
        let rows = SidebarRow.rows(destinations: [
            DestinationEdit(id: ProjectDestinationID(rawValue: "a"), urlText: "", name: "Twitch"),
            DestinationEdit(id: ProjectDestinationID(rawValue: "b"), urlText: "https://b.example/live", name: "Web"),
            DestinationEdit(id: ProjectDestinationID(rawValue: "c"), urlText: "rtm", name: "Typo"),
        ])

        #expect(rows.map(\.destinationReadiness) == [.needsURL, .needsURL, .needsURL])
    }

    @Test("off wins over a missing URL")
    @MainActor
    func offWinsOverMissingURL() {
        let rows = SidebarRow.rows(destinations: [
            DestinationEdit(id: ProjectDestinationID(rawValue: "a"), urlText: "", name: "Twitch", isEnabled: false)
        ])

        // The switch is the operator's own decision and the first thing to
        // change; the missing URL shows once it is back on.
        #expect(rows.map(\.destinationReadiness) == [.off])
    }

    @Test("a destination reads ready exactly when Start Streaming would stream to it")
    @MainActor
    func readinessMatchesIsStreamable() {
        let destinations = [
            DestinationEdit(id: ProjectDestinationID(rawValue: "a"), urlText: "rtmp://a.example/live"),
            DestinationEdit(id: ProjectDestinationID(rawValue: "b"), urlText: "srt://b.example:9000", isEnabled: false),
            DestinationEdit(id: ProjectDestinationID(rawValue: "c"), urlText: ""),
            DestinationEdit(id: ProjectDestinationID(rawValue: "d"), urlText: "rtmps://d.example/app"),
        ]

        let rows = SidebarRow.rows(destinations: destinations)

        // The sidebar and the Start control must agree on which destinations
        // count, or one of them is lying.
        #expect(rows.map { $0.destinationReadiness == .ready } == destinations.map(\.isStreamable))
    }

    @Test("rows outside the destination section carry no readiness")
    func nonDestinationRowsCarryNoReadiness() {
        let presetRows = SidebarRow.rows(presets: [Preset(name: "Main")], active: nil)

        #expect(presetRows.map(\.destinationReadiness) == [nil])
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

    @Test("display rows carry the input's tally, like the cameras")
    @MainActor
    func displayRowsCarryTheirTally() {
        let rows = SidebarRow.rows(
            from: Self.videoChoices,
            ofKind: .display,
            onProgram: [Self.input("display")],
            onPreview: []
        )

        #expect(rows.map(\.name) == ["Built-in Display"])
        #expect(rows.map(\.tally) == [.onAir])
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

    @Test("an application's audio row is listed by its own kind, with its mixer mark")
    func applicationRows() {
        let choices = Self.audioChoices + [Self.choice("app", "Music Maker", .application)]
        let strip = MixerStrip(id: InputID(rawValue: "app"), name: "Music Maker", level: 1, pan: 0, isMuted: true)
        let rows = SidebarRow.audioRows(from: choices, ofKind: .application, strips: [strip], onProgram: [])
        #expect(rows.map(\.id) == ["app"])
        #expect(rows.first?.isOnMixer == true)
        // Muted, so it feeds nothing and lights no lamp.
        #expect(rows.first?.tally == nil)
        #expect(
            SidebarRow.audioRows(from: choices, ofKind: .microphone, strips: [], onProgram: []).map(\.id) == ["mic"])
    }

    @Test("the audio generator section lists the tone and not the microphones")
    @MainActor
    func audioGeneratorSectionListsOnlyGenerators() {
        let rows = SidebarRow.rows(from: Self.audioChoices, ofKind: .generator)

        #expect(rows == [SidebarRow(id: "tone", name: "440 Hz Tone", tally: nil)])
    }

    @Test("the audio generator section leaves out the video generators")
    @MainActor
    func audioGeneratorSectionExcludesVideoGenerators() {
        let rows = SidebarRow.rows(from: Self.videoChoices, ofKind: .generator)

        // The two generator sections are told apart by the *media-role* list
        // each is handed — the model's audio and video lists — so the bars
        // cannot reach the audio section even though both are `.generator`.
        #expect(rows.map(\.id) == ["bars"])
    }

    @Test("an inert row carries no tally")
    @MainActor
    func inertRowsCarryNoTally() {
        #expect(SidebarRow.rows(from: Self.audioChoices, ofKind: .microphone).allSatisfy { $0.tally == nil })
        #expect(SidebarRow.rows(from: Self.audioChoices, ofKind: .generator).allSatisfy { $0.tally == nil })
        #expect(SidebarRow.rows(from: [AudioMonitorDevice(uid: "u", name: "n")]).allSatisfy { $0.tally == nil })
    }

    // MARK: Audio rows

    @Test("an audio row whose input has no strip carries no mark and no tally")
    @MainActor
    func audioRowOffTheMixerIsPlain() {
        let rows = SidebarRow.audioRows(from: Self.audioChoices, ofKind: .microphone, strips: [], onProgram: [])

        // Listed all the same: the section is the inventory the operator adds from.
        #expect(rows == [SidebarRow(id: "mic", name: "MacBook Pro Microphone", tally: nil)])
        #expect(rows.allSatisfy { !$0.isOnMixer })
    }

    @Test("an audio row whose strip is muted is marked on the mixer but unlit")
    @MainActor
    func audioRowWithAMutedStripIsMarkedButUnlit() {
        let strip = MixerStrip(id: Self.input("mic"), name: "MacBook Pro Microphone", level: 1, pan: 0, isMuted: true)

        let rows = SidebarRow.audioRows(from: Self.audioChoices, ofKind: .microphone, strips: [strip], onProgram: [])

        #expect(rows.map(\.isOnMixer) == [true])
        #expect(rows.map(\.tally) == [nil])
    }

    @Test("an audio row whose strip is unmuted lights the program tally")
    @MainActor
    func audioRowWithALiveStripIsOnAir() {
        let strip = MixerStrip(id: Self.input("tone"), name: "440 Hz Tone", level: 1, pan: 0, isMuted: false)

        let rows = SidebarRow.audioRows(from: Self.audioChoices, ofKind: .generator, strips: [strip], onProgram: [])

        #expect(rows == [SidebarRow(id: "tone", name: "440 Hz Tone", tally: .onAir, isOnMixer: true)])
    }

    @Test("an unmuted strip that follows video lights the tally only while its input is on program")
    @MainActor
    func audioRowFollowingVideoLightsOnlyOnProgram() {
        let strip = MixerStrip(
            id: Self.input("tone"), name: "440 Hz Tone", level: 1, pan: 0, isMuted: false, followsProgram: true)

        let offProgram = SidebarRow.audioRows(
            from: Self.audioChoices, ofKind: .generator, strips: [strip], onProgram: [])
        let onProgram = SidebarRow.audioRows(
            from: Self.audioChoices, ofKind: .generator, strips: [strip], onProgram: [Self.input("tone")])

        // Off program it is still on the mixer, just not reaching the mix.
        #expect(offProgram == [SidebarRow(id: "tone", name: "440 Hz Tone", tally: nil, isOnMixer: true)])
        #expect(onProgram == [SidebarRow(id: "tone", name: "440 Hz Tone", tally: .onAir, isOnMixer: true)])
    }

    @Test("a muted strip that follows video stays unlit even on program — mute wins")
    @MainActor
    func audioRowMutedFollowingVideoStaysUnlit() {
        let strip = MixerStrip(
            id: Self.input("tone"), name: "440 Hz Tone", level: 1, pan: 0, isMuted: true, followsProgram: true)

        let rows = SidebarRow.audioRows(
            from: Self.audioChoices, ofKind: .generator, strips: [strip], onProgram: [Self.input("tone")])

        #expect(rows.map(\.tally) == [nil])
    }

    @Test("a strip that does not follow video lights the tally whatever is on program")
    @MainActor
    func audioRowNotFollowingVideoIgnoresProgram() {
        let strip = MixerStrip(
            id: Self.input("mic"), name: "MacBook Pro Microphone", level: 1, pan: 0, isMuted: false,
            followsProgram: false)

        let rows = SidebarRow.audioRows(from: Self.audioChoices, ofKind: .microphone, strips: [strip], onProgram: [])

        #expect(rows.map(\.tally) == [.onAir])
    }

    @Test("audio rows keep the provenance split of the inert rows")
    @MainActor
    func audioRowsSplitByKind() {
        let strips = [MixerStrip(id: Self.input("mic"), name: "Mic", level: 1, pan: 0, isMuted: false)]

        #expect(
            SidebarRow.audioRows(from: Self.audioChoices, ofKind: .microphone, strips: strips, onProgram: []).map(\.id)
                == ["mic"])
        #expect(
            SidebarRow.audioRows(from: Self.audioChoices, ofKind: .generator, strips: strips, onProgram: []).map(\.id)
                == ["tone"])
    }

    @Test("rows differing only in their mixer mark compare not equal")
    @MainActor
    func mixerMarkAffectsEquality() {
        let plain = SidebarRow(id: "mic", name: "Mic", tally: nil)
        #expect(plain == SidebarRow(id: "mic", name: "Mic", tally: nil, isOnMixer: false))
        #expect(plain != SidebarRow(id: "mic", name: "Mic", tally: nil, isOnMixer: true))
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

    @Test("two rows are equal only when identifier, name, tally, and current mark all match")
    func equalityComparesEveryField() {
        let row = SidebarRow(id: "mic", name: "MacBook Pro Microphone", tally: nil)

        #expect(row == SidebarRow(id: "mic", name: "MacBook Pro Microphone", tally: nil))
        // A renamed device is a changed row — the sidebar redraws the name.
        #expect(row != SidebarRow(id: "mic", name: "External Microphone", tally: nil))
        #expect(row != SidebarRow(id: "mic-2", name: "MacBook Pro Microphone", tally: nil))
        // A lamp lighting is a changed row too, or it would never redraw.
        #expect(row != SidebarRow(id: "mic", name: "MacBook Pro Microphone", tally: .idle))
        // And so is a checkmark arriving, or a preset switch would leave the
        // check on the preset the operator switched away from.
        #expect(row != SidebarRow(id: "mic", name: "MacBook Pro Microphone", tally: nil, isCurrent: true))
    }
}
