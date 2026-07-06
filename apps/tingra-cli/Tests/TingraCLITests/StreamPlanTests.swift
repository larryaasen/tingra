//
//  StreamPlanTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraCLI

/// A hardware-free stand-in for a real input, per the project's
/// generators-and-mocks testing rule.
private struct MockInput: Input {
    let id: InputID
    let name: String
    let kind: InputKind

    func start() async throws {}
    func stop() async {}
}

/// A registry loaded with the CLI.md example devices plus the built-in generators.
private func makeRegistry() async throws -> InputRegistry {
    let registry = InputRegistry()
    let fixtures = [
        MockInput(id: InputID(rawValue: "0x8020000005ac8514"), name: "FaceTime HD Camera", kind: .camera),
        MockInput(id: InputID(rawValue: "0x14100000046d085e"), name: "Logitech BRIO", kind: .camera),
        MockInput(id: InputID(rawValue: "BuiltInMicrophoneDevice"), name: "MacBook Pro Microphone", kind: .microphone),
        MockInput(id: InputID(rawValue: "AppleUSBAudioEngine:Shure:MV7"), name: "Shure MV7", kind: .microphone),
        MockInput(id: InputID(rawValue: "bars"), name: "SMPTE Bars", kind: .generator),
        MockInput(id: InputID(rawValue: "alignment"), name: "Alignment Pattern", kind: .generator),
        MockInput(id: InputID(rawValue: "pluge"), name: "PLUGE", kind: .generator),
        MockInput(id: InputID(rawValue: "pluge-strict"), name: "PLUGE Strict", kind: .generator),
        MockInput(id: InputID(rawValue: "tone"), name: "440 Hz Tone", kind: .generator),
    ]
    for fixture in fixtures {
        try await registry.register(fixture)
    }
    return registry
}

/// Defaults pointing at the built-in devices, like a stock MacBook.
private let builtInDefaults = SystemDefaultProvider(
    cameraID: { InputID(rawValue: "0x8020000005ac8514") },
    microphoneID: { InputID(rawValue: "BuiltInMicrophoneDevice") }
)

/// Defaults for a machine with nothing connected (a CI runner).
private let noDefaults = SystemDefaultProvider(cameraID: { nil }, microphoneID: { nil })

@Suite("StreamPlan resolution")
struct StreamPlanTests {
    @Test("no selectors resolve to the system default camera and microphone")
    func defaultsResolve() async throws {
        let plan = try await StreamPlan.resolve(
            request: StreamRequest(url: "rtmp://localhost/live"),
            registry: try await makeRegistry(),
            defaults: builtInDefaults
        )

        #expect(plan.video == StreamPlan.ResolvedInput(id: "0x8020000005ac8514", name: "FaceTime HD Camera"))
        #expect(plan.audio == StreamPlan.ResolvedInput(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"))
    }

    @Test("explicit selectors override the defaults")
    func selectorsOverrideDefaults() async throws {
        var request = StreamRequest(url: "rtmp://localhost/live")
        request.camera = "BRIO"
        request.mic = "MV7"

        let plan = try await StreamPlan.resolve(
            request: request,
            registry: try await makeRegistry(),
            defaults: builtInDefaults
        )

        #expect(plan.video?.name == "Logitech BRIO")
        #expect(plan.audio?.name == "Shure MV7")
    }

    @Test("generators resolve by their stable identifiers, no hardware involved")
    func generatorsResolve() async throws {
        var request = StreamRequest(url: "rtmp://localhost/live")
        request.videoGenerator = .alignment
        request.audioGenerator = .tone

        let plan = try await StreamPlan.resolve(
            request: request,
            registry: try await makeRegistry(),
            defaults: noDefaults
        )

        #expect(plan.video?.id == "alignment")
        #expect(plan.audio?.id == "tone")
    }

    @Test("--no-video and --no-audio leave that side unresolved")
    func disabledSidesStayNil() async throws {
        var request = StreamRequest(url: "rtmp://localhost/live")
        request.noVideo = true
        request.audioGenerator = .tone

        let plan = try await StreamPlan.resolve(
            request: request,
            registry: try await makeRegistry(),
            defaults: noDefaults
        )

        #expect(plan.video == nil)
        #expect(plan.audio?.id == "tone")
    }

    @Test("no selector and no connected default throws noDefaultInput")
    func missingDefaultThrows() async throws {
        let registry = try await makeRegistry()

        await #expect(throws: StreamPlanError.noDefaultInput(.camera)) {
            _ = try await StreamPlan.resolve(
                request: StreamRequest(url: "rtmp://localhost/live"),
                registry: registry,
                defaults: noDefaults
            )
        }
    }

    @Test("an unknown selector propagates the selector error")
    func unknownSelectorPropagates() async throws {
        var request = StreamRequest(url: "rtmp://localhost/live")
        request.camera = "Elgato"
        let registry = try await makeRegistry()

        await #expect(throws: InputSelectorError.notFound(selector: "Elgato", kind: .camera)) {
            _ = try await StreamPlan.resolve(request: request, registry: registry, defaults: builtInDefaults)
        }
    }

    @Test("noDefaultInput maps to the inputNotFound identifier and names the generator escape hatch")
    func noDefaultErrorShape() {
        let error = StreamPlanError.noDefaultInput(.microphone)
        #expect(error.identifier == .inputNotFound)
        #expect(String(describing: error).contains("--audio-generator tone"))
    }
}

@Suite("StreamPlan output")
struct StreamPlanOutputTests {
    /// A fully-populated plan over the generator inputs.
    private func makePlan() async throws -> StreamPlan {
        var request = StreamRequest(url: "rtmp://localhost/live")
        request.videoGenerator = .bars
        request.audioGenerator = .tone
        request.keySource = .environment
        request.duration = 30
        request.logFile = "/tmp/tingra.log"
        return try await StreamPlan.resolve(
            request: request,
            registry: try await makeRegistry(),
            defaults: noDefaults
        )
    }

    @Test("the stream.plan event params carry the full stable key set")
    func eventParamsAreStable() async throws {
        let params = try await makePlan().eventParams

        let expected: [String: EventValue] = [
            "url": .string("rtmp://localhost/live"),
            "keySource": .string("environment"),
            "reconnect": .int(3),
            "reconnectDelay": .int(2),
            "statsInterval": .int(5),
            "duration": .int(30),
            "logFile": .string("/tmp/tingra.log"),
            "videoInput": .string("bars"),
            "videoInputName": .string("SMPTE Bars"),
            "resolution": .string("1920x1080"),
            "fps": .int(30),
            "videoCodec": .string("h264"),
            "videoBitrate": .int(4_500_000),
            "keyframeInterval": .int(2),
            "audioInput": .string("tone"),
            "audioInputName": .string("440 Hz Tone"),
            "audioCodec": .string("aac"),
            "audioBitrate": .int(160_000),
            "audioSamplerate": .int(48_000),
        ]
        #expect(params == expected)
    }

    @Test("a disabled side is omitted from the event params entirely")
    func disabledSideOmitted() async throws {
        var request = StreamRequest(url: "rtmp://localhost/live")
        request.noVideo = true
        request.audioGenerator = .tone
        let plan = try await StreamPlan.resolve(
            request: request,
            registry: try await makeRegistry(),
            defaults: noDefaults
        )

        let params = plan.eventParams

        #expect(params["videoInput"] == nil)
        #expect(params["resolution"] == nil)
        #expect(params["fps"] == nil)
        #expect(params["audioInput"] == .string("tone"))
    }

    @Test("the stream key value never appears in event params, only its source")
    func keyNeverAppears() async throws {
        let params = try await makePlan().eventParams

        #expect(params["key"] == nil)
        #expect(params["keySource"] == .string("environment"))
    }

    @Test("the human plan names the inputs, the destination, and the dry-run promise")
    func humanPlanReadsRight() async throws {
        let text = try await makePlan().humanDescription

        #expect(text.contains("nothing started, nothing connected"))
        #expect(text.contains("rtmp://localhost/live"))
        #expect(text.contains("SMPTE Bars"))
        #expect(text.contains("440 Hz Tone"))
        #expect(text.contains("30s"))
        #expect(!text.contains("live_"))
    }
}
