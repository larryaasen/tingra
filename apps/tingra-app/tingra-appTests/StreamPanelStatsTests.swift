//
//  StreamPanelStatsTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-01.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraComposition
import TingraHost
import TingraPlugInKit

@testable import TingraApp

/// The streaming panel's figures from one reading of the session's live
/// statistics: each live destination's own, the first live one's as the
/// headline, and nothing for a destination its own events do not call live.
@Suite("Stream panel stats")
struct StreamPanelStatsTests {
    /// The first destination in the panel.
    private let twitch = ProjectDestinationID(rawValue: "twitch")

    /// The second destination in the panel.
    private let youtube = ProjectDestinationID(rawValue: "youtube")

    /// Builds one leg's reading.
    ///
    /// - Parameters:
    ///   - id: The destination.
    ///   - bytesPerSecond: The delivery rate.
    ///   - fps: The frame rate.
    /// - Returns: The reading.
    private func reading(_ id: ProjectDestinationID, bytesPerSecond: Int, fps: Int) -> StreamSession.LegStatistics {
        StreamSession.LegStatistics(
            destination: id.rawValue,
            statistics: StreamingStatistics(bytesSent: 0, bytesPerSecond: bytesPerSecond, framesPerSecond: fps)
        )
    }

    @Test("Each live destination gets its own figures in kbps and the first live one is the headline")
    func liveDestinationsAndHeadline() {
        let panel = EngineModel.panelStats(
            for: [
                reading(twitch, bytesPerSecond: 750_000, fps: 30),
                reading(youtube, bytesPerSecond: 500_000, fps: 29),
            ],
            destinationStates: [twitch: .live, youtube: .live],
            destinationOrder: [twitch, youtube]
        )
        #expect(panel.perDestination[twitch] == EngineModel.StreamStats(bitrateKbps: 6000, fps: 30))
        #expect(panel.perDestination[youtube] == EngineModel.StreamStats(bitrateKbps: 4000, fps: 29))
        #expect(panel.headline == EngineModel.StreamStats(bitrateKbps: 6000, fps: 30))
    }

    @Test("A destination that is not live by its own events gets no figures and the headline moves on")
    func notLiveDestinationIsDropped() {
        let panel = EngineModel.panelStats(
            for: [
                reading(twitch, bytesPerSecond: 750_000, fps: 30),
                reading(youtube, bytesPerSecond: 500_000, fps: 29),
            ],
            destinationStates: [twitch: .reconnecting(attempt: 1, maxAttempts: 3), youtube: .live],
            destinationOrder: [twitch, youtube]
        )
        #expect(panel.perDestination[twitch] == nil)
        #expect(panel.headline == EngineModel.StreamStats(bitrateKbps: 4000, fps: 29))
    }

    @Test("A reading that misses the first live destination leaves the headline alone")
    func headlineNeedsFirstLiveDestination() {
        let panel = EngineModel.panelStats(
            for: [reading(youtube, bytesPerSecond: 500_000, fps: 29)],
            destinationStates: [twitch: .live, youtube: .live],
            destinationOrder: [twitch, youtube]
        )
        #expect(panel.perDestination[youtube] != nil)
        #expect(panel.headline == nil)
    }

    @Test("An empty reading changes nothing")
    func emptyReading() {
        let panel = EngineModel.panelStats(
            for: [],
            destinationStates: [twitch: .live],
            destinationOrder: [twitch]
        )
        #expect(panel.perDestination.isEmpty)
        #expect(panel.headline == nil)
    }

    @Test("The log interval is a minute")
    func logInterval() {
        #expect(EngineModel.streamStatsLogIntervalSeconds == 60)
    }
}
