//
//  AVAssetWriterBackend.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreMedia
import TingraPlugInKit

/// The production ``RecordingWriterBackend``: an `AVAssetWriter` writing the
/// program to a local `.mov`/`.mp4` file with hardware compression — the one
/// type in the monorepo that touches `AVFoundation` for recording.
///
/// An actor so its non-`Sendable` `AVAssetWriter`, its inputs, and the pixel
/// buffer adaptor stay isolated to one execution context without any
/// `@unchecked Sendable` (ARCHITECTURE.md sanctions only the two frame
/// wrappers). The session appends already-rebased program media (PTS on the
/// shared session timeline, `hostTime − T0`); the writer session is anchored
/// at `.zero`, and any buffer that predates it (a rare in-flight audio buffer
/// captured before `T0`) is dropped rather than clamped, so track timestamps
/// stay strictly increasing.
actor AVAssetWriterBackend: RecordingWriterBackend {
    /// The writer, while recording.
    private var writer: AVAssetWriter?

    /// The video track input, when the program has video.
    private var videoInput: AVAssetWriterInput?

    /// The audio track input, when the program has audio.
    private var audioInput: AVAssetWriterInput?

    /// The pixel buffer adaptor feeding ``videoInput``.
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    /// Creates a backend. The writer is opened in ``open(file:configuration:)``.
    init() {}

    /// Opens the file, adds the enabled tracks, starts writing, and anchors
    /// the session at time zero.
    func open(file: RecordingFile, configuration: StreamConfiguration) throws {
        // AVAssetWriter refuses to overwrite an existing file; clear a stale
        // one first so a re-run does not fail on a leftover.
        try? FileManager.default.removeItem(at: file.url)

        let fileType: AVFileType = file.container == .mp4 ? .mp4 : .mov
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: file.url, fileType: fileType)
        } catch {
            throw RecordingServiceError.unwritableDestination(
                "The recording could not be created at '\(file.url.path)': \(error.localizedDescription)"
            )
        }

        if configuration.includesVideo {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(configuration))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingServiceError.writerNotReady(
                    "The recording writer rejected the video track for the requested compression settings."
                )
            }
            writer.add(input)
            videoInput = input
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: Self.pixelBufferAttributes(configuration)
            )
        }
        if configuration.includesAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(configuration))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingServiceError.writerNotReady(
                    "The recording writer rejected the audio track for the requested compression settings."
                )
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw RecordingServiceError.writerNotReady(
                "The recording writer refused to start: \(writer.error?.localizedDescription ?? "unknown error")."
            )
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
    }

    /// Appends a video frame through the pixel buffer adaptor, dropping it
    /// on backpressure or a pre-session PTS.
    func appendVideo(_ frame: CapturedFrame) -> Bool {
        guard let writer, let videoInput, let adaptor else { return true }
        if writer.status == .failed { return false }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return true }
        let pts = frame.presentationTime
        guard pts.isValid, pts >= .zero else { return true }
        if adaptor.append(frame.pixelBuffer, withPresentationTime: pts) { return true }
        // A false return without a failed status is transient (dropped);
        // only a failed writer is a terminal error.
        return writer.status != .failed
    }

    /// Appends an audio buffer to the audio track, dropping it on
    /// backpressure or a pre-session PTS.
    func appendAudio(_ buffer: CapturedAudio) -> Bool {
        guard let writer, let audioInput else { return true }
        if writer.status == .failed { return false }
        guard writer.status == .writing, audioInput.isReadyForMoreMediaData else { return true }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer.sampleBuffer)
        guard pts.isValid, pts >= .zero else { return true }
        if audioInput.append(buffer.sampleBuffer) { return true }
        return writer.status != .failed
    }

    /// Marks the tracks finished and finalizes the file.
    func finish() async {
        guard let writer else { return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        guard writer.status == .writing else { return }
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    /// The writer's terminal failure description, if it failed.
    func failureReason() -> String? {
        guard let writer, writer.status == .failed else { return nil }
        return writer.error?.localizedDescription ?? "the recording writer failed"
    }

    // MARK: - Settings mapping

    /// `AVAssetWriter` video output settings for a configuration: codec,
    /// dimensions, bitrate, keyframe interval, and BT.709 color tags (so the
    /// recording carries the same color description ARCHITECTURE.md requires
    /// of every delivery, "Color and pixel format conventions").
    static func videoSettings(_ configuration: StreamConfiguration) -> [String: Any] {
        let codec: AVVideoCodecType = configuration.videoCodec == .hevc ? .hevc : .h264
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: configuration.videoBitsPerSecond,
            AVVideoMaxKeyFrameIntervalDurationKey: configuration.keyframeInterval,
        ]
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: color,
        ]
    }

    /// The source pixel buffer attributes for the adaptor: the working
    /// format (32BGRA) at the program dimensions.
    static func pixelBufferAttributes(_ configuration: StreamConfiguration) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: configuration.width,
            kCVPixelBufferHeightKey as String: configuration.height,
        ]
    }

    /// `AVAssetWriter` audio output settings: mono AAC at the configured
    /// sample rate and bitrate. Multi-channel program audio arrives with the
    /// audio mixer (roadmap step 7); v1 records the single program channel.
    static func audioSettings(_ configuration: StreamConfiguration) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: configuration.audioSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: configuration.audioBitsPerSecond,
            AVChannelLayoutKey: layoutData,
        ]
    }
}
