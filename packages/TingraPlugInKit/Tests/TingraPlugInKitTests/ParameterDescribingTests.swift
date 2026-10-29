//
//  ParameterDescribingTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing

@testable import TingraPlugInKit

/// An input with no settings — it declares no parameters and leaves
/// `setParameters` to its default.
private struct SilentInput: Input {
    let id = InputID(rawValue: "silent")
    let name = "Silent"
    let kind = InputKind.generator

    func start() async throws {}
    func stop() async {}
}

/// An input that declares one parameter and records the payloads it is
/// handed, standing in for a generator with a settings pane.
private final class TunableInput: Input, Sendable {
    let id = InputID(rawValue: "tunable")
    let name = "Tunable"
    let kind = InputKind.generator
    let parameters = [Parameter(key: "frequencyHertz", name: "Frequency", range: 20...20_000, defaultValue: 440)]

    /// Every payload `setParameters` received, in order.
    let received = Mutex<[[String: JSONValue]]>([])

    func start() async throws {}
    func stop() async {}

    func setParameters(_ parameters: [String: JSONValue]) async {
        received.withLock { $0.append(parameters) }
    }
}

/// A streaming provider that declares nothing, standing in for the RTMP
/// output as it is today.
private struct PlainStreamingProvider: StreamingServiceProvider {
    let id = OutputID(rawValue: "plain")
    let name = "Plain"
    let schemes = ["plain"]

    func makeStreamingService(configuration: StreamConfiguration) -> any StreamingService {
        UnstartableService()
    }
}

/// A recording provider declaring one parameter, standing in for a
/// container option a future recorder exposes.
private struct OptionedRecordingProvider: RecordingServiceProvider {
    let id = OutputID(rawValue: "optioned")
    let name = "Optioned"
    let fileExtensions = ["opt"]
    let parameters = [Parameter(key: "chapters", name: "Chapters", range: 0...1, defaultValue: 0)]

    func makeRecordingService(configuration: StreamConfiguration) -> any RecordingService {
        UnstartableRecorder()
    }
}

/// A streaming service the tests never start.
private struct UnstartableService: StreamingService {
    var events: AsyncStream<StreamingServiceEvent> { AsyncStream { $0.finish() } }
    func start(to destination: Destination) async throws {}
    func send(video frame: CapturedFrame) async {}
    func send(audio buffer: CapturedAudio) async {}
    func statistics() async -> StreamingStatistics {
        StreamingStatistics(bytesSent: 0, bytesPerSecond: 0, framesPerSecond: 0)
    }
    func stop() async {}
}

/// A recording service the tests never start.
private struct UnstartableRecorder: RecordingService {
    var events: AsyncStream<RecordingServiceEvent> { AsyncStream { $0.finish() } }
    func start(to file: RecordingFile) async throws {}
    func send(video frame: CapturedFrame) async {}
    func send(audio buffer: CapturedAudio) async {}
    func stop() async {}
}

@Suite("Declared parameters on every registration")
struct ParameterDescribingTests {
    @Test("an input that declares nothing reports no parameters")
    func inputDeclaresNothingByDefault() {
        #expect(SilentInput().parameters.isEmpty)
    }

    @Test("setParameters defaults to doing nothing, so an input without settings needs no override")
    func inputSetParametersDefaultIsHarmless() async {
        let input = SilentInput()
        await input.setParameters(["anything": .int(1)])
        #expect(input.parameters.isEmpty)
    }

    @Test("an input that declares parameters reports them and receives their values")
    func inputDeclaresAndReceives() async {
        let input = TunableInput()
        #expect(input.parameters.map(\.key) == ["frequencyHertz"])
        await input.setParameters(["frequencyHertz": .double(1000)])
        #expect(input.received.withLock { $0 } == [["frequencyHertz": .double(1000)]])
    }

    @Test("a streaming provider declares no parameters unless it says otherwise")
    func streamingProviderDefaultsToNone() {
        #expect(PlainStreamingProvider().parameters.isEmpty)
    }

    @Test("a recording provider's declared parameters are reported in order")
    func recordingProviderDeclares() {
        #expect(OptionedRecordingProvider().parameters.map(\.key) == ["chapters"])
    }

    @Test("a destination carries no parameter values unless given some")
    func destinationParametersDefaultEmpty() throws {
        let url = try #require(URL(string: "rtmp://example.invalid/app"))
        #expect(Destination(url: url).parameters.isEmpty)
        let tuned = Destination(url: url, streamKey: "k", parameters: ["name": .string("Program")])
        #expect(tuned.parameters == ["name": .string("Program")])
        #expect(tuned.streamKey == "k")
    }

    @Test("a recording file carries its provider's parameter values beside the container")
    func recordingFileParameters() {
        let file = RecordingFile(url: URL(filePath: "/tmp/take.mov"), container: .mov)
        #expect(file.parameters.isEmpty)
        let optioned = RecordingFile(url: file.url, container: .mov, parameters: ["chapters": .bool(true)])
        #expect(optioned.parameters == ["chapters": .bool(true)])
        #expect(optioned != file)
        #expect(RecordingFile(url: file.url, container: .mov) == file)
    }

    @Test("a parameter reads its value from a payload, widening an integer and defaulting a missing or foreign key")
    func parameterValueInPayload() {
        let frequency = Parameter(key: "frequencyHertz", name: "Frequency", range: 20...20_000, defaultValue: 440)
        #expect(frequency.value(in: ["frequencyHertz": .double(880)]) == 880)
        #expect(frequency.value(in: ["frequencyHertz": .int(1000)]) == 1000)
        #expect(frequency.value(in: [:]) == 440)
        #expect(frequency.value(in: ["frequencyHertz": .string("loud")]) == 440)
    }

    @Test("a parameter clamps a value into its declared range and leaves one inside it alone")
    func parameterClamps() {
        let level = Parameter(key: "levelDecibels", name: "Level", range: -60...0, defaultValue: -6)
        #expect(level.clamped(-80) == -60)
        #expect(level.clamped(3) == 0)
        #expect(level.clamped(-12) == -12)
    }

    @Test("a color parameter reads its color from a payload and a numeric one has none")
    func parameterColorInPayload() {
        let border = Parameter(key: "borderColor", name: "Border", defaultColor: .white)
        let red = ParameterColor(red: 1, green: 0, blue: 0)
        #expect(border.color(in: ["borderColor": red.jsonValue]) == red)
        #expect(border.color(in: [:]) == .white)
        #expect(border.color(in: ["borderColor": .int(3)]) == .white)
        let gain = Parameter(key: "gainDecibels", name: "Gain", range: -60...6, defaultValue: 0)
        #expect(gain.color(in: [:]) == nil)
    }

    @Test("currentParameters defaults to an empty payload, for an input whose settings live in the host")
    func currentParametersDefaultsToEmpty() async {
        #expect(await SilentInput().currentParameters().isEmpty)
        #expect(await TunableInput().currentParameters().isEmpty)
    }

    @Test("a toggle reads a boolean, reads a number as on when non-zero, and defaults otherwise")
    func toggleReadsItsPayload() {
        let auto = Parameter(key: "whiteBalanceAuto", name: "Auto White Balance", defaultIsOn: true)
        #expect(auto.kind == .toggle)
        #expect(auto.range == 0...1)
        #expect(auto.defaultValue == 1)
        #expect(auto.isOn(in: [:]) == true)
        #expect(auto.isOn(in: ["whiteBalanceAuto": .bool(false)]) == false)
        #expect(auto.isOn(in: ["whiteBalanceAuto": .int(0)]) == false)
        #expect(auto.isOn(in: ["whiteBalanceAuto": .double(1)]) == true)
        #expect(auto.isOn(in: ["whiteBalanceAuto": .string("off")]) == true)
        let off = Parameter(key: "focusAuto", name: "Auto Focus", defaultIsOn: false)
        #expect(off.isOn(in: [:]) == false)
        let gain = Parameter(key: "gainDecibels", name: "Gain", range: -60...6, defaultValue: 0)
        #expect(gain.isOn(in: ["gainDecibels": .bool(true)]) == nil)
    }

    @Test("section and automatic toggle default to nil and are set by modifiers")
    func modifiersSetSectionAndAutomaticToggle() {
        let plain = Parameter(key: "brightness", name: "Brightness", range: 0...255, defaultValue: 128)
        #expect(plain.section == nil)
        #expect(plain.automaticToggleKey == nil)
        let grouped = plain.inSection("Image")
        #expect(grouped.section == "Image")
        #expect(grouped.key == plain.key)
        let governed = plain.controlledAutomatically(whenOn: "exposureAuto")
        #expect(governed.automaticToggleKey == "exposureAuto")
        #expect(governed.section == nil)
    }

    @Test("parameters that differ only in section or automatic toggle are not equal")
    func sectionAndAutomaticToggleTakePartInEquality() {
        let plain = Parameter(key: "brightness", name: "Brightness", range: 0...255, defaultValue: 128)
        #expect(plain == Parameter(key: "brightness", name: "Brightness", range: 0...255, defaultValue: 128))
        #expect(plain != plain.inSection("Image"))
        #expect(plain != plain.controlledAutomatically(whenOn: "exposureAuto"))
        #expect(plain.inSection("Image") == plain.inSection("Image"))
    }

    @Test("a stepped parameter snaps to the nearest step from the bottom of its range, never to -0")
    func steppedParameterSnaps() {
        let pan = Parameter(key: "pan", name: "Pan", range: -10...10, defaultValue: 0, unit: "°").stepped(by: 1)
        #expect(pan.step == 1)
        #expect(pan.snapped(-0.003) == 0)
        #expect(pan.snapped(-0.003).sign == .plus)
        #expect(pan.snapped(2.6) == 3)
        #expect(pan.snapped(40) == 10)
        let temperature = Parameter(key: "kelvin", name: "Temperature", range: 2000...7500, defaultValue: 5000)
            .stepped(by: 10)
        #expect(temperature.snapped(5103) == 5100)
        #expect(temperature.snapped(5106) == 5110)
    }

    @Test("a parameter without a step, or with a step that is not positive, stays continuous")
    func unsteppedParameterIsContinuous() {
        let gain = Parameter(key: "gain", name: "Gain", range: -60...6, defaultValue: 0)
        #expect(gain.step == nil)
        #expect(gain.snapped(-0.25) == -0.25)
        #expect(gain.snapped(9) == 6)
        #expect(gain.stepped(by: 0).step == nil)
        #expect(gain.stepped(by: -1).step == nil)
        #expect(gain != gain.stepped(by: 1))
    }

    @Test("a governed parameter is automatic exactly while its toggle is on")
    func governedParameterFollowsItsToggle() {
        let auto = Parameter(key: "whiteBalanceAuto", name: "Auto White Balance", defaultIsOn: true)
        let temperature = Parameter(
            key: "whiteBalanceTemperature", name: "Temperature", range: 2000...7500, defaultValue: 5000, unit: "K"
        ).controlledAutomatically(whenOn: "whiteBalanceAuto")
        let parameters = [auto, temperature]
        #expect(temperature.isControlledAutomatically(in: [:], among: parameters))
        #expect(!temperature.isControlledAutomatically(in: ["whiteBalanceAuto": .bool(false)], among: parameters))
        #expect(!temperature.isControlledAutomatically(in: [:], among: [temperature]))
        #expect(!auto.isControlledAutomatically(in: [:], among: parameters))
    }
}
