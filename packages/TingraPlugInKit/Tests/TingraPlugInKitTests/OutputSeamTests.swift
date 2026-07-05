//
//  OutputSeamTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Testing

@testable import TingraPlugInKit

/// Tests for the output seam types: the stream configuration, the output
/// identifier, the service error mapping, and the session-timeline rebase.
struct OutputSeamTests {
    // MARK: - StreamConfiguration

    @Test("The configuration defaults mirror CLI.md's compression defaults")
    func configurationDefaults() {
        let configuration = StreamConfiguration()
        #expect(configuration.width == 1920)
        #expect(configuration.height == 1080)
        #expect(configuration.frameRate == 30)
        #expect(configuration.videoCodec == .h264)
        #expect(configuration.videoBitsPerSecond == 4_500_000)
        #expect(configuration.keyframeInterval == 2)
        #expect(configuration.audioCodec == .aac)
        #expect(configuration.audioBitsPerSecond == 160_000)
        #expect(configuration.audioSampleRate == 48_000)
    }

    @Test("Configurations compare equal when matching and unequal when any field differs")
    func configurationEquality() {
        let base = StreamConfiguration()
        #expect(base == StreamConfiguration())
        var different = StreamConfiguration()
        different.videoBitsPerSecond = 6_000_000
        #expect(base != different)
    }

    // MARK: - OutputID

    @Test("Output identifiers round-trip through Codable and compare by raw value")
    func outputIdentifierRoundTrip() throws {
        let id = OutputID(rawValue: "rtmp")
        let encoded = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(OutputID.self, from: encoded)
        #expect(decoded == id)
        #expect(OutputID(rawValue: "rtmp") != OutputID(rawValue: "srt"))
    }

    // MARK: - StreamingServiceError

    @Test(
        "Service errors map to their registered identifiers",
        arguments: [
            (StreamingServiceError.unsupportedDestination("m"), ErrorIdentifier.invalidArgument),
            (StreamingServiceError.connectionRejected("m"), ErrorIdentifier.connectionFailed),
        ]
    )
    func serviceErrorIdentifiers(error: StreamingServiceError, identifier: ErrorIdentifier) {
        #expect(error.identifier == identifier)
    }

    @Test("Service error descriptions carry the message")
    func serviceErrorDescriptions() {
        let error = StreamingServiceError.connectionRejected("The destination refused the handshake.")
        #expect(String(describing: error) == "The destination refused the handshake.")
    }

    @Test("Service errors compare equal when matching and unequal otherwise")
    func serviceErrorEquality() {
        #expect(StreamingServiceError.connectionRejected("a") == .connectionRejected("a"))
        #expect(StreamingServiceError.connectionRejected("a") != .connectionRejected("b"))
        #expect(StreamingServiceError.connectionRejected("a") != .unsupportedDestination("a"))
    }

    // MARK: - StreamingServiceEvent / StreamingStatistics

    @Test("Service events compare by case and payload")
    func serviceEventEquality() {
        #expect(
            StreamingServiceEvent.connectionLost(reason: "closed")
                == StreamingServiceEvent.connectionLost(reason: "closed")
        )
        #expect(
            StreamingServiceEvent.connectionLost(reason: "closed")
                != StreamingServiceEvent.connectionLost(reason: "reset")
        )
    }

    @Test("Statistics compare equal when matching and unequal when a counter differs")
    func statisticsEquality() {
        let base = StreamingStatistics(bytesSent: 1, bytesPerSecond: 2, framesPerSecond: 3)
        #expect(base == StreamingStatistics(bytesSent: 1, bytesPerSecond: 2, framesPerSecond: 3))
        #expect(base != StreamingStatistics(bytesSent: 9, bytesPerSecond: 2, framesPerSecond: 3))
    }

    // MARK: - CapturedAudio.rebased(by:)

    @Test("Rebasing moves the PTS onto the session timeline and keeps the sample data")
    func rebasedMovesPTS() throws {
        let audio = try #require(Self.makeAudio(pts: CMTime(value: 105, timescale: 10), samples: 128))
        let rebased = try #require(audio.rebased(by: CMTime(value: 10, timescale: 1)))
        #expect(rebased.presentationTime == CMTime(value: 5, timescale: 10))
        #expect(CMSampleBufferGetNumSamples(rebased.sampleBuffer) == 128)
        // The original is untouched (immutable after transfer).
        #expect(audio.presentationTime == CMTime(value: 105, timescale: 10))
    }

    /// Creates a mono float32 LPCM buffer with the given PTS.
    private static func makeAudio(pts: CMTime, samples: Int) -> CapturedAudio? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
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
            ) == noErr,
            let format = formatOut
        else { return nil }
        let dataLength = samples * MemoryLayout<Float32>.size
        var blockOut: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataLength,
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
                presentationTimeStamp: pts,
                packetDescriptions: nil,
                sampleBufferOut: &sampleOut
            ) == noErr,
            let sample = sampleOut
        else { return nil }
        return CapturedAudio(sampleBuffer: sample)
    }
}
