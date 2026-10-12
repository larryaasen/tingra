//
//  StreamResumeOfferTests.swift
//  TingraAppTests
//
//  Created by Larry Aasen on 2026-10-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraComposition
import TingraEventBus
import TingraHost

@testable import TingraApp

/// A record over a temporary folder of its own.
private func temporaryRecord() -> LiveStreamRecord {
    LiveStreamRecord(directory: URL.temporaryDirectory.appending(path: "tingra-live-\(UUID().uuidString)"))
}

/// Removes a temporary record's folder.
private func discard(_ record: LiveStreamRecord) {
    try? FileManager.default.removeItem(at: record.fileURL.deletingLastPathComponent())
}

/// The events sent on a throwaway bus, as the model's observer would drain
/// them.
private func events(_ send: (EventBus) -> Void) async -> [EventBusEvent] {
    let eventBus = EventBus()
    let stream = eventBus.events()
    send(eventBus)
    eventBus.shutdown()
    var received: [EventBusEvent] = []
    for await event in stream {
        received.append(event)
    }
    return received
}

/// A project file and a whole-second time, as a record holds them.
private let projectURL = URL(filePath: "/Users/operator/Shows/Friday.tingra")
private let wentLive = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
@Suite("LiveStreamRecord")
struct LiveStreamRecordTests {
    /// What a stream to two destinations records.
    private let contents = LiveStreamRecord.Contents(
        project: projectURL, destinations: ["twitch", "youtube"], wentLive: wentLive)

    @Test("no file is no record")
    func missingFileIsNoRecord() {
        #expect(temporaryRecord().read() == nil)
    }

    @Test("the stream written is the stream read, until the record is removed")
    func writeReadRemove() {
        let record = temporaryRecord()
        defer { discard(record) }

        record.write(contents)
        let read = record.read()
        record.remove()

        #expect(read == contents)
        #expect(record.read() == nil)
        #expect(record.fileURL.lastPathComponent == "live-stream.json")
    }

    @Test("a file that does not decode reads as no record")
    func undecodableFileIsNoRecord() throws {
        let record = temporaryRecord()
        defer { discard(record) }
        try FileManager.default.createDirectory(
            at: record.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: record.fileURL)

        #expect(record.read() == nil)
    }

    @Test("the file holds the project, the destination IDs, and the time, and nothing else")
    func fileShape() throws {
        let record = temporaryRecord()
        defer { discard(record) }
        record.write(contents)

        let data = try Data(contentsOf: record.fileURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["project", "destinations", "wentLive"])
        #expect(object["destinations"] as? [String] == ["twitch", "youtube"])
    }

    @Test("decoding throws for each missing key", arguments: ["project", "destinations", "wentLive"])
    func missingKeyThrows(key: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoder.encode(contents)) as? [String: Any])
        object[key] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        #expect(throws: DecodingError.self) {
            try decoder.decode(LiveStreamRecord.Contents.self, from: data)
        }
    }

    @Test("contents with a different project, destination, or time are not equal")
    func contentsInequality() {
        let other = URL(filePath: "/Users/operator/Shows/Saturday.tingra")

        #expect(
            contents
                == LiveStreamRecord.Contents(
                    project: projectURL, destinations: ["twitch", "youtube"], wentLive: wentLive))
        #expect(
            contents
                != LiveStreamRecord.Contents(project: other, destinations: ["twitch", "youtube"], wentLive: wentLive))
        #expect(
            contents != LiveStreamRecord.Contents(project: projectURL, destinations: ["twitch"], wentLive: wentLive))
        #expect(
            contents
                != LiveStreamRecord.Contents(
                    project: projectURL, destinations: ["twitch", "youtube"], wentLive: wentLive.addingTimeInterval(60))
        )
    }
}

@MainActor
@Suite("StreamResumeOffer")
struct StreamResumeOfferTests {
    /// An enabled destination with a streamable URL.
    private let twitch = DestinationEdit(
        id: ProjectDestinationID(rawValue: "twitch"), urlText: "rtmp://localhost/live", name: "Twitch")

    /// A second one.
    private let youtube = DestinationEdit(
        id: ProjectDestinationID(rawValue: "youtube"), urlText: "rtmps://localhost/live2", name: "YouTube")

    /// A record of a stream from the project to the named destinations.
    private func record(_ destinations: [String], project: URL = projectURL) -> LiveStreamRecord.Contents {
        LiveStreamRecord.Contents(project: project, destinations: destinations, wentLive: wentLive)
    }

    @Test("no record offers nothing")
    func noRecord() {
        #expect(StreamResumeOffer.decide(record: nil, projectURL: projectURL, destinations: [twitch]) == .none)
    }

    @Test("the same project with a recorded destination still streamable asks, naming it")
    func sameProjectAsks() {
        let offer = StreamResumeOffer.decide(
            record: record(["twitch", "youtube"]), projectURL: projectURL, destinations: [twitch, youtube])

        #expect(offer == .ask(destinations: [twitch, youtube], wentLive: wentLive))
    }

    @Test("the question names only the recorded destinations that are still streamable")
    func asksAboutRecordedStreamableOnly() {
        var disabled = youtube
        disabled.isEnabled = false
        let added = DestinationEdit(id: ProjectDestinationID(rawValue: "new"), urlText: "rtmp://localhost/other")

        let offer = StreamResumeOffer.decide(
            record: record(["twitch", "youtube"]), projectURL: projectURL, destinations: [twitch, disabled, added])

        #expect(offer == .ask(destinations: [twitch], wentLive: wentLive))
    }

    @Test("the same project file spelled another way is the same project")
    func projectIsComparedStandardized() {
        let spelled = URL(filePath: "/Users/operator/Shows/../Shows/Friday.tingra")

        let offer = StreamResumeOffer.decide(record: record(["twitch"]), projectURL: spelled, destinations: [twitch])

        #expect(offer == .ask(destinations: [twitch], wentLive: wentLive))
    }

    @Test("another project open is skipped as projectChanged")
    func projectChanged() {
        let other = URL(filePath: "/Users/operator/Shows/Saturday.tingra")

        let offer = StreamResumeOffer.decide(record: record(["twitch"]), projectURL: other, destinations: [twitch])

        #expect(offer == .skip(.projectChanged))
        #expect(StreamResumeOffer.SkipReason.projectChanged.rawValue == "projectChanged")
    }

    @Test("no recorded destination left enabled and streamable is skipped as noDestinations")
    func noDestinations() {
        var disabled = twitch
        disabled.isEnabled = false
        var unusable = twitch
        unusable.urlText = "rtm"

        for destinations in [[], [disabled], [unusable], [youtube]] {
            let offer = StreamResumeOffer.decide(
                record: record(["twitch"]), projectURL: projectURL, destinations: destinations)
            #expect(offer == .skip(.noDestinations))
        }
        #expect(StreamResumeOffer.SkipReason.noDestinations.rawValue == "noDestinations")
    }

    @Test("a resume streams only to the destinations named, never one added or enabled since")
    func resumeIsNarrowedToTheNamedDestinations() {
        let added = DestinationEdit(id: ProjectDestinationID(rawValue: "new"), urlText: "rtmp://localhost/other")
        var disabled = youtube
        disabled.isEnabled = false
        let all = [twitch, youtube, added]

        #expect(DestinationEdit.streamable(in: all) == all)
        #expect(DestinationEdit.streamable(in: all, only: [twitch.id]) == [twitch])
        #expect(DestinationEdit.streamable(in: [twitch, disabled], only: [twitch.id, youtube.id]) == [twitch])
        #expect(DestinationEdit.streamable(in: all, only: []).isEmpty)
    }

    @Test("the record names the destinations that went live, not one that rejected the connection")
    func rejectedDestinationIsNotRecorded() {
        var disabled = DestinationEdit(id: ProjectDestinationID(rawValue: "off"), urlText: "rtmp://localhost/off")
        disabled.isEnabled = false
        let all = [twitch, youtube, disabled]

        #expect(StreamResumeOffer.liveDestinationIDs(of: all, states: [:]) == ["twitch", "youtube"])
        #expect(
            StreamResumeOffer.liveDestinationIDs(of: all, states: [twitch.id: .live, youtube.id: .rejected])
                == ["twitch"])
        #expect(
            StreamResumeOffer.liveDestinationIDs(of: all, states: [twitch.id: .rejected, youtube.id: .rejected]).isEmpty
        )
    }

    @Test("each answer is its button's tap")
    func answerTaps() {
        #expect(StreamResumeOffer.Answer.resume.tapName == "streamResume.button")
        #expect(StreamResumeOffer.Answer.decline.tapName == "streamResumeDecline.button")
    }

    @Test("the alert names the destinations, then says a recording is not resumed")
    func informativeText() {
        let text = StreamResumeAlert.informativeText(destinations: ["Twitch", "YouTube"], wentLive: wentLive)

        #expect(text.contains("Twitch"))
        #expect(text.contains("YouTube"))
        #expect(text.hasSuffix("A recording is not resumed."))
    }
}

/// The model keeping the record: written when the stream goes live, removed
/// when it stops or the app quits, and read once at launch. The engine is
/// never started.
@MainActor
@Suite("EngineModel live stream record")
struct LiveStreamRecordModelTests {
    /// A model over a record in a temporary folder.
    private func makeModel() -> (EngineModel, LiveStreamRecord) {
        let record = temporaryRecord()
        return (EngineModel(monitor: SilentMonitor(), liveStreamRecord: record), record)
    }

    /// A record of a stream from a project to one destination.
    private func contents(project: URL) -> LiveStreamRecord.Contents {
        LiveStreamRecord.Contents(project: project, destinations: ["twitch"], wentLive: wentLive)
    }

    @Test("the stream session going live writes the record, naming the open project and no URL")
    func startedWrites() async throws {
        let (model, record) = makeModel()
        defer { discard(record) }

        for event in await events({ $0.event("stream.started", domain: .output) }) {
            model.handleStreamStatusEvent(event)
        }

        let read = try #require(record.read())
        #expect(read.project == model.projectURL)
        #expect(read.destinations.isEmpty)
    }

    @Test(
        "the stream stopping removes the record, whatever the reason",
        arguments: ["stopRequested", "durationElapsed", "connectionLost", "recordingFailed", nil] as [String?])
    func stoppedRemoves(reason: String?) async {
        let (model, record) = makeModel()
        defer { discard(record) }
        record.write(contents(project: model.projectURL))

        let params: [String: EventValue]? = reason.map { ["reason": .string($0)] }
        for event in await events({ $0.event("stream.stopped", domain: .output, params: params) }) {
            model.handleStreamStatusEvent(event)
        }

        #expect(record.read() == nil)
    }

    @Test("every stop reason the session can report is covered")
    func stopReasonsAreTheSessionsOutcomes() {
        let outcomes: [StreamSession.Outcome] = [.stopRequested, .durationElapsed, .connectionLost, .recordingFailed]

        #expect(
            outcomes.map(\.rawValue) == ["stopRequested", "durationElapsed", "connectionLost", "recordingFailed"])
    }

    @Test("the recording session's own start and stop never touch the record")
    func recordingSessionIsIgnored() async {
        let (model, record) = makeModel()
        defer { discard(record) }
        let label: [String: EventValue] = ["session": .string(EngineModel.recordSessionLabel)]

        for event in await events({ $0.event("stream.started", domain: .output, params: label) }) {
            model.handleStreamStatusEvent(event)
        }
        #expect(record.read() == nil)

        let live = contents(project: model.projectURL)
        record.write(live)
        for event in await events({ $0.event("stream.stopped", domain: .output, params: label) }) {
            model.handleStreamStatusEvent(event)
        }
        #expect(record.read() == live)
    }

    @Test("a clean quit removes the record")
    func shutDownRemoves() async {
        let (model, record) = makeModel()
        defer { discard(record) }
        record.write(contents(project: model.projectURL))

        await model.shutDown(reason: .quit)

        #expect(record.read() == nil)
    }

    @Test("with no record, the launch asks nothing and reports nothing")
    func noRecordOffersNothing() async {
        let (model, record) = makeModel()
        defer { discard(record) }
        let stream = model.eventBus.events()
        var asked = false

        await model.offerStreamResume { _, _ in
            asked = true
            return .decline
        }
        model.eventBus.shutdown()
        var received: [EventBusEvent] = []
        for await event in stream { received.append(event) }

        #expect(!asked)
        #expect(received.isEmpty)
    }

    @Test("a record naming another project is removed without asking, and reported as projectChanged")
    func otherProjectIsSkipped() async {
        let (model, record) = makeModel()
        defer { discard(record) }
        record.write(contents(project: URL(filePath: "/Users/operator/Shows/Saturday.tingra")))
        let stream = model.eventBus.events()
        var asked = false

        await model.offerStreamResume { _, _ in
            asked = true
            return .resume
        }
        model.eventBus.shutdown()
        var received: [EventBusEvent] = []
        for await event in stream { received.append(event) }

        #expect(!asked)
        #expect(record.read() == nil)
        #expect(received.map(\.name) == ["stream.resumeSkipped"])
        #expect(received.first?.domain == .output)
        #expect(received.first?.params?["reason"] == .string("projectChanged"))
    }

    @Test("a record whose destinations are gone is removed without asking, and reported as noDestinations")
    func goneDestinationsAreSkipped() async {
        let (model, record) = makeModel()
        defer { discard(record) }
        record.write(contents(project: model.projectURL))
        let stream = model.eventBus.events()
        var asked = false

        await model.offerStreamResume { _, _ in
            asked = true
            return .resume
        }
        model.eventBus.shutdown()
        var received: [EventBusEvent] = []
        for await event in stream { received.append(event) }

        #expect(!asked)
        #expect(record.read() == nil)
        #expect(received.map(\.name) == ["stream.resumeSkipped"])
        #expect(received.first?.params?["reason"] == .string("noDestinations"))
    }
}
