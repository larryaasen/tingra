//
//  StreamHealthTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraComposition

@testable import TingraApp

@Suite("StreamHealth")
@MainActor
struct StreamHealthTests {
    /// A reading of the stream's delivery.
    private func stats(kbps: Int = 4500, fps: Int = 30) -> EngineModel.StreamStats {
        EngineModel.StreamStats(bitrateKbps: kbps, fps: fps)
    }

    /// A destination's identifier.
    private func id(_ name: String) -> ProjectDestinationID {
        ProjectDestinationID(rawValue: name)
    }

    /// A health value that has taken the same reading a number of times, at
    /// a 30 fps program.
    private func health(after count: Int, of reading: EngineModel.StreamStats) -> StreamHealth {
        var health = StreamHealth()
        for _ in 0..<count { health.record(reading, frameRate: 30) }
        return health
    }

    @Test("no readings is no trouble")
    func emptyIsHealthy() {
        #expect(StreamHealth().trouble(destinationStates: [:]) == nil)
    }

    @Test("readings at the program's rate are no trouble, however many")
    func healthyReadings() {
        #expect(health(after: 10, of: stats()).trouble(destinationStates: [id("a"): .live]) == nil)
    }

    @Test("a low bitrate alone is no trouble — a still program compresses small")
    func lowBitrateIsHealthy() {
        #expect(health(after: 10, of: stats(kbps: 164, fps: 32)).trouble(destinationStates: [id("a"): .live]) == nil)
    }

    @Test("a frame rate within a tenth of the program's is not behind, and one under it is")
    func frameRateFloor() {
        #expect(!StreamHealth.isBehind(fps: 30, target: 30))
        #expect(!StreamHealth.isBehind(fps: 27, target: 30))
        #expect(StreamHealth.isBehind(fps: 26, target: 30))
        #expect(!StreamHealth.isBehind(fps: 54, target: 60))
        #expect(StreamHealth.isBehind(fps: 53, target: 60))
    }

    @Test("frames behind are reported only once they have stayed behind")
    func framesBehindMustLast() {
        let slow = stats(fps: 20)

        #expect(health(after: StreamHealth.sustainedReadings - 1, of: slow).trouble(destinationStates: [:]) == nil)
        #expect(
            health(after: StreamHealth.sustainedReadings, of: slow).trouble(destinationStates: [:])
                == .framesBehind(fps: 20, target: 30))
    }

    @Test("one reading back at the program's rate drops the frames-behind report")
    func framesRecover() {
        var health = health(after: 5, of: stats(fps: 20))
        health.record(stats(), frameRate: 30)

        #expect(health.trouble(destinationStates: [:]) == nil)
        #expect(health.slowReadings == 0)
    }

    @Test("nothing delivered is reported as stalled only once it has lasted")
    func stalledMustLast() {
        let nothing = stats(kbps: 0, fps: 30)

        #expect(
            health(after: StreamHealth.sustainedReadings - 1, of: nothing).trouble(destinationStates: [:]) == nil)
        #expect(
            health(after: StreamHealth.sustainedReadings, of: nothing).trouble(destinationStates: [:]) == .stalled)
    }

    @Test("a destination that is reconnecting, lost, or rejected counts as off air")
    func destinationsOffAir() {
        let health = health(after: 5, of: stats())

        #expect(
            health.trouble(destinationStates: [id("a"): .live, id("b"): .reconnecting(attempt: 1, maxAttempts: 5)])
                == .destinationsOffAir(count: 1, total: 2))
        #expect(
            health.trouble(destinationStates: [id("a"): .live, id("b"): .lost, id("c"): .rejected])
                == .destinationsOffAir(count: 2, total: 3))
    }

    @Test("the worst is reported: stalled over a destination off air, and that over frames behind")
    func worstFirst() {
        let offAir: [ProjectDestinationID: EngineModel.DestinationState] = [id("a"): .live, id("b"): .lost]

        #expect(health(after: 5, of: stats(kbps: 0, fps: 0)).trouble(destinationStates: offAir) == .stalled)
        #expect(
            health(after: 5, of: stats(fps: 10)).trouble(destinationStates: offAir)
                == .destinationsOffAir(count: 1, total: 2))
    }

    @Test("reset forgets every reading")
    func resetForgets() {
        var health = health(after: 5, of: stats(kbps: 0, fps: 0))
        health.reset()

        #expect(health == StreamHealth())
        #expect(health.trouble(destinationStates: [:]) == nil)
    }

    @Test("two health values with the same readings are equal, and differing readings are not")
    func equality() {
        #expect(health(after: 2, of: stats()) == health(after: 2, of: stats()))
        #expect(health(after: 2, of: stats()) != health(after: 2, of: stats(fps: 10)))
    }
}
