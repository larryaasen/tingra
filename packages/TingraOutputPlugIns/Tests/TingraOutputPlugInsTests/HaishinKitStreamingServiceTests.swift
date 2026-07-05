//
//  HaishinKitStreamingServiceTests.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreMedia
import Foundation
import Testing
import TingraPlugInKit
import VideoToolbox

@testable import TingraOutputPlugIns

/// Tests for the endpoint derivation, settings mapping, and buffer
/// conversion behind the HaishinKit seam — pure logic, no network.
struct HaishinKitStreamingServiceTests {
    // MARK: - Endpoint derivation

    @Test("A stream key becomes the publish name and the URL stays the connect command")
    func endpointWithKey() throws {
        let destination = Destination(
            url: try #require(URL(string: "rtmp://localhost:1935/live")),
            streamKey: "tingra_test_key"
        )
        let endpoint = try HaishinKitStreamingService.endpoint(for: destination)
        #expect(endpoint.command == "rtmp://localhost:1935/live")
        #expect(endpoint.streamName == "tingra_test_key")
    }

    @Test("Without a key, the URL's last path component becomes the publish name")
    func endpointWithoutKey() throws {
        let destination = Destination(url: try #require(URL(string: "rtmp://host/app/mystream")))
        let endpoint = try HaishinKitStreamingService.endpoint(for: destination)
        #expect(endpoint.command == "rtmp://host/app")
        #expect(endpoint.streamName == "mystream")
    }

    @Test("A keyless URL with a single path component throws unsupportedDestination")
    func endpointThrowsWithoutStreamName() throws {
        let destination = Destination(url: try #require(URL(string: "rtmp://host/app")))
        #expect(throws: StreamingServiceError.self) {
            _ = try HaishinKitStreamingService.endpoint(for: destination)
        }
    }

    @Test("An empty stream key falls back to the URL path form")
    func endpointWithEmptyKey() throws {
        let destination = Destination(
            url: try #require(URL(string: "rtmp://host/app/name")),
            streamKey: ""
        )
        let endpoint = try HaishinKitStreamingService.endpoint(for: destination)
        #expect(endpoint.streamName == "name")
    }

    // MARK: - Rejection reasons

    @Test("Rejection reasons name the host and never the stream key")
    func rejectionReasonOmitsKey() throws {
        let destination = Destination(
            url: try #require(URL(string: "rtmp://ingest.example.com/live")),
            streamKey: "live_secret_key_value"
        )
        struct SomeError: Error {}
        let reason = HaishinKitStreamingService.rejectionReason(for: SomeError(), destination: destination)
        #expect(reason.contains("ingest.example.com"))
        #expect(!reason.contains("live_secret_key_value"))
    }

    // MARK: - Connection-loss codes

    @Test(
        "Connection close and failure codes classify as loss",
        arguments: [
            ("NetConnection.Connect.Closed", true),
            ("NetConnection.Connect.Failed", true),
            ("NetConnection.Connect.AppShutdown", true),
            ("NetConnection.Connect.Success", false),
            ("NetStream.Publish.Start", false),
        ]
    )
    func lossCodeClassification(code: String, isLoss: Bool) {
        #expect(HaishinKitStreamingService.isConnectionLoss(code: code) == isLoss)
    }

    // MARK: - Settings mapping

    @Test("Video settings carry size, bitrate, High profile, keyframe interval, and frame rate")
    func videoSettingsMapping() {
        let configuration = StreamConfiguration(
            width: 1280,
            height: 720,
            frameRate: 60,
            videoCodec: .h264,
            videoBitsPerSecond: 6_000_000,
            keyframeInterval: 4
        )
        let settings = HaishinKitStreamingService.videoSettings(for: configuration)
        #expect(settings.videoSize == CGSize(width: 1280, height: 720))
        #expect(settings.bitRate == 6_000_000)
        #expect(settings.profileLevel == kVTProfileLevel_H264_High_AutoLevel as String)
        #expect(settings.maxKeyFrameIntervalDuration == 4)
        #expect(settings.expectedFrameRate == 60)
    }

    @Test("HEVC selects the HEVC Main profile")
    func hevcProfileMapping() {
        let configuration = StreamConfiguration(videoCodec: .hevc)
        let settings = HaishinKitStreamingService.videoSettings(for: configuration)
        #expect(settings.profileLevel == kVTProfileLevel_HEVC_Main_AutoLevel as String)
    }

    @Test("Audio settings carry the bitrate and sample rate as AAC")
    func audioSettingsMapping() {
        let configuration = StreamConfiguration(audioBitsPerSecond: 128_000, audioSampleRate: 44_100)
        let settings = HaishinKitStreamingService.audioSettings(for: configuration)
        #expect(settings.bitRate == 128_000)
        #expect(settings.sampleRate == 44_100)
    }

    // MARK: - Buffer conversion

    @Test("A pixel buffer wraps into a sample buffer keeping its session-timeline PTS")
    func videoSampleBufferKeepsPTS() throws {
        let pixelBuffer = try #require(Self.makePixelBuffer(width: 64, height: 64))
        let pts = CMTime(value: 900, timescale: 30)
        let frame = CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: pts)
        let sample = try #require(HaishinKitStreamingService.videoSampleBuffer(for: frame, frameRate: 30))
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == pts)
        #expect(CMSampleBufferGetImageBuffer(sample) != nil)
    }

    @Test("LPCM audio converts to a PCM buffer whose AVAudioTime carries the PTS as host time")
    func audioConversionCarriesPTS() throws {
        let audio = try #require(Self.makeToneAudio(seconds: 2.5, sampleRate: 48_000, samples: 1024))
        let (buffer, when) = try #require(HaishinKitStreamingService.pcmBuffer(for: audio))
        #expect(buffer.frameLength == 1024)
        #expect(buffer.format.sampleRate == 48_000)
        let carried = AVAudioTime.seconds(forHostTime: when.hostTime)
        #expect(abs(carried - 2.5) < 0.001)
    }

    @Test("A zero-sample audio buffer converts to nil rather than a degenerate buffer")
    func emptyAudioConvertsToNil() throws {
        let audio = try #require(Self.makeEmptyAudio(sampleRate: 48_000))
        #expect(HaishinKitStreamingService.pcmBuffer(for: audio) == nil)
    }

    // MARK: - Fixtures

    /// Creates a bare 32BGRA pixel buffer for wrapping tests.
    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var bufferOut: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()] as CFDictionary,
            &bufferOut
        )
        return bufferOut
    }

    /// Creates a zero-sample LPCM buffer — the degenerate shape the
    /// conversion must refuse.
    private static func makeEmptyAudio(sampleRate: Int) -> CapturedAudio? {
        guard let format = makeMonoFloatFormat(sampleRate: sampleRate) else { return nil }
        var sampleOut: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format,
                sampleCount: 0,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleOut
            ) == noErr,
            let sample = sampleOut
        else { return nil }
        return CapturedAudio(sampleBuffer: sample)
    }

    /// The mono float32 LPCM format description the tone generator uses.
    private static func makeMonoFloatFormat(sampleRate: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatOut: CMAudioFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatOut
            ) == noErr
        else { return nil }
        return formatOut
    }

    /// Creates a mono float32 LPCM sample buffer with the given PTS in
    /// seconds — the shape the tone generator yields.
    private static func makeToneAudio(seconds: Double, sampleRate: Int, samples: Int) -> CapturedAudio? {
        guard let format = makeMonoFloatFormat(sampleRate: sampleRate) else { return nil }
        let dataLength = max(samples, 0) * MemoryLayout<Float32>.size
        var blockOut: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: max(dataLength, 1),
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataLength,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockOut
            ) == noErr,
            let block = blockOut
        else { return nil }
        var sampleOut: CMSampleBuffer?
        guard
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: format,
                sampleCount: samples,
                presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil,
                sampleBufferOut: &sampleOut
            ) == noErr,
            let sample = sampleOut
        else { return nil }
        return CapturedAudio(sampleBuffer: sample)
    }
}
