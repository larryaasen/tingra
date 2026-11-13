//
//  ApplicationAudioInputTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreAudio
import CoreMedia
import Synchronization
import Testing
import TingraApplicationAudio
import TingraEventBus
import TingraPlugInKit

@testable import TingraCapturePlugIns

/// The application the tests capture.
private let musicApp = CaptureApplication(bundleIdentifier: "com.example.music", name: "Music Maker")

/// The identifier the tests' input reports.
private let musicInputID = InputID(rawValue: "application-1")

/// A scripted tap seam: records each tap it starts and stops, can reject a
/// start, and lets a test deliver audio through the newest tap.
private final class FakeApplicationCaptures: Sendable {
    /// What one started tap was handed.
    struct Started: Sendable, Equatable {
        /// The processes tapped.
        let processes: [AudioObjectID]

        /// Whether it mutes them.
        let mutes: Bool
    }

    /// Every tap started, in order, with where its audio goes.
    private let started = Mutex<[(Started, @Sendable (CapturedAudio) -> Void)]>([])

    /// The start attempts (0 is the first) that throw.
    private let rejections: Set<Int>

    /// How many starts have been attempted.
    private let attempts = Mutex(0)

    /// The indices of the taps stopped, in order.
    private let stoppedIndices = Mutex<[Int]>([])

    /// Each start and stop as it happens, so a test can wait for one.
    let changes: AsyncStream<String>

    /// Feeds ``changes``.
    private let changeContinuation: AsyncStream<String>.Continuation

    /// Creates the seam.
    ///
    /// - Parameter rejections: The start attempts that throw.
    init(rejections: Set<Int> = []) {
        self.rejections = rejections
        (changes, changeContinuation) = AsyncStream.makeStream(of: String.self)
    }

    /// The capture seam the input is handed.
    var starter: ApplicationCaptureStarter {
        { [self] processes, mutes, _, id, deliver in
            let attempt = attempts.withLock { count in
                defer { count += 1 }
                return count
            }
            if rejections.contains(attempt) {
                throw CaptureInputError.configurationRejected(id, "the tap could not start")
            }
            let index = started.withLock { started in
                started.append((Started(processes: processes, mutes: mutes), deliver))
                return started.count - 1
            }
            changeContinuation.yield("started \(index)")
            return FakeApplicationCapture(index: index, owner: self)
        }
    }

    /// What each tap started was handed.
    var starts: [Started] { started.withLock { $0.map(\.0) } }

    /// The indices of the taps stopped.
    var stopped: [Int] { stoppedIndices.withLock { $0 } }

    /// Delivers audio through a tap.
    func deliver(_ audio: CapturedAudio, through index: Int) {
        started.withLock { $0[index].1 }(audio)
    }

    /// Records a stop.
    fileprivate func markStopped(_ index: Int) {
        stoppedIndices.withLock { $0.append(index) }
        changeContinuation.yield("stopped \(index)")
    }
}

/// One fake tap, reporting its stop to its seam.
private struct FakeApplicationCapture: ApplicationCapture {
    /// Its position among the taps started.
    let index: Int

    /// The seam that started it.
    let owner: FakeApplicationCaptures

    /// A fixed rate.
    var sampleRate: Double { 48_000 }

    /// Stereo.
    var channelCount: Int { 2 }

    func stop() {
        owner.markStopped(index)
    }
}

/// The scripted process list: what the next read returns, and whether it
/// throws.
private final class ProcessScript: Sendable {
    /// The application's processes.
    let processes: Mutex<[AudioObjectID]>

    /// Whether a read throws.
    let listingFails: Mutex<Bool>

    /// Creates the script.
    ///
    /// - Parameters:
    ///   - processes: The processes at the start.
    ///   - listingFails: Whether reads throw.
    init(processes: [AudioObjectID], listingFails: Bool) {
        self.processes = Mutex(processes)
        self.listingFails = Mutex(listingFails)
    }
}

/// An application input over the fakes, its bus, and its scripted process
/// list.
private struct ApplicationHarness {
    /// The input under test.
    let input: ApplicationAudioInput

    /// The taps it starts.
    let captures: FakeApplicationCaptures

    /// The bus's events, read in order.
    var events: AsyncStream<EventBusEvent>.Iterator

    /// The application's processes, as the next read returns them.
    let script: ProcessScript

    /// Scripts a change to the process list.
    let processChanges: AsyncStream<Void>.Continuation

    /// Builds the harness.
    ///
    /// - Parameters:
    ///   - processes: The application's processes at the start.
    ///   - listingFails: Whether reading the list throws.
    ///   - rejections: The tap starts that throw.
    init(processes: [AudioObjectID] = [], listingFails: Bool = false, rejections: Set<Int> = []) {
        let captures = FakeApplicationCaptures(rejections: rejections)
        let eventBus = EventBus()
        let script = ProcessScript(processes: processes, listingFails: listingFails)
        let (changes, processChanges) = AsyncStream.makeStream(of: Void.self)
        self.captures = captures
        self.events = eventBus.events().makeAsyncIterator()
        self.script = script
        self.processChanges = processChanges
        self.input = ApplicationAudioInput(
            application: musicApp,
            id: musicInputID,
            eventBus: eventBus,
            findProcesses: { bundleIdentifier in
                guard bundleIdentifier == musicApp.bundleIdentifier else { return [] }
                if script.listingFails.withLock({ $0 }) {
                    throw ApplicationAudioError.processListUnavailable(status: -1)
                }
                return script.processes.withLock { $0 }
            },
            processChanges: { changes },
            startCapture: captures.starter
        )
    }

    /// The next event the input reports.
    mutating func nextEvent() async -> EventBusEvent? {
        await events.next()
    }

    /// Sets the application's processes and announces the change.
    func setProcesses(_ processes: [AudioObjectID]) {
        script.processes.withLock { $0 = processes }
        processChanges.yield(())
    }
}

/// A small stereo buffer for delivery tests.
private func makeAudio() throws -> CapturedAudio {
    let buffer = ApplicationAudioBuffer(samples: [0.5, -0.5], channelCount: 2, sampleRate: 48_000, hostTime: 1_000)
    return try #require(ApplicationAudioInput.capturedAudio(from: buffer))
}

@Suite("Application audio input")
struct ApplicationAudioInputTests {
    @Test("an application input is an audio input of the application kind, named for its application")
    func identity() {
        let harness = ApplicationHarness()
        #expect(harness.input.id == musicInputID)
        #expect(harness.input.name == "Music Maker")
        #expect(harness.input.kind == .application)
        #expect(harness.input.media == .audio)
        #expect(harness.input.parameters.map(\.key) == ["mutesApplication"])
        #expect(harness.input.parameters.first?.kind == .toggle)
        #expect(harness.input.parameters.first?.isOn(in: [:]) == true)
    }

    @Test("a running application is tapped at start, muted by default")
    func tapsAtStart() async throws {
        let harness = ApplicationHarness(processes: [7, 8])
        var changes = harness.captures.changes.makeAsyncIterator()
        try await harness.input.start()
        #expect(await changes.next() == "started 0")
        #expect(harness.captures.starts == [.init(processes: [7, 8], mutes: true)])
        await harness.input.stop()
        #expect(await changes.next() == "stopped 0")
    }

    @Test("an application that is not running starts anyway and reports input.interrupted as a normal event")
    func missingApplicationWaits() async throws {
        var harness = ApplicationHarness()
        try await harness.input.start()

        let event = try #require(await harness.nextEvent())
        #expect(event.name == "input.interrupted")
        #expect(event.group == .event)
        #expect(event.params?["reason"] == .string("applicationUnavailable"))
        #expect(event.params?["id"] == .string(musicInputID.rawValue))
        #expect(event.params?["name"] == .string("Music Maker"))
        #expect(harness.captures.starts.isEmpty)
        await harness.input.stop()
    }

    @Test("the application's processes appearing start the tap and report input.resumed")
    func appearingResumes() async throws {
        var harness = ApplicationHarness()
        try await harness.input.start()
        #expect(await harness.nextEvent()?.name == "input.interrupted")

        harness.setProcesses([9])
        let resumed = try #require(await harness.nextEvent())
        #expect(resumed.name == "input.resumed")
        #expect(harness.captures.starts == [.init(processes: [9], mutes: true)])
        await harness.input.stop()
    }

    @Test("an application that quits stops the tap and reports input.interrupted")
    func quittingInterrupts() async throws {
        var harness = ApplicationHarness(processes: [7])
        try await harness.input.start()

        harness.setProcesses([])
        let event = try #require(await harness.nextEvent())
        #expect(event.name == "input.interrupted")
        #expect(event.params?["reason"] == .string("applicationUnavailable"))
        #expect(harness.captures.stopped == [0])
        await harness.input.stop()
    }

    @Test("a helper process joining rebuilds the tap over the new set without an interruption")
    func helperRebuilds() async throws {
        let harness = ApplicationHarness(processes: [7])
        var changes = harness.captures.changes.makeAsyncIterator()
        try await harness.input.start()
        #expect(await changes.next() == "started 0")

        harness.setProcesses([7, 12])
        #expect(await changes.next() == "stopped 0")
        #expect(await changes.next() == "started 1")
        #expect(harness.captures.starts.last == .init(processes: [7, 12], mutes: true))
        await harness.input.stop()
    }

    @Test("a process-list change that leaves the application's processes alone changes nothing")
    func unrelatedChangeIsIgnored() async throws {
        let harness = ApplicationHarness(processes: [7, 8])
        var changes = harness.captures.changes.makeAsyncIterator()
        try await harness.input.start()
        #expect(await changes.next() == "started 0")

        // The same set in another order, then a real change to prove the
        // first was handled before it.
        harness.setProcesses([8, 7])
        harness.setProcesses([8])
        #expect(await changes.next() == "stopped 0")
        #expect(await changes.next() == "started 1")
        #expect(harness.captures.starts.count == 2)
        await harness.input.stop()
    }

    @Test("start throws when the process list cannot be read")
    func listingThrows() async {
        let harness = ApplicationHarness(listingFails: true)
        await #expect(throws: CaptureInputError.self) {
            try await harness.input.start()
        }
    }

    @Test("start throws when the tap is refused")
    func refusedTapThrows() async {
        let harness = ApplicationHarness(processes: [7], rejections: [0])
        await #expect(throws: CaptureInputError.configurationRejected(musicInputID, "the tap could not start")) {
            try await harness.input.start()
        }
    }

    @Test("a tap that cannot start after the application returns reports input.resume as an error")
    func resumeErrorIsReported() async throws {
        var harness = ApplicationHarness(rejections: [0])
        try await harness.input.start()
        #expect(await harness.nextEvent()?.name == "input.interrupted")

        harness.setProcesses([9])
        let event = try #require(await harness.nextEvent())
        #expect(event.name == "input.resume")
        #expect(event.group == .error)
        await harness.input.stop()
    }

    @Test("audio from the tap reaches the input's stream, and the first reports input.format")
    func deliveryAndFirstAudio() async throws {
        var harness = ApplicationHarness(processes: [7])
        let stream = harness.input.audio()
        var audio = stream.makeAsyncIterator()
        try await harness.input.start()

        harness.captures.deliver(try makeAudio(), through: 0)
        harness.captures.deliver(try makeAudio(), through: 0)
        #expect(await audio.next() != nil)
        #expect(await audio.next() != nil)

        let event = try #require(await harness.nextEvent())
        #expect(event.name == "input.format")
        #expect(event.params?["kind"] == .string("application"))
        #expect(event.params?["sampleRate"] == .double(48_000))
        #expect(event.params?["channels"] == .int(2))

        await harness.input.stop()
        #expect(await audio.next() == nil)
    }

    @Test("turning muting off rebuilds a running tap unmuted")
    func mutingChangeRebuilds() async throws {
        let harness = ApplicationHarness(processes: [7])
        var changes = harness.captures.changes.makeAsyncIterator()
        try await harness.input.start()
        #expect(await changes.next() == "started 0")

        await harness.input.setParameters(["mutesApplication": .bool(false)])
        #expect(await changes.next() == "stopped 0")
        #expect(await changes.next() == "started 1")
        #expect(harness.captures.starts.last == .init(processes: [7], mutes: false))
        #expect(await harness.input.currentParameters() == ["mutesApplication": .bool(false)])

        // The same value again changes nothing; a real change proves it.
        await harness.input.setParameters(["mutesApplication": .bool(false)])
        await harness.input.setParameters([:])
        #expect(await changes.next() == "stopped 1")
        #expect(await changes.next() == "started 2")
        #expect(harness.captures.starts.last == .init(processes: [7], mutes: true))
        await harness.input.stop()
    }

    @Test("a muting setting applied before start is the first tap's")
    func mutingBeforeStart() async throws {
        let harness = ApplicationHarness(processes: [7])
        #expect(await harness.input.currentParameters() == ["mutesApplication": .bool(true)])
        await harness.input.setParameters(["mutesApplication": .bool(false)])
        try await harness.input.start()
        #expect(harness.captures.starts == [.init(processes: [7], mutes: false)])
        await harness.input.stop()
    }

    @Test("stop releases the tap and may be called twice")
    func stopTwice() async throws {
        let harness = ApplicationHarness(processes: [7])
        var changes = harness.captures.changes.makeAsyncIterator()
        try await harness.input.start()
        #expect(await changes.next() == "started 0")
        await harness.input.stop()
        await harness.input.stop()
        #expect(await changes.next() == "stopped 0")
        #expect(harness.captures.stopped == [0])
    }

    @Test("a tap's copy becomes deinterleaved float audio stamped with its host time")
    func conversion() throws {
        let buffer = ApplicationAudioBuffer(
            samples: [0.1, -0.1, 0.2, -0.2, 0.3, -0.3], channelCount: 2, sampleRate: 48_000, hostTime: 123_456_789)
        let audio = try #require(ApplicationAudioInput.capturedAudio(from: buffer))
        #expect(audio.presentationTime == CMClockMakeHostTimeFromSystemUnits(123_456_789))
        #expect(CMSampleBufferGetNumSamples(audio.sampleBuffer) == 3)

        let description = try #require(CMSampleBufferGetFormatDescription(audio.sampleBuffer))
        let format = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(format.mSampleRate == 48_000)
        #expect(format.mChannelsPerFrame == 2)
        #expect(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)

        let pcm = try #require(
            AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(cmAudioFormatDescription: description), frameCapacity: 3))
        pcm.frameLength = 3
        #expect(
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                audio.sampleBuffer, at: 0, frameCount: 3, into: pcm.mutableAudioBufferList) == noErr)
        let channels = try #require(pcm.floatChannelData)
        #expect(Array(UnsafeBufferPointer(start: channels[0], count: 3)) == [0.1, 0.2, 0.3])
        #expect(Array(UnsafeBufferPointer(start: channels[1], count: 3)) == [-0.1, -0.2, -0.3])
    }

    @Test("a copy with no frames is skipped")
    func emptyConversion() {
        let buffer = ApplicationAudioBuffer(samples: [], channelCount: 2, sampleRate: 48_000, hostTime: 1)
        #expect(ApplicationAudioInput.capturedAudio(from: buffer) == nil)
    }
}

@Suite("Application audio provider")
struct ApplicationAudioProviderTests {
    @Test("the provider offers the applications it lists")
    func lists() async throws {
        let provider = ApplicationAudioProvider(eventBus: nil) { [musicApp] }
        #expect(try await provider.availableApplications() == [musicApp])
    }

    @Test("the provider passes on a listing that cannot be read")
    func listingError() async {
        let provider = ApplicationAudioProvider(eventBus: nil) {
            throw ApplicationListingError.unavailable("status -1")
        }
        await #expect(throws: ApplicationListingError.unavailable("status -1")) {
            _ = try await provider.availableApplications()
        }
        #expect(ApplicationListingError.unavailable("status -1").description.contains("status -1"))
    }

    @Test("the provider makes an application input reporting the project's identifier")
    func makesInput() {
        let input = ApplicationAudioProvider().makeInput(for: musicApp, id: musicInputID)
        #expect(input.id == musicInputID)
        #expect(input.kind == .application)
        #expect(input.name == "Music Maker")
    }

    @Test("application records compare equal only when both fields match")
    func equality() {
        #expect(musicApp == CaptureApplication(bundleIdentifier: "com.example.music", name: "Music Maker"))
        #expect(musicApp != CaptureApplication(bundleIdentifier: "com.example.other", name: "Music Maker"))
        #expect(musicApp != CaptureApplication(bundleIdentifier: "com.example.music", name: "Other"))
        #expect(musicApp.id == "com.example.music")
    }
}
