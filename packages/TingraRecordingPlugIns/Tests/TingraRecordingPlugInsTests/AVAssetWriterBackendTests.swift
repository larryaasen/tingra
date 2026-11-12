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

    @Test("Video is written with the configured codec and bit rate")
    func videoSettingsFollowTheCodec() throws {
        let h264 = AVAssetWriterBackend.videoSettings(StreamConfiguration(videoCodec: .h264))
        #expect(h264[AVVideoCodecKey] as? AVVideoCodecType == .h264)

        let configuration = StreamConfiguration(videoCodec: .hevc, videoBitsPerSecond: 2_700_000)
        let hevc = AVAssetWriterBackend.videoSettings(configuration)
        #expect(hevc[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        let compression = try #require(hevc[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(compression[AVVideoAverageBitRateKey] as? Int == 2_700_000)
    }

    @Test(
        "The writer accepts both codecs, and audio from 96 to 320 kbps, in both containers",
        arguments: [AVFileType.mov, AVFileType.mp4])
    func writerAcceptsTheOfferedSettings(fileType: AVFileType) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tingra-settings-\(UUID().uuidString)")
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        for codec in StreamConfiguration.VideoCodec.allCases {
            let settings = AVAssetWriterBackend.videoSettings(StreamConfiguration(videoCodec: codec))
            #expect(writer.canApply(outputSettings: settings, forMediaType: .video), "\(codec) in \(fileType)")
        }
        for rate in [96_000, 128_000, 160_000, 192_000, 256_000, 320_000] {
            let settings = AVAssetWriterBackend.audioSettings(StreamConfiguration(audioBitsPerSecond: rate))
            #expect(writer.canApply(outputSettings: settings, forMediaType: .audio), "\(rate) in \(fileType)")
        }
    }

    @Test("The writer lays down a movie fragment every ten seconds")
    func movieFragmentIntervalIsTenSeconds() {
        let interval = AVAssetWriterBackend.movieFragmentInterval
        #expect(interval.isValid)
        #expect(interval.seconds == 10)
    }
}
