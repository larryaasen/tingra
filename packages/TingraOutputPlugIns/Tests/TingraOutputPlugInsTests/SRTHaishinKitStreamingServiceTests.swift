//
//  SRTHaishinKitStreamingServiceTests.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-24.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import Foundation
import SRTHaishinKit
import Testing
import TingraPlugInKit

@testable import TingraOutputPlugIns

/// Tests for the SRT service's URL composition and topology mapping behind
/// the HaishinKit seam — pure logic, no network.
struct SRTHaishinKitStreamingServiceTests {
    // MARK: - streamid composition

    @Test("A stream key is composed into a streamid on a query-less URL")
    func keyBecomesStreamID() throws {
        let destination = Destination(
            url: try #require(URL(string: "srt://localhost:8890")),
            streamKey: "publish:live/tingra_test_key"
        )
        let url = try SRTHaishinKitStreamingService.srtURL(for: destination)
        // Literal, not percent-encoded: HaishinKit reads streamid by raw split.
        #expect(url.absoluteString == "srt://localhost:8890?streamid=publish:live/tingra_test_key")
    }

    @Test("A stream key is appended with & when the URL already carries other query items")
    func keyAppendsToExistingQuery() throws {
        let destination = Destination(
            url: try #require(URL(string: "srt://localhost:8890?latency=200")),
            streamKey: "publish:live/key"
        )
        let url = try SRTHaishinKitStreamingService.srtURL(for: destination)
        #expect(url.absoluteString == "srt://localhost:8890?latency=200&streamid=publish:live/key")
    }

    @Test("A URL that already carries a streamid plus a key throws unsupportedDestination")
    func keyAndExistingStreamIDThrows() throws {
        let destination = Destination(
            url: try #require(URL(string: "srt://localhost:8890?streamid=publish:live/x")),
            streamKey: "publish:live/y"
        )
        #expect(throws: StreamingServiceError.self) {
            _ = try SRTHaishinKitStreamingService.srtURL(for: destination)
        }
    }

    @Test("A URL with its own streamid and no key is used as given")
    func streamIDInURLNoKey() throws {
        let destination = Destination(
            url: try #require(URL(string: "srt://localhost:8890?streamid=publish:live/key"))
        )
        let url = try SRTHaishinKitStreamingService.srtURL(for: destination)
        #expect(url.absoluteString == "srt://localhost:8890?streamid=publish:live/key")
    }

    @Test("A keyless, streamid-less URL is used as given")
    func plainURLNoKey() throws {
        let destination = Destination(url: try #require(URL(string: "srt://host:9000")))
        let url = try SRTHaishinKitStreamingService.srtURL(for: destination)
        #expect(url.absoluteString == "srt://host:9000")
    }

    @Test("An empty stream key is treated as no key")
    func emptyKeyIsNoKey() throws {
        let destination = Destination(
            url: try #require(URL(string: "srt://host:9000")),
            streamKey: ""
        )
        let url = try SRTHaishinKitStreamingService.srtURL(for: destination)
        #expect(url.absoluteString == "srt://host:9000")
    }

    // MARK: - Existing streamid detection

    @Test(
        "A streamid is detected in the query by raw split, matching how HaishinKit reads it",
        arguments: [
            ("srt://h:9?streamid=x", "x"),
            ("srt://h:9?latency=200&streamid=publish:live/k", "publish:live/k"),
            ("srt://h:9?latency=200", String?.none),
            ("srt://h:9", String?.none),
        ] as [(String, String?)]
    )
    func existingStreamIDDetection(urlString: String, expected: String?) {
        #expect(SRTHaishinKitStreamingService.existingStreamID(in: urlString) == expected)
    }

    // MARK: - Rejection reasons

    @Test("Rejection reasons name the host and never the stream key")
    func rejectionReasonOmitsKey() throws {
        let destination = Destination(
            url: try #require(URL(string: "srt://ingest.example.com:8890")),
            streamKey: "publish:live/live_secret_value"
        )
        let reason = SRTHaishinKitStreamingService.rejectionReason(
            for: SRTConnection.Error.failedToConnect(.badsecret),
            destination: destination
        )
        #expect(reason.contains("ingest.example.com"))
        #expect(!reason.contains("live_secret_value"))
    }

    // MARK: - Track topology

    @Test(
        "Expected medias follow the configuration's declared sides",
        arguments: [
            (true, true, Set<AVMediaType>([.video, .audio])),
            (true, false, Set<AVMediaType>([.video])),
            (false, true, Set<AVMediaType>([.audio])),
            (false, false, Set<AVMediaType>([])),
        ]
    )
    func expectedMediasMapping(includesVideo: Bool, includesAudio: Bool, expected: Set<AVMediaType>) {
        let configuration = StreamConfiguration(includesVideo: includesVideo, includesAudio: includesAudio)
        #expect(SRTHaishinKitStreamingService.expectedMedias(for: configuration) == expected)
    }

    // MARK: - Frame rate

    @Test(
        "The frame rate divides the frames by the master clock interval, rounding down",
        arguments: [
            (frames: 30, elapsed: CMTime(value: 1, timescale: 1), expected: 30),
            (frames: 60, elapsed: CMTime(value: 2, timescale: 1), expected: 30),
            (frames: 29, elapsed: CMTime(value: 1_001, timescale: 1_000), expected: 28),
            (frames: 15, elapsed: CMTime(value: 1, timescale: 2), expected: 30),
        ]
    )
    func framesPerSecond(frames: Int, elapsed: CMTime, expected: Int) {
        #expect(SRTHaishinKitStreamingService.framesPerSecond(frames: frames, over: elapsed) == expected)
    }

    @Test(
        "An interval that is zero, negative, or not numeric makes a frame rate of zero",
        arguments: [CMTime.zero, CMTime(value: -1, timescale: 1), CMTime.invalid, CMTime.positiveInfinity]
    )
    func framesPerSecondOverNoTime(elapsed: CMTime) {
        #expect(SRTHaishinKitStreamingService.framesPerSecond(frames: 30, over: elapsed) == 0)
    }

    @Test("A frame count that went backward makes a frame rate of zero, never a negative one")
    func framesPerSecondNeverNegative() {
        #expect(
            SRTHaishinKitStreamingService.framesPerSecond(frames: -5, over: CMTime(value: 1, timescale: 1)) == 0)
    }
}
