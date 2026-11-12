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

        // Feed whichever track the writer will take, the earlier one first.
        // Writing one track to the end and then the other deadlocks: the
        // writer interleaves the file, so once the video runs a couple of
        // seconds ahead it stops taking video until audio arrives — and how
        // far ahead that is depends on the encoder, which is why a
        // video-then-audio fixture passed here and hung on a CI runner,
        // whose virtual machine has no hardware encoder.
        let sampleRate = 48000
        let totalAudioFrames = audioInput == nil ? 0 : sampleRate * frameCount / Int(frameRate)
        let blockFrames = 1024
        var frameIndex = 0
        var audioPosition = 0
        if frameCount == 0 { videoInput.markAsFinished() }
        if totalAudioFrames == 0 { audioInput?.markAsFinished() }
        while frameIndex < frameCount || audioPosition < totalAudioFrames {
            let videoWanted = frameIndex < frameCount
            let audioWanted = audioPosition < totalAudioFrames
            let videoOpen = videoWanted && videoInput.isReadyForMoreMediaData
            let audioOpen = audioWanted && (audioInput?.isReadyForMoreMediaData ?? false)
            guard videoOpen || audioOpen else {
                var pending: [AVAssetWriterInput] = []
                if videoWanted { pending.append(videoInput) }
                if audioWanted, let audioInput { pending.append(audioInput) }
                try await Self.waitUntilAnyIsReady(pending, writer: writer)
                continue
            }
            let videoTime = Double(frameIndex) / Double(frameRate)
            let audioTime = Double(audioPosition) / Double(sampleRate)
            if videoOpen && (!audioOpen || videoTime <= audioTime) {
                let pool = try #require(adaptor.pixelBufferPool)
                let buffer = try Self.makeGrayFrame(level: UInt8(min(255, frameIndex * Self.grayStep)), from: pool)
                try #require(
                    adaptor.append(
                        buffer, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: frameRate)))
                frameIndex += 1
                if frameIndex == frameCount { videoInput.markAsFinished() }
            } else if let audioInput {
                let count = min(blockFrames, totalAudioFrames - audioPosition)
                let sample = try Self.makeAudioSample(
                    frames: count, sampleRate: sampleRate,
                    presentationTime: CMTime(value: CMTimeValue(audioPosition), timescale: CMTimeScale(sampleRate)))
                try #require(audioInput.append(sample))
                audioPosition += count
                if audioPosition == totalAudioFrames { audioInput.markAsFinished() }
            }
        }
        await writer.finishWriting()
        try #require(
            writer.status == .completed, "movie fixture: \(writer.error.map(String.init(describing:)) ?? "no error")")
        return url
    }

    /// The containers ``writeAudio(_:seconds:sampleRate:channels:name:)``
    /// writes.
    enum AudioFormat {
        /// 16-bit integer linear PCM in a `.wav`: sample-exact, so a test
        /// can count frames.
        case wav

        /// AAC in an `.m4a`: a compressed file, whose decoded length is
        /// only close to what was written.
        case m4a

        /// The file name the fixture takes by default.
        var defaultName: String {
            switch self {
            case .wav: "music.wav"
            case .m4a: "music.m4a"
            }
        }
    }

    /// Writes an audio file holding a 440 Hz sine on every channel.
    ///
    /// - Parameters:
    ///   - format: The container and codec.
    ///   - seconds: How long the sound runs; zero writes a file with a
    ///     header and no samples.
    ///   - sampleRate: The file's sample rate.
    ///   - channels: The file's channel count.
    ///   - name: The file name, or nil for the format's default.
    /// - Returns: The file's URL.
    func writeAudio(
        _ format: AudioFormat = .wav, seconds: Double = 1, sampleRate: Double = 44100, channels: UInt32 = 2,
        name: String? = nil
    ) throws -> URL {
        let url = folder.appending(path: name ?? format.defaultName)
        let settings: [String: Any] =
            switch format {
            case .wav:
                [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
            case .m4a:
                [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                ]
            }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        // Closed before returning either way, so the reader under test
        // opens a finished file.
        defer { file.close() }
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard frames > 0 else { return url }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(file.processingFormat.channelCount) {
            for frame in 0..<Int(frames) {
                data[channel][frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 0.25)
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// The gray-level step between successive fixture frames.
    static let grayStep = 20

    /// How long ``waitUntilAnyIsReady(_:writer:)`` waits before giving up.
    /// The fixture clip is about a second long, so a wait this long means the
    /// writer has stalled, and the test should say so rather than hang.
    private static let readinessTimeout = Duration.seconds(10)

    /// The fixture writer stopped taking media: no input it still had samples
    /// for became ready within ``readinessTimeout``.
    struct MovieWriterStalled: Error, CustomStringConvertible {
        /// The writer's status when the wait gave up.
        let status: AVAssetWriter.Status

        /// The writer's error, if it reported one.
        let underlying: (any Error)?

        /// Names the stall and the writer's state, for the test's failure.
        var description: String {
            "movie fixture: the writer took no media for \(MediaFixtures.readinessTimeout) "
                + "(status \(status.rawValue), error: \(underlying.map(String.init(describing:)) ?? "none"))"
        }
    }

    /// Returns once any of `inputs` is ready for more media, woken by each
    /// input's key-value observation of `isReadyForMoreMediaData` rather than
    /// by checking on a timer.
    ///
    /// - Parameters:
    ///   - inputs: The inputs that still have samples to append.
    ///   - writer: Their writer, whose state names a stall.
    /// - Throws: ``MovieWriterStalled`` when none becomes ready within
    ///   ``readinessTimeout``.
    private static func waitUntilAnyIsReady(_ inputs: [AVAssetWriterInput], writer: AVAssetWriter) async throws {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observations = inputs.map { input in
            input.observe(\.isReadyForMoreMediaData) { _, _ in continuation.yield() }
        }
        let deadline = Task {
            try? await Task.sleep(for: readinessTimeout)
            continuation.finish()
        }
        defer {
            deadline.cancel()
            observations.forEach { $0.invalidate() }
        }
        // Checked after observing, so a change between the caller's check and
        // the observation is not lost.
        if inputs.contains(where: \.isReadyForMoreMediaData) { return }
        for await _ in changes where inputs.contains(where: \.isReadyForMoreMediaData) {
            return
        }
        throw MovieWriterStalled(status: writer.status, underlying: writer.error)
    }

    /// A BGRA frame from `pool`, every pixel opaque gray at `level`.
    private static func makeGrayFrame(level: UInt8, from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var bufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut)
        let buffer = try #require(bufferOut)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let rowPointer = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<CVPixelBufferGetWidth(buffer) {
                rowPointer[column * 4] = level
                rowPointer[column * 4 + 1] = level
                rowPointer[column * 4 + 2] = level
                rowPointer[column * 4 + 3] = 255
            }
        }
        return buffer
    }

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
