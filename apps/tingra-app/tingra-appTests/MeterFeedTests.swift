//
//  MeterFeedTests.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Synchronization
import Testing
import TingraAppPlugInKit
import TingraAudio
import TingraEventBus
import TingraJSONRPC
import TingraMCP
import TingraPlugInKit

@testable import TingraApp

/// A mix block at `seconds` with one microphone strip and a left-only
/// master, the fixture every meters test folds.
private func block(
    at seconds: Double, peak: Float, rms: Float, strip: String = "mic"
) -> MeterBlock {
    MeterBlock(
        time: CMTime(seconds: seconds, preferredTimescale: 48_000),
        strips: [InputID(rawValue: strip): MeterReading(peak: peak, rms: rms)],
        master: StereoMeterReading(left: MeterReading(peak: peak / 2, rms: rms / 2), right: .floor))
}

/// The window a follower is sent: how many mix blocks become one
/// `tingra/meters` notification (PLUGINS.md, Decision 18).
@Suite("MeterWindow")
struct MeterWindowTests {
    @Test("an empty window has no levels")
    func emptyWindow() {
        let window = MeterWindow()
        #expect(window.isEmpty)
        #expect(window.levels == nil)
    }

    @Test("one block's levels are its readings, at its time")
    func oneBlock() throws {
        var window = MeterWindow()
        window.fold(block(at: 2, peak: 0.5, rms: 0.25))
        let levels = try #require(window.levels)
        #expect(levels.time == 2)
        #expect(levels.strips == [InputID(rawValue: "mic"): MeterLevel(peak: 0.5, rms: 0.25)])
        #expect(levels.masterLeft == MeterLevel(peak: 0.25, rms: 0.125))
        #expect(levels.masterRight == .floor)
    }

    @Test("a window keeps its hottest peak, takes the RMS of its blocks, and the last block's time")
    func foldsBlocks() throws {
        var window = MeterWindow()
        window.fold(block(at: 1, peak: 0.25, rms: 0.3))
        window.fold(block(at: 2, peak: 1.5, rms: 0.4))
        window.fold(block(at: 3, peak: 0.125, rms: 0))
        let levels = try #require(window.levels)
        #expect(levels.time == 3)
        let mic = try #require(levels.strips[InputID(rawValue: "mic")])
        #expect(mic.peak == 1.5)
        // sqrt((0.09 + 0.16 + 0) / 3)
        #expect(abs(mic.rms - 0.288675) < 0.0001)
        #expect(levels.masterLeft.peak == 0.75)
    }

    @Test("the strips are the latest block's: one that left is gone, one that joined counts its own blocks")
    func stripsFollowLatestBlock() throws {
        var window = MeterWindow()
        window.fold(block(at: 1, peak: 0.5, rms: 0.5, strip: "mic"))
        window.fold(block(at: 2, peak: 0.25, rms: 0.25, strip: "tone"))
        let levels = try #require(window.levels)
        #expect(levels.strips == [InputID(rawValue: "tone"): MeterLevel(peak: 0.25, rms: 0.25)])
    }

    @Test("a reading that is not a finite number meters as silence, so the window still renders as JSON")
    func nonFiniteReadings() throws {
        var window = MeterWindow()
        window.fold(block(at: 1, peak: .infinity, rms: .nan))
        let levels = try #require(window.levels)
        #expect(levels.strips[InputID(rawValue: "mic")] == .floor)
        _ = try JSONEncoder().encode(levels.jsonValue)
    }
}

/// The feed between the meter drain and the plug-ins' connections.
@Suite("MeterFeed")
struct MeterFeedTests {
    @Test("a follower is sent the blocks folded since its last window, and nothing while none arrive")
    func followerGetsWindows() async throws {
        let feed = MeterFeed()
        var iterator = feed.levels(every: .milliseconds(1)).makeAsyncIterator()
        #expect(feed.hasFollowers)
        feed.fold(block(at: 1, peak: 0.5, rms: 0.5))
        let first = await iterator.next()
        #expect(first?.time == 1)

        // Nothing arrives until a block does: the follower waits, unwoken.
        let later = Task {
            try await Task.sleep(for: .milliseconds(30))
            feed.fold(block(at: 2, peak: 0.25, rms: 0.25))
        }
        let second = await iterator.next()
        try await later.value
        #expect(second?.time == 2)
        #expect(second?.strips[InputID(rawValue: "mic")]?.peak == 0.25)
    }

    @Test("blocks that arrive inside the interval reach the follower as one window")
    func coalescesInsideInterval() async throws {
        let feed = MeterFeed()
        var iterator = feed.levels(every: .milliseconds(200)).makeAsyncIterator()
        feed.fold(block(at: 1, peak: 0.1, rms: 0.1))
        #expect(await iterator.next()?.time == 1)
        for tick in 2...9 {
            feed.fold(block(at: Double(tick), peak: tick == 5 ? 0.75 : 0.125, rms: 0.125))
        }
        let window = await iterator.next()
        #expect(window?.time == 9)
        #expect(window?.strips[InputID(rawValue: "mic")]?.peak == 0.75)
    }

    @Test("each follower has a window of its own")
    func followersAreIndependent() async {
        let feed = MeterFeed()
        var early = feed.levels(every: .milliseconds(1)).makeAsyncIterator()
        feed.fold(block(at: 1, peak: 0.5, rms: 0.5))
        #expect(await early.next()?.time == 1)
        var late = feed.levels(every: .milliseconds(1)).makeAsyncIterator()
        feed.fold(block(at: 2, peak: 0.75, rms: 0.5))
        #expect(await late.next()?.strips[InputID(rawValue: "mic")]?.peak == 0.75)
        #expect(await early.next()?.time == 2)
    }

    @Test("a follower that stops is forgotten")
    func stoppedFollowerForgotten() async throws {
        let feed = MeterFeed()
        let following = Task {
            for await _ in feed.levels(every: .milliseconds(1)) {}
        }
        feed.fold(block(at: 1, peak: 0.5, rms: 0.5))
        try await Task.sleep(for: .milliseconds(20))
        following.cancel()
        await following.value
        for _ in 0..<200 where feed.hasFollowers {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!feed.hasFollowers)
    }
}

/// The handler's half of `tingra/meters`: the subscription a connection
/// opts in with, and the notification it is then sent.
@Suite("PlugInMethodHandler meters")
struct PlugInMethodHandlerMetersTests {
    /// The plug-in every test speaks as.
    private let notes = PlugInID(rawValue: "com.moonwink.tingra.notes")

    /// The notifications a handler sent, recorded in order.
    private final class Recorder: Sendable {
        /// What was sent: the method and its params.
        let sent = Mutex<[(method: String, params: JSONValue?)]>([])

        /// A notifier that records instead of writing to a transport.
        var notifier: SessionNotifier {
            SessionNotifier { method, params, _ in self.sent.withLock { $0.append((method, params)) } }
        }

        /// Waits until `count` notifications were sent, or two seconds.
        func waitForCount(_ count: Int) async throws {
            for _ in 0..<400 where sent.withLock({ $0.count }) < count {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// A handler over an in-memory store and `feed`, sending as often as
    /// the feed has a window.
    private func makeHandler(feed: MeterFeed, bus: EventBus = EventBus()) -> PlugInMethodHandler {
        PlugInMethodHandler(
            plugIn: notes, eventBus: bus, storage: PlugInApplicationStoreStub(), statusItems: StatusItemRegistry(),
            meters: feed, frames: NoFrames(), metersInterval: .milliseconds(1))
    }

    @Test("a subscribed connection is sent the levels inline as tingra/meters, and none once it unsubscribes")
    func subscribesAndUnsubscribes() async throws {
        let feed = MeterFeed()
        let recorder = Recorder()
        let handler = makeHandler(feed: feed)
        await handler.sessionOpened(notifier: recorder.notifier)
        let answer = try await handler.respond(method: AppTierMethod.metersSubscribe, params: nil)
        #expect(answer == .object([:]))
        #expect(feed.hasFollowers)

        feed.fold(block(at: 4, peak: 0.5, rms: 0.25))
        try await recorder.waitForCount(1)
        let sent = try #require(recorder.sent.withLock { $0.first })
        #expect(sent.method == AppTierMethod.meters)
        let levels = try #require(MeterLevels(jsonValue: sent.params))
        #expect(levels.time == 4)
        #expect(levels.strips == [InputID(rawValue: "mic"): MeterLevel(peak: 0.5, rms: 0.25)])

        let stopped = try await handler.respond(method: AppTierMethod.metersUnsubscribe, params: nil)
        #expect(stopped == .object([:]))
        for _ in 0..<200 where feed.hasFollowers {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!feed.hasFollowers)
    }

    @Test("subscribing twice is one subscription, and unsubscribing when not subscribed is answered all the same")
    func subscriptionIsIdempotent() async throws {
        let feed = MeterFeed()
        let recorder = Recorder()
        let handler = makeHandler(feed: feed)
        await handler.sessionOpened(notifier: recorder.notifier)
        #expect(try await handler.respond(method: AppTierMethod.metersUnsubscribe, params: nil) == .object([:]))
        _ = try await handler.respond(method: AppTierMethod.metersSubscribe, params: nil)
        _ = try await handler.respond(method: AppTierMethod.metersSubscribe, params: nil)
        feed.fold(block(at: 1, peak: 0.5, rms: 0.25))
        try await recorder.waitForCount(1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.sent.withLock { $0.count } == 1)
        await handler.sessionClosed()
    }

    @Test("the session closing ends the subscription, and both ends are reported on the bus")
    func sessionCloseEndsSubscription() async throws {
        let feed = MeterFeed()
        let bus = EventBus()
        let events = bus.events()
        let handler = makeHandler(feed: feed, bus: bus)
        await handler.sessionOpened(notifier: Recorder().notifier)
        _ = try await handler.respond(method: AppTierMethod.metersSubscribe, params: nil)
        await handler.sessionClosed()
        for _ in 0..<200 where feed.hasFollowers {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!feed.hasFollowers)
        bus.shutdown()
        var names: [String] = []
        var reason: EventValue?
        for await event in events {
            names.append(event.name)
            if event.name == "plugin.meters.unsubscribed" { reason = event.params?["reason"] }
        }
        #expect(names == ["plugin.meters.subscribed", "plugin.meters.unsubscribed"])
        #expect(reason == .string("closed"))
    }

    @Test("a subscription before the session opened returns an internal error")
    func subscribeBeforeOpen() async throws {
        let handler = makeHandler(feed: MeterFeed())
        do {
            _ = try await handler.respond(method: AppTierMethod.metersSubscribe, params: nil)
            Issue.record("expected an internal error")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.internalError.rawValue)
        }
    }
}

/// A store that keeps nothing: the meters tests never touch storage.
private final class PlugInApplicationStoreStub: PlugInStoring {
    func value(scope: StorageScope, plugIn: PlugInID) async -> JSONValue? { nil }

    func setValue(_ value: JSONValue?, scope: StorageScope, plugIn: PlugInID) async {}

    func secret(named name: String, plugIn: PlugInID) async throws -> String? { nil }

    func setSecret(_ secret: String?, named name: String, plugIn: PlugInID) async throws {}
}
