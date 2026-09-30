//
//  AVAssetWriterBackendTests.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-09-30.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreMedia
import Foundation
import Testing
import TingraPlugInKit

@testable import TingraRecordingPlugIns

/// The writer settings the production backend hands `AVAssetWriter`: the
/// pure mapping from a configuration, checked without opening a file.
@Suite("AVAssetWriterBackend settings")
struct AVAssetWriterBackendTests {
    @Test("Audio is written as stereo AAC at the configured rate and bitrate")
    func audioSettingsAreStereo() throws {
        let configuration = StreamConfiguration(audioBitsPerSecond: 192_000, audioSampleRate: 44_100)
        let settings = AVAssetWriterBackend.audioSettings(configuration)

        #expect(settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
        #expect(settings[AVNumberOfChannelsKey] as? Int == 2)
        #expect(settings[AVSampleRateKey] as? Int == 44_100)
        #expect(settings[AVEncoderBitRateKey] as? Int == 192_000)

        let layoutData = try #require(settings[AVChannelLayoutKey] as? Data)
        let tag = layoutData.withUnsafeBytes { $0.load(as: AudioChannelLayout.self).mChannelLayoutTag }
        #expect(tag == kAudioChannelLayoutTag_Stereo)
    }

    @Test("The writer lays down a movie fragment every ten seconds")
    func movieFragmentIntervalIsTenSeconds() {
        let interval = AVAssetWriterBackend.movieFragmentInterval
        #expect(interval.isValid)
        #expect(interval.seconds == 10)
    }
}
