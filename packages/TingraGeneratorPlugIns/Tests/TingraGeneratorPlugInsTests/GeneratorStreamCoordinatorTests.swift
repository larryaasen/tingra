//
//  GeneratorStreamCoordinatorTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

/// A renderer whose outcome per tick is scripted, so the coordinator's stall
/// reporting is testable without provoking a real Core Video allocation
/// failure — which is precisely the condition no unit test can arrange on
/// demand, and the reason the defect went unreported for so long.
private final class ScriptedRenderer {
    /// The outcome for each tick in order; ticks past the end succeed.
    private let outcomes: [GeneratorSynthesisFailure?]

    /// The tick this renderer is on.
    private var tick = 0

    /// Creates a renderer following `outcomes`, one entry per tick.
    init(outcomes: [GeneratorSynthesisFailure?]) {
        self.outcomes = outcomes
    }

    /// Returns the tick index as the output, or throws the scripted failure.
    func render() throws(GeneratorSynthesisFailure) -> Int {
        let outcome = tick < outcomes.count ? outcomes[tick] : nil
        tick += 1
        if let outcome { throw outcome }
        return tick
    }
}

/// The scripted times a run of `count` ticks uses; the values themselves do
/// not matter to these tests, only that there are exactly that many.
private func tickTimes(_ count: Int) -> [CMTime] {
    (0..<count).map { CMTime(value: CMTimeValue($0), timescale: 30) }
}

/// Drives a coordinator over `outcomes` and returns what was yielded and what
/// reached the bus.
private func run(
    outcomes: [GeneratorSynthesisFailure?]
) async -> (outputs: [Int], events: [EventBusEvent]) {
    let eventBus = EventBus()
    let events = eventBus.events()
    let coordinator = GeneratorStreamCoordinator<Int>()
    let stream = coordinator.makeStream(
        clock: SyntheticClock(tickTimes: tickTimes(outcomes.count)),
        tickInterval: CMTime(value: 1, timescale: 30),
        inputID: InputID(rawValue: "scripted"),
        eventBus: eventBus,
        makeRenderer: { ScriptedRenderer(outcomes: outcomes) },
        render: { (renderer, _) throws(GeneratorSynthesisFailure) in try renderer.render() }
    )

    var outputs: [Int] = []
    for await output in stream {
        outputs.append(output)
    }
    eventBus.shutdown()

    var received: [EventBusEvent] = []
    for await event in events {
        received.append(event)
    }
    return (outputs, received)
}

@Suite("GeneratorStreamCoordinator stall reporting")
struct GeneratorStreamCoordinatorTests {
    @Test("a tick that produces nothing is skipped rather than propagated")
    func failedTicksAreSkipped() async {
        let (outputs, _) = await run(outcomes: [nil, .drawingContextUnavailable, nil, nil])

        // Three ticks succeeded and one was skipped: the consumer sees the
        // three, and the stream stays open — a generator problem must never
        // take down the pipeline.
        #expect(outputs.count == 3)
    }

    @Test("a run of skipped ticks reports one stall and one resume")
    func stallAndResumeBoundTheEpisode() async {
        let stalled: [GeneratorSynthesisFailure?] = Array(repeating: .pixelBufferUnavailable(-6680), count: 5)
        let (outputs, events) = await run(outcomes: [nil] + stalled + [nil, nil])

        #expect(outputs.count == 3)
        #expect(events.count == 2)
        #expect(events.first?.group == .error)
        #expect(events.first?.name == "generator.stalled")
        #expect(events.first?.params?["id"] == .string("scripted"))
        #expect(events.first?.params?["reason"] == .string("pixelBuffer"))
        #expect(events.last?.group == .event)
        #expect(events.last?.name == "generator.resumed")
        #expect(events.last?.params?["skipped"] == .int(5))
    }

    @Test("a generator that never recovers reports exactly one error for the whole run")
    func permanentStallReportsOnce() async {
        let outcomes: [GeneratorSynthesisFailure?] = Array(
            repeating: .pixelBufferPoolUnavailable(-6682),
            count: 120
        )
        let (outputs, events) = await run(outcomes: outcomes)

        // The case the defect was really about: four seconds of nothing at
        // 30 fps used to be indistinguishable from a hang. It is now one
        // error event naming the pool, and no flood.
        #expect(outputs.isEmpty)
        #expect(events.count == 1)
        #expect(events.first?.name == "generator.stalled")
        #expect(events.first?.params?["reason"] == .string("pixelBufferPool"))
        #expect(events.first?.params?["status"] == .int(-6682))
    }

    @Test("a healthy run reports nothing")
    func healthyRunIsSilent() async {
        let (outputs, events) = await run(outcomes: Array(repeating: nil, count: 30))

        #expect(outputs.count == 30)
        #expect(events.isEmpty)
    }

    @Test("two episodes in one run are reported separately")
    func separateEpisodesAreReportedSeparately() async {
        let (outputs, events) = await run(outcomes: [
            nil,
            .drawingContextUnavailable,
            .drawingContextUnavailable,
            nil,
            .audioSampleBufferUnavailable(-12731),
            nil,
        ])

        #expect(outputs.count == 3)
        #expect(events.count == 4)
        #expect(events[0].params?["reason"] == .string("drawingContext"))
        #expect(events[1].params?["skipped"] == .int(2))
        #expect(events[2].params?["reason"] == .string("audioSampleBuffer"))
        #expect(events[3].params?["skipped"] == .int(1))
    }

    @Test("a stall still reports when the run ends without recovering")
    func stallAtEndOfRunStillReports() async {
        let (outputs, events) = await run(outcomes: [nil, nil, .pixelBufferUnavailable(-6680)])

        #expect(outputs.count == 2)
        #expect(events.count == 1)
        #expect(events.first?.name == "generator.stalled")
    }

    @Test("a coordinator without a bus skips ticks exactly as before and reports nothing")
    func coordinatorWithoutBusStillSkips() async {
        let coordinator = GeneratorStreamCoordinator<Int>()
        let stream = coordinator.makeStream(
            clock: SyntheticClock(tickTimes: tickTimes(3)),
            tickInterval: CMTime(value: 1, timescale: 30),
            inputID: InputID(rawValue: "scripted"),
            eventBus: nil,
            makeRenderer: { ScriptedRenderer(outcomes: [nil, .drawingContextUnavailable, nil]) },
            render: { (renderer, _) throws(GeneratorSynthesisFailure) in try renderer.render() }
        )

        var outputs: [Int] = []
        for await output in stream {
            outputs.append(output)
        }
        #expect(outputs.count == 2)
    }
}
