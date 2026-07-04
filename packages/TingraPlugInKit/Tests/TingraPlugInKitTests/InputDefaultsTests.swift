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
