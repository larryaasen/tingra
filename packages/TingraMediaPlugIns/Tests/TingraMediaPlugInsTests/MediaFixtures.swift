//
//  MediaFixtures.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Files the media tests write into a throwaway folder — an image, text
/// documents, and a small movie — so no test depends on a checked-in
/// binary or a real library.
struct MediaFixtures {
    /// The throwaway folder, removed by ``remove()``.
    let folder: URL

    /// Creates a fresh folder under the temporary directory.
    init() throws {
        folder = URL.temporaryDirectory.appending(path: "tingra-media-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Removes the folder and everything in it.
    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Writes a PNG whose left half is opaque red and whose right half is
    /// fully transparent, at the given size.
    ///
    /// - Returns: The file's URL.
    func writePNG(width: Int = 64, height: Int = 48, name: String = "poster.png") throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(context.makeImage())
        let url = folder.appending(path: name)
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    /// Writes a text file with the given contents and name.
    ///
    /// - Returns: The file's URL.
    func writeText(_ text: String, name: String = "notes.txt") throws -> URL {
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Writes raw bytes under the given name.
    ///
    /// - Returns: The file's URL.
    func writeBytes(_ bytes: [UInt8], name: String) throws -> URL {
        let url = folder.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    /// The pixel size of the fixture movie.
    static let movieSize = 64

    /// Writes an H.264 `.mov` of `frameCount` solid gray frames at `frameRate`
    /// — frame `n` is gray level `n * grayStep` — with, optionally, a mono
    /// 16-bit LPCM sine track of the same duration.
    ///
    /// - Returns: The file's URL.
    func writeMovie(
        frameCount: Int = 12, frameRate: Int32 = 12, withAudio: Bool = true, name: String = "clip.mov"
    ) async throws -> URL {
        let url = folder.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let size = Self.movieSize
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size,
                AVVideoHeightKey: size,
            ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size,
            ])
        try #require(writer.canAdd(videoInput))
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if withAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            input.expectsMediaDataInRealTime = false
            try #require(writer.canAdd(input))
            writer.add(input)
            audioInput = input
        }

        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var bufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut)
            let buffer = try #require(bufferOut)
            CVPixelBufferLockBaseAddress(buffer, [])
            let gray = UInt8(min(255, index * Self.grayStep))
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<size {
                let rowPointer = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for column in 0..<size {
                    rowPointer[column * 4] = gray
                    rowPointer[column * 4 + 1] = gray
                    rowPointer[column * 4 + 2] = gray
                    rowPointer[column * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: frameRate)))
        }
        videoInput.markAsFinished()

        if let audioInput {
            let sampleRate = 48000
            let totalFrames = sampleRate * frameCount / Int(frameRate)
            let blockFrames = 1024
            var position = 0
            while position < totalFrames {
                while !audioInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                let count = min(blockFrames, totalFrames - position)
                let sample = try Self.makeAudioSample(
                    frames: count, sampleRate: sampleRate,
                    presentationTime: CMTime(value: CMTimeValue(position), timescale: CMTimeScale(sampleRate)))
                try #require(audioInput.append(sample))
                position += count
            }
            audioInput.markAsFinished()
        }
        await writer.finishWriting()
        try #require(
            writer.status == .completed, "movie fixture: \(writer.error.map(String.init(describing:)) ?? "no error")")
        return url
    }

    /// The gray-level step between successive fixture frames.
    static let grayStep = 20

    /// One block of a 440 Hz mono 16-bit sine at the given position.
    private static func makeAudioSample(frames: Int, sampleRate: Int, presentationTime: CMTime) throws -> CMSampleBuffer
    {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
            mReserved: 0)
        var formatOut: CMAudioFormatDescription?
        try #require(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &formatOut) == noErr)
        let format = try #require(formatOut)
        let start = Int(presentationTime.value)
        let samples: [Int16] = (0..<frames).map { offset in
            Int16(sin(2 * Double.pi * 440 * Double(start + offset) / Double(sampleRate)) * 8000)
        }
        let length = samples.count * 2
        var blockOut: CMBlockBuffer?
        try #require(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockOut) == noErr)
        let block = try #require(blockOut)
        try samples.withUnsafeBytes { bytes in
            try #require(
                CMBlockBufferReplaceDataBytes(
                    with: try #require(bytes.baseAddress), blockBuffer: block, offsetIntoDestination: 0,
                    dataLength: length)
                    == noErr)
        }
        var sampleOut: CMSampleBuffer?
        try #require(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
                presentationTimeStamp: presentationTime, packetDescriptions: nil, sampleBufferOut: &sampleOut) == noErr)
        return try #require(sampleOut)
    }

    /// The blue-channel value (equal to the gray level) at the center of a
    /// BGRA buffer.
    static func centerGray(of buffer: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let row = CVPixelBufferGetHeight(buffer) / 2
        let column = CVPixelBufferGetWidth(buffer) / 2
        let pointer = base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer) + column * 4)
            .assumingMemoryBound(to: UInt8.self)
        return pointer[0]
    }

    /// The BGRA bytes of one pixel.
    static func pixel(of buffer: CVPixelBuffer, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0, 0) }
        let pointer = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(
            to: UInt8.self)
        return (pointer[0], pointer[1], pointer[2], pointer[3])
    }

    /// Whether the buffer carries all three color attachments, whatever
    /// they say — an untagged buffer is a defect, but a movie keeps the
    /// colorimetry its track declares.
    static func hasColorTags(_ buffer: CVPixelBuffer) -> Bool {
        CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) != nil
            && CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) != nil
            && CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) != nil
    }

    /// Whether the buffer carries the three BT.709 color attachments.
    static func isTaggedBT709(_ buffer: CVPixelBuffer) -> Bool {
        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        return primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String
            && transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String
            && matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
    }
}
