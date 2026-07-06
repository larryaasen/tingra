//
//  RecordingTestSupport.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import TingraPlugInKit

/// Creates a small IOSurface-backed 32BGRA frame with the given PTS.
func makeFrame(pts: CMTime) -> CapturedFrame? {
    var bufferOut: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()] as CFDictionary,
        &bufferOut
    )
    guard let pixelBuffer = bufferOut else { return nil }
    return CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: pts)
}

/// Creates a mono float32 LPCM audio buffer with the given PTS.
func makeAudio(pts: CMTime, samples: Int = 256, sampleRate: Int = 48_000) -> CapturedAudio? {
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
