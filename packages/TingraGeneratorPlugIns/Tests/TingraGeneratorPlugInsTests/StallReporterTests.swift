//
//  StallReporterTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

/// Collects everything a bus emitted, so a test can assert on the whole
/// episode rather than on one event at a time — the point of the rule under
/// test is precisely *how many* events an episode produces.
private func collect(_ body: (EventBus) -> Void) async -> [EventBusEvent] {
    let eventBus = EventBus()
    let events = eventBus.events()
    body(eventBus)
    eventBus.shutdown()
    var received: [EventBusEvent] = []
    for await event in events {
        received.append(event)
    }
    return received
}

@Suite("StallReporter")
struct StallReporterTests {
    /// The identifier every test in this suite reports under.
    private static let inputID = InputID(rawValue: "bars")

    @Test("a first skipped tick opens the episode with one error naming the cause")
    func firstFailureReportsTheCause() async {
        let received = await collect { eventBus in
            var reporter = StallReporter(inputID: Self.inputID, eventBus: eventBus)
            reporter.recordFailure(.pixelBufferUnavailable(-6680))
        }

        #expect(received.count == 1)
        let event = received.first
        #expect(event?.group == .error)
        #expect(event?.domain == .capture)
        #expect(event?.name == "generator.stalled")
        #expect(event?.params?["id"] == .string("bars"))
        #expect(event?.params?["reason"] == .string("pixelBuffer"))
        #expect(event?.params?["status"] == .int(-6680))
    }

    @Test("a cause the framework gives no status for reports without the status param")
    func failureWithoutStatusOmitsTheParam() async {
        let received = await collect { eventBus in
            var reporter = StallReporter(inputID: Self.inputID, eventBus: eventBus)
            reporter.recordFailure(.drawingContextUnavailable)
        }

        #expect(received.count == 1)
        #expect(received.first?.params?["reason"] == .string("drawingContext"))
        #expect(received.first?.params?["status"] == nil)
    }

    @Test("an open episode stays at one event however many ticks are skipped")
    func repeatedFailuresReportOnce() async {
        let received = await collect { eventBus in
            var reporter = StallReporter(inputID: Self.inputID, eventBus: eventBus)
            for _ in 0..<300 {
                reporter.recordFailure(.pixelBufferUnavailable(-6680))
            }
        }

        // 300 ticks is ten seconds at 30 fps: the flood principle 3 forbids,
        // reduced to the one event that says the generator stopped.
        #expect(received.count == 1)
    }

    @Test("a second cause inside an open episode does not reopen the report")
    func changedCauseDoesNotReport() async {
        let received = await collect { eventBus in
            var reporter = StallReporter(inputID: Self.inputID, eventBus: eventBus)
            reporter.recordFailure(.pixelBufferUnavailable(-6680))
            reporter.recordFailure(.drawingContextUnavailable)
            reporter.recordFailure(.pixelBufferUnavailable(-6680))
        }

        #expect(received.count == 1)
        // The cause that opened the episode is the one kept.
        #expect(received.first?.params?["reason"] == .string("pixelBuffer"))
    }

    @Test("recovery closes the episode with the count of ticks lost")
    func recoveryReportsTheSkippedCount() async {
        let received = await collect { eventBus in
            var reporter = StallReporter(inputID: Self.inputID, eventBus: eventBus)
            for _ in 0..<7 {
                reporter.recordFailure(.pixelBufferUnavailable(-6680))
            }
            reporter.recordOutput()
        }

        #expect(received.count == 2)
        let resumed = received.last
        #expect(resumed?.group == .event)
        #expect(resumed?.domain == .capture)
        #expect(resumed?.name == "generator.resumed")
        #expect(resumed?.params?["id"] == .string("bars"))
        #expect(resumed?.params?["reason"] == .string("pixelBuffer"))
        #expect(resumed?.params?["skipped"] == .int(7))
    }

    @Test("output while healthy reports nothing at all")
    func healthyOutputIsSilent() async {
        let received = await collect { eventBus in
            var reporter = StallReporter(inputID: Self.inputID, eventBus: eventBus)
            for _ in 0..<100 {
                reporter.recordOutput()
            }
        }

        #expect(received.isEmpty)
    }

    @Test("a repeated recovery reports once, not on every subsequent tick")
    func recoveryReportsOnlyOnTheEdge() async {
        let received = await collect { eventBus in
            var reporter = StallReporter(inputID: Self.inputID, eventBus: eventBus)
            reporter.recordFailure(.drawingContextUnavailable)
            reporter.recordOutput()
            reporter.recordOutput()
            reporter.recordOutput()
        }

        #expect(received.count == 2)
    }

    @Test("a later episode reports its own cause and its own count afresh")
    func secondEpisodeIsIndependent() async {
        let received = await collect { eventBus in
            var reporter = StallReporter(inputID: Self.inputID, eventBus: eventBus)
            reporter.recordFailure(.pixelBufferUnavailable(-6680))
            reporter.recordFailure(.pixelBufferUnavailable(-6680))
            reporter.recordOutput()
            reporter.recordFailure(.audioBlockBufferUnavailable(-12730))
            reporter.recordOutput()
        }

        #expect(received.count == 4)
        #expect(received[0].params?["reason"] == .string("pixelBuffer"))
        #expect(received[1].params?["skipped"] == .int(2))
        #expect(received[2].name == "generator.stalled")
        #expect(received[2].params?["reason"] == .string("audioBlockBuffer"))
        #expect(received[2].params?["status"] == .int(-12730))
        // The skipped count restarts with the episode rather than accumulating.
        #expect(received[3].params?["skipped"] == .int(1))
    }

    @Test("an unresolved episode stays at its single error, which is the standing signal")
    func unresolvedEpisodeStaysSilent() async {
        let received = await collect { eventBus in
            var reporter = StallReporter(inputID: Self.inputID, eventBus: eventBus)
            for _ in 0..<50 {
                reporter.recordFailure(.pixelBufferPoolUnavailable(-6682))
            }
        }

        #expect(received.count == 1)
        #expect(received.first?.name == "generator.stalled")
        #expect(received.first?.params?["reason"] == .string("pixelBufferPool"))
    }

    @Test("a reporter without a bus tracks and emits nothing")
    func reporterWithoutBusIsInert() async {
        var reporter = StallReporter(inputID: Self.inputID, eventBus: nil)
        reporter.recordFailure(.drawingContextUnavailable)
        reporter.recordOutput()
        reporter.recordFailure(.pixelBufferUnavailable(-6680))

        // Nothing to observe — the assertion is that driving the reporter
        // without a bus is well defined rather than a trap, since that is how
        // every unit-test generator in this package is built.
        #expect(Bool(true))
    }
}

@Suite("GeneratorSynthesisFailure")
struct GeneratorSynthesisFailureTests {
    @Test("every case carries a distinct stable reason token")
    func reasonsAreDistinct() {
        let failures: [GeneratorSynthesisFailure] = [
            .pixelBufferPoolUnavailable(-1),
            .pixelBufferUnavailable(-1),
            .drawingContextUnavailable,
            .patternImageUnavailable,
            .audioFormatDescriptionUnavailable(-1),
            .audioBlockBufferUnavailable(-1),
            .audioSampleBufferUnavailable(-1),
        ]
        let reasons = failures.map(\.reason)
        #expect(Set(reasons).count == failures.count)
        #expect(reasons.allSatisfy { !$0.isEmpty })
    }

    @Test("the status is carried where the framework gave one and absent where it did not")
    func statusIsCarriedWhereAvailable() {
        #expect(GeneratorSynthesisFailure.pixelBufferUnavailable(-6680).status == -6680)
        #expect(GeneratorSynthesisFailure.pixelBufferPoolUnavailable(-6682).status == -6682)
        #expect(GeneratorSynthesisFailure.audioFormatDescriptionUnavailable(-12712).status == -12712)
        #expect(GeneratorSynthesisFailure.audioBlockBufferUnavailable(-12730).status == -12730)
        #expect(GeneratorSynthesisFailure.audioSampleBufferUnavailable(-12731).status == -12731)
        #expect(GeneratorSynthesisFailure.drawingContextUnavailable.status == nil)
        #expect(GeneratorSynthesisFailure.patternImageUnavailable.status == nil)
    }

    @Test("two failures match only when both the case and the status agree")
    func equality() {
        #expect(GeneratorSynthesisFailure.pixelBufferUnavailable(-6680) == .pixelBufferUnavailable(-6680))
        #expect(GeneratorSynthesisFailure.drawingContextUnavailable == .drawingContextUnavailable)
        #expect(GeneratorSynthesisFailure.pixelBufferUnavailable(-6680) != .pixelBufferUnavailable(-6682))
        #expect(GeneratorSynthesisFailure.pixelBufferUnavailable(-6680) != .pixelBufferPoolUnavailable(-6680))
        #expect(GeneratorSynthesisFailure.drawingContextUnavailable != .patternImageUnavailable)
    }
}
