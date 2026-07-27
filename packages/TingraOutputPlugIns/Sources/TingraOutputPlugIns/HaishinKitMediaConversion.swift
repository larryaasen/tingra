//
//  HaishinKitMediaConversion.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-24.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreMedia
import HaishinKit
import TingraPlugInKit
import VideoToolbox

/// The compression-settings mapping and buffer conversion shared by both
/// HaishinKit-backed streaming services (RTMP and SRT).
///
/// Both `RTMPStream` and `SRTStream` take the identical settings types
/// (``VideoCodecSettings``/``AudioCodecSettings``) and the identical append
/// forms (an uncompressed video `CMSampleBuffer`, and LPCM audio as
/// `AVAudioPCMBuffer` + `AVAudioTime`), so the conversion is transport-neutral
/// and lives here once rather than being duplicated per service (CLAUDE.md,
/// DRY). The seam facts these build on were verified by the de-risking spike
/// (TODO.md): uncompressed video keeps its session-timeline PTS through the
/// encoder, and LPCM audio must enter as `AVAudioPCMBuffer` + `AVAudioTime`
/// (HaishinKit's `CMSampleBuffer` audio path drops LPCM when the output codec
/// is AAC).
enum HaishinKitMediaConversion {
    // MARK: - Settings mapping

    /// HaishinKit video codec settings for a stream configuration: size,
    /// bitrate, profile (High for H.264, Main for HEVC — never the
    /// Baseline default), keyframe interval, and expected frame rate.
    static func videoSettings(for configuration: StreamConfiguration) -> VideoCodecSettings {
        let profileLevel =
            switch configuration.videoCodec {
            case .h264: kVTProfileLevel_H264_High_AutoLevel as String
            case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel as String
            }
        return VideoCodecSettings(
            videoSize: CGSize(width: configuration.width, height: configuration.height),
            bitRate: configuration.videoBitsPerSecond,
            profileLevel: profileLevel,
            maxKeyFrameIntervalDuration: Int32(configuration.keyframeInterval),
            expectedFrameRate: Double(configuration.frameRate)
        )
    }

    /// HaishinKit audio codec settings for a stream configuration: AAC at
    /// the configured bitrate and sample rate.
    static func audioSettings(for configuration: StreamConfiguration) -> AudioCodecSettings {
        AudioCodecSettings(
            bitRate: configuration.audioBitsPerSecond,
            sampleRate: Float64(configuration.audioSampleRate),
            format: .aac
        )
    }

    // MARK: - Buffer conversion

    /// Wraps a program frame's pixel buffer in an uncompressed
    /// `CMSampleBuffer` carrying the frame's session-timeline PTS, the
    /// form HaishinKit compresses internally. Returns nil if Core Media
    /// cannot create the wrapper — a failed frame is skipped, never fatal.
    static func videoSampleBuffer(for frame: CapturedFrame, frameRate: Int) -> CMSampleBuffer? {
        var formatOut: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &formatOut
            ) == noErr,
            let format = formatOut
        else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: frame.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleOut: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sampleOut
            ) == noErr
        else { return nil }
        return sampleOut
    }

    /// Converts LPCM program audio into the `AVAudioPCMBuffer` +
    /// `AVAudioTime` pair HaishinKit's AAC path requires, the
    /// session-timeline PTS carried as the `AVAudioTime`'s host time.
    /// Returns nil for a non-PCM buffer or a failed copy — skipped, never
    /// fatal.
    static func pcmBuffer(for audio: CapturedAudio) -> (AVAudioPCMBuffer, AVAudioTime)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(audio.sampleBuffer) else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(audio.sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                audio.sampleBuffer,
                at: 0,
                frameCount: Int32(frames),
                into: buffer.mutableAudioBufferList
            ) == noErr
        else { return nil }
        let seconds = max(0, audio.presentationTime.seconds)
        let when = AVAudioTime(
            hostTime: AVAudioTime.hostTime(forSeconds: seconds),
            sampleTime: AVAudioFramePosition(seconds * format.sampleRate),
            atRate: format.sampleRate
        )
        return (buffer, when)
    }
}
