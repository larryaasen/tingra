//
//  CompressionChoicesTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraPlugInKit

@testable import TingraHost

@Suite("CompressionChoices")
struct CompressionChoicesTests {
    @Test("the offered audio bit rates ascend and include the default")
    func audioBitRatesAscendAndHoldTheDefault() {
        #expect(CompressionChoices.audioBitRates == CompressionChoices.audioBitRates.sorted())
        #expect(CompressionChoices.audioBitRates.contains(CompressionChoices.defaultAudioBitsPerSecond))
        #expect(CompressionChoices.defaultAudioBitsPerSecond == StreamConfiguration().audioBitsPerSecond)
    }

    @Test("an offered audio bit rate matches itself")
    func offeredRateMatchesItself() {
        for rate in CompressionChoices.audioBitRates {
            #expect(CompressionChoices.audioBitsPerSecond(nearest: rate) == rate)
        }
    }

    @Test(
        "a rate off the menu matches the nearest offered one, a tie going to the higher",
        arguments: [
            (0, 96_000), (-5, 96_000), (100_000, 96_000), (112_000, 128_000), (150_000, 160_000),
            (224_000, 256_000), (300_000, 320_000), (1_000_000, 320_000),
        ])
    func nearestRate(requested: Int, expected: Int) {
        #expect(CompressionChoices.audioBitsPerSecond(nearest: requested) == expected)
    }

    @Test("H.264 keeps the pixel-rate rule's figure")
    func h264KeepsTheRecommendedRate() {
        let rate = CompressionChoices.videoBitsPerSecond(width: 1920, height: 1080, frameRate: 30, codec: .h264)
        #expect(rate == 4_500_000)
        #expect(
            rate == StreamConfiguration.recommendedVideoBitsPerSecond(width: 1920, height: 1080, frameRate: 30))
    }

    @Test("HEVC is given 60 % of the H.264 figure, rounded to 100 kbps")
    func hevcIsGivenItsShare() {
        #expect(
            CompressionChoices.videoBitsPerSecond(width: 1920, height: 1080, frameRate: 30, codec: .hevc)
                == 2_700_000)
        #expect(
            CompressionChoices.videoBitsPerSecond(width: 3840, height: 2160, frameRate: 30, codec: .hevc)
                == 10_800_000)
        #expect(
            CompressionChoices.videoBitsPerSecond(width: 1280, height: 720, frameRate: 30, codec: .hevc)
                == 1_200_000)
    }

    @Test("HEVC is lower than H.264 at every size, and never under 100 kbps")
    func hevcIsLowerAndBounded() {
        for (width, height) in [(854, 480), (1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)] {
            let h264 = CompressionChoices.videoBitsPerSecond(
                width: width, height: height, frameRate: 60, codec: .h264)
            let hevc = CompressionChoices.videoBitsPerSecond(
                width: width, height: height, frameRate: 60, codec: .hevc)
            #expect(hevc < h264)
        }
        #expect(CompressionChoices.videoBitsPerSecond(width: 16, height: 16, frameRate: 1, codec: .hevc) == 100_000)
        #expect(CompressionChoices.videoBitsPerSecond(width: 0, height: 0, frameRate: 0, codec: .hevc) == 100_000)
    }
}
