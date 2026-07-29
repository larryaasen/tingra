//
//  InputDefaultsTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Testing

@testable import TingraPlugInKit

/// A minimal input that overrides neither media stream, standing in for a
/// conformance that produces no frames of one kind (a microphone has no
/// video; a camera has no audio).
private struct BareInput: Input {
    let id = InputID(rawValue: "bare")
    let name = "Bare"
    let kind = InputKind.generator

    func start() async throws {}
    func stop() async {}
}

@Suite("Input default streams")
struct InputDefaultsTests {
    @Test("frames() defaults to an already-finished stream for audio-only inputs")
    func defaultFramesStreamFinishes() async {
        var count = 0
        for await _ in BareInput().frames() {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("audio() defaults to an already-finished stream for video-only inputs")
    func defaultAudioStreamFinishes() async {
        var count = 0
        for await _ in BareInput().audio() {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("media defaults to empty, matching what the default streams deliver")
    func defaultMediaIsEmpty() {
        #expect(BareInput().media.isEmpty)
    }

    @Test("the default media declaration agrees with the default streams")
    func defaultMediaAgreesWithDefaultStreams() async {
        // The whole justification for `[]` being the default: an input that
        // overrides neither stream genuinely produces nothing, so anything
        // else would be a declaration the seam itself contradicts.
        let input = BareInput()
        var frameCount = 0
        for await _ in input.frames() { frameCount += 1 }
        var audioCount = 0
        for await _ in input.audio() { audioCount += 1 }

        #expect(input.media.contains(.video) == (frameCount > 0))
        #expect(input.media.contains(.audio) == (audioCount > 0))
    }
}

@Suite("InputMedia")
struct InputMediaTests {
    @Test("video and audio are distinct options")
    func videoAndAudioAreDistinct() {
        #expect(InputMedia.video != InputMedia.audio)
        #expect(!InputMedia.video.contains(.audio))
        #expect(!InputMedia.audio.contains(.video))
    }

    @Test("a combined set contains both options")
    func combinedSetContainsBoth() {
        let both: InputMedia = [.video, .audio]
        #expect(both.contains(.video))
        #expect(both.contains(.audio))
    }

    @Test("an empty set contains neither option")
    func emptySetContainsNeither() {
        let none: InputMedia = []
        #expect(none.isEmpty)
        #expect(!none.contains(.video))
        #expect(!none.contains(.audio))
    }

    @Test("equal sets compare equal and different sets do not")
    func equality() {
        #expect(InputMedia([.video, .audio]) == InputMedia([.audio, .video]))
        #expect(InputMedia.video != InputMedia([.video, .audio]))
    }

    @Test("a set is usable as a dictionary key")
    func hashable() {
        let counts: [InputMedia: Int] = [.video: 1, .audio: 2, [.video, .audio]: 3]
        #expect(counts[.video] == 1)
        #expect(counts[[.video, .audio]] == 3)
    }
}

@Suite("CapturedAudio")
struct CapturedAudioTests {
    @Test("presentationTime reads the sample buffer's PTS")
    func presentationTimeMatchesSampleBuffer() throws {
        let pts = CMTime(value: 48_000, timescale: 48_000)
        let sampleBuffer = try Self.makeSilentSampleBuffer(presentationTime: pts)

        let audio = CapturedAudio(sampleBuffer: sampleBuffer)

        #expect(audio.presentationTime == pts)
    }

    /// Builds a tiny ready-to-use PCM sample buffer (one float32 sample of
    /// silence at 48 kHz) with the given PTS — no hardware involved.
    private static func makeSilentSampleBuffer(presentationTime: CMTime) throws -> CMSampleBuffer {
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
        try #require(
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
        )
        let format = try #require(formatOut)

        var blockOut: CMBlockBuffer?
        try #require(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: 4,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: 4,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockOut
            ) == noErr
        )
        let block = try #require(blockOut)
        try #require(
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4) == noErr)

        var sampleBufferOut: CMSampleBuffer?
        try #require(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: format,
                sampleCount: 1,
                presentationTimeStamp: presentationTime,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBufferOut
            ) == noErr
        )
        return try #require(sampleBufferOut)
    }
}
