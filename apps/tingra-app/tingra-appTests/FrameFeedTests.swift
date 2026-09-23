//
//  FrameFeedTests.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Synchronization
import Testing
import TingraAppPlugInKit
import TingraEventBus
import TingraJSONRPC
import TingraMCP
import TingraPlugInKit

@testable import TingraApp

/// A frame feed with no frames: a demand waits until its task is
/// cancelled. What every handler test that is not about frames is given.
final class NoFrames: PlugInFrameFeeding {
    func next(of bus: FrameBus, after sequence: UInt64) async -> PlugInFrameUpdate? {
        let (signal, _) = AsyncStream<Void>.makeStream()
        for await _ in signal {}
        return nil
    }
}

/// A frame feed over two real relays the test stores into, plus updates a
/// test scripts directly — an unbacked frame, which no relay can be made
/// to hold without building a buffer the engine never would.
private final class ScriptedFrames: PlugInFrameFeeding {
    /// The relays, as the app wires them.
    let relays = RelayFrameFeed(program: ProgramFrameRelay(), preview: ProgramFrameRelay())

    /// Updates answered before the relays are asked, in order.
    let scripted = Mutex<[PlugInFrameUpdate]>([])

    func next(of bus: FrameBus, after sequence: UInt64) async -> PlugInFrameUpdate? {
        if let next = scripted.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return next }
        return await relays.next(of: bus, after: sequence)
    }
}

/// An IOSurface-backed BGRA frame at `seconds`, the working format.
private func makeFrame(at seconds: Double) throws -> CapturedFrame {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 9, kCVPixelFormatType_32BGRA, attributes, &buffer)
    return CapturedFrame(
        pixelBuffer: try #require(buffer), presentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
}

/// The relay's numbered changes: what lets a frame reach another process
/// the moment it exists.
@Suite("ProgramFrameRelay changes")
struct ProgramFrameRelayChangesTests {
    @Test("a relay that already changed answers at once with its newest frame")
    func answersAtOnce() async throws {
        let relay = ProgramFrameRelay()
        relay.store(try makeFrame(at: 1))
        relay.store(try makeFrame(at: 2))
        let update = try #require(await relay.next(after: 0))
        #expect(update.sequence == 2)
        #expect(update.frame?.presentationTime.seconds == 2)
    }

    @Test("a caller that has seen the newest change waits for the next frame")
    func waitsForNextFrame() async throws {
        let relay = ProgramFrameRelay()
        relay.store(try makeFrame(at: 1))
        let frame = try makeFrame(at: 2)
        let later = Task {
            try await Task.sleep(for: .milliseconds(30))
            relay.store(frame)
        }
        let update = try #require(await relay.next(after: 1))
        #expect(update.sequence == 2)
        #expect(update.frame?.presentationTime.seconds == 2)
        try await later.value
    }

    @Test("emptying the relay is a change of its own, and an empty relay turned off again is not")
    func emptyingIsAChange() async throws {
        let relay = ProgramFrameRelay()
        relay.store(try makeFrame(at: 1))
        relay.setAccepting(false)
        let update = try #require(await relay.next(after: 1))
        #expect(update.sequence == 2)
        #expect(update.frame == nil)
        relay.setAccepting(false)
        relay.store(try makeFrame(at: 3))  // Not accepting: dropped, no change.
        relay.setAccepting(true)
        relay.store(try makeFrame(at: 4))
        #expect(await relay.next(after: 2)?.sequence == 3)
    }

    @Test("a cancelled wait returns nil")
    func cancelledWait() async {
        let relay = ProgramFrameRelay()
        let waiting = Task { await relay.next(after: 0) }
        try? await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        #expect(await waiting.value == nil)
    }

    @Test("the relay feed surfaces the frame's own IOSurface and its time, and an empty bus as empty")
    func feedSurfacesFrame() async throws {
        let feed = RelayFrameFeed(program: ProgramFrameRelay(), preview: ProgramFrameRelay())
        let frame = try makeFrame(at: 5)
        feed.preview.store(frame)
        let update = try #require(await feed.next(of: .preview, after: 0))
        let surface = try #require(update.surface)
        let backing = try #require(CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue())
        #expect(IOSurfaceGetID(surface) == IOSurfaceGetID(backing))
        #expect(update.time == 5)
        #expect(!update.isEmpty)

        feed.preview.setAccepting(false)
        let emptied = try #require(await feed.next(of: .preview, after: update.sequence))
        #expect(emptied.isEmpty)
        #expect(emptied.surface == nil)
    }
}

/// The handler's half of `tingra/frame`: one frame per demand.
@Suite("PlugInMethodHandler frames")
struct PlugInMethodHandlerFramesTests {
    /// The plug-in every test speaks as.
    private let notes = PlugInID(rawValue: "com.moonwink.tingra.notes")

    /// The notifications a handler sent, with their surfaces.
    private final class Recorder: Sendable {
        /// What was sent: the method, its params, and the attachment.
        let sent = Mutex<[(method: String, params: JSONValue?, surface: IOSurface?)]>([])

        /// A notifier that records instead of writing to a transport.
        var notifier: SessionNotifier {
            SessionNotifier { method, params, surface in self.sent.withLock { $0.append((method, params, surface)) } }
        }

        /// Waits until `count` notifications were sent, or two seconds.
        func waitForCount(_ count: Int) async throws {
            for _ in 0..<400 where sent.withLock({ $0.count }) < count {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// A handler over `frames`.
    private func makeHandler(frames: any PlugInFrameFeeding, bus: EventBus = EventBus()) -> PlugInMethodHandler {
        PlugInMethodHandler(
            plugIn: notes, eventBus: bus, storage: NoStorage(), statusItems: StatusItemRegistry(),
            meters: MeterFeed(), frames: frames)
    }

    /// The params of a demand for `bus`.
    private func demand(_ bus: String) -> JSONValue {
        .object(["bus": .string(bus)])
    }

    @Test("a demand is answered at once, and the frame follows with its surface attached")
    func demandBringsFrame() async throws {
        let frames = ScriptedFrames()
        let recorder = Recorder()
        let handler = makeHandler(frames: frames)
        await handler.sessionOpened(notifier: recorder.notifier)
        let frame = try makeFrame(at: 7)
        frames.relays.program.store(frame)
        #expect(try await handler.respond(method: AppTierMethod.frameNext, params: demand("program")) == .object([:]))
        try await recorder.waitForCount(1)
        let sent = try #require(recorder.sent.withLock { $0.first })
        #expect(sent.method == AppTierMethod.frame)
        let read = try #require(BusFrame(jsonValue: sent.params, surface: sent.surface))
        #expect(read.bus == .program)
        #expect(read.time == 7)
        let backing = try #require(CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue())
        #expect(try IOSurfaceGetID(#require(read.surface)) == IOSurfaceGetID(backing))
        await handler.sessionClosed()
    }

    @Test("the next demand waits for a newer frame, and demands made meanwhile bring only one")
    func oneFramePerDemand() async throws {
        let frames = ScriptedFrames()
        let recorder = Recorder()
        let handler = makeHandler(frames: frames)
        await handler.sessionOpened(notifier: recorder.notifier)
        frames.relays.program.store(try makeFrame(at: 1))
        _ = try await handler.respond(method: AppTierMethod.frameNext, params: demand("program"))
        try await recorder.waitForCount(1)

        _ = try await handler.respond(method: AppTierMethod.frameNext, params: demand("program"))
        _ = try await handler.respond(method: AppTierMethod.frameNext, params: demand("program"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.sent.withLock { $0.count } == 1)

        frames.relays.program.store(try makeFrame(at: 2))
        frames.relays.program.store(try makeFrame(at: 3))
        try await recorder.waitForCount(2)
        try await Task.sleep(for: .milliseconds(30))
        let sent = recorder.sent.withLock { $0 }
        #expect(sent.count == 2)
        #expect(BusFrame(jsonValue: sent.last?.params, surface: sent.last?.surface)?.time ?? 0 >= 2)
        await handler.sessionClosed()
    }

    @Test("a bus that emptied is sent as an empty frame with no surface")
    func emptiedBus() async throws {
        let frames = ScriptedFrames()
        let recorder = Recorder()
        let handler = makeHandler(frames: frames)
        await handler.sessionOpened(notifier: recorder.notifier)
        frames.relays.preview.store(try makeFrame(at: 1))
        frames.relays.preview.setAccepting(false)
        _ = try await handler.respond(method: AppTierMethod.frameNext, params: demand("preview"))
        try await recorder.waitForCount(1)
        let sent = try #require(recorder.sent.withLock { $0.first })
        #expect(sent.surface == nil)
        #expect(sent.params?["empty"] == .bool(true))
        #expect(sent.params?["bus"] == .string("preview"))
        await handler.sessionClosed()
    }

    @Test("a frame with no surface behind it is reported once and skipped for the next that has one")
    func unbackedFrameSkipped() async throws {
        let frames = ScriptedFrames()
        frames.scripted.withLock {
            $0 = [
                PlugInFrameUpdate(sequence: 1, isEmpty: false, surface: nil, time: 1),
                PlugInFrameUpdate(sequence: 2, isEmpty: false, surface: nil, time: 2),
            ]
        }
        let bus = EventBus()
        let events = bus.events()
        let recorder = Recorder()
        let handler = makeHandler(frames: frames, bus: bus)
        await handler.sessionOpened(notifier: recorder.notifier)
        for _ in 0..<3 {
            frames.relays.program.store(try makeFrame(at: 9))
        }
        _ = try await handler.respond(method: AppTierMethod.frameNext, params: demand("program"))
        try await recorder.waitForCount(1)
        #expect(recorder.sent.withLock { $0.first?.surface } != nil)
        await handler.sessionClosed()
        bus.shutdown()
        var names: [String] = []
        for await event in events {
            names.append("\(event.group.rawValue):\(event.name)")
        }
        #expect(names == ["event:plugin.frames.started", "error:plugin.frames"])
    }

    @Test("a demand without a bus, or of a bus the app does not have, is invalid params")
    func invalidBus() async throws {
        let handler = makeHandler(frames: NoFrames())
        await handler.sessionOpened(notifier: Recorder().notifier)
        for params: JSONValue? in [nil, .object([:]), demand("multiview"), .object(["bus": .int(1)])] {
            do {
                _ = try await handler.respond(method: AppTierMethod.frameNext, params: params)
                Issue.record("expected invalid params")
            } catch let error as JSONRPCError {
                #expect(error.code == JSONRPCErrorCode.invalidParams.rawValue)
                #expect(error.message.contains("program or preview"))
            }
        }
    }

    @Test("a demand before the session opened returns an internal error, and the session closing ends a waiting one")
    func lifecycle() async throws {
        let handler = makeHandler(frames: NoFrames())
        do {
            _ = try await handler.respond(method: AppTierMethod.frameNext, params: demand("program"))
            Issue.record("expected an internal error")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.internalError.rawValue)
        }
        let recorder = Recorder()
        await handler.sessionOpened(notifier: recorder.notifier)
        _ = try await handler.respond(method: AppTierMethod.frameNext, params: demand("program"))
        await handler.sessionClosed()
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.sent.withLock { $0.isEmpty })
    }
}

/// A store that keeps nothing: the frames tests never touch storage.
private final class NoStorage: PlugInStoring {
    func value(scope: StorageScope, plugIn: PlugInID) async -> JSONValue? { nil }

    func setValue(_ value: JSONValue?, scope: StorageScope, plugIn: PlugInID) async {}

    func secret(named name: String, plugIn: PlugInID) async throws -> String? { nil }

    func setSecret(_ secret: String?, named name: String, plugIn: PlugInID) async throws {}
}
