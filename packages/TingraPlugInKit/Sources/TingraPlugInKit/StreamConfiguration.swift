//
//  StreamConfiguration.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The compression and program settings a stream session runs with,
/// handed to a ``StreamingServiceProvider`` when a streaming service is
/// created (see CLI.md, "Compression", for the option surface these come
/// from, and ARCHITECTURE.md: compression happens at the sinks, so the
/// service drives its internal compressor from these values).
///
/// Contains no secrets — the stream key travels only inside
/// ``Destination``.
public struct StreamConfiguration: Sendable, Equatable {
    /// The video codecs a stream can compress with (CLI.md: H.264 has the
    /// broadest destination support; HEVC where the destination accepts it).
    public enum VideoCodec: String, Sendable, Codable, CaseIterable {
        /// H.264/AVC.
        case h264

        /// H.265/HEVC.
        case hevc
    }

    /// The audio codecs a stream can compress with (AAC only in v1).
    public enum AudioCodec: String, Sendable, Codable, CaseIterable {
        /// AAC-LC.
        case aac
    }

    /// The program width in pixels (even — 4:2:0 delivery requires it).
    public var width: Int

    /// The program height in pixels (even — 4:2:0 delivery requires it).
    public var height: Int

    /// The program frame rate the tick fires at (see CLOCK.md).
    public var frameRate: Int

    /// The video codec.
    public var videoCodec: VideoCodec

    /// The video bitrate in bits per second.
    public var videoBitsPerSecond: Int

    /// The keyframe interval in seconds (CLI.md default 2, the
    /// Twitch/YouTube recommendation).
    public var keyframeInterval: Int

    /// The audio codec.
    public var audioCodec: AudioCodec

    /// The audio bitrate in bits per second.
    public var audioBitsPerSecond: Int

    /// The audio sample rate in Hertz.
    public var audioSampleRate: Int

    /// Creates a configuration. Defaults mirror CLI.md's "Compression"
    /// defaults (1080p30, H.264 at 4500k, AAC at 160k / 48 kHz).
    ///
    /// - Parameters:
    ///   - width: Program width in pixels.
    ///   - height: Program height in pixels.
    ///   - frameRate: Program frame rate.
    ///   - videoCodec: Video codec.
    ///   - videoBitsPerSecond: Video bitrate in bits per second.
    ///   - keyframeInterval: Keyframe interval in seconds.
    ///   - audioCodec: Audio codec.
    ///   - audioBitsPerSecond: Audio bitrate in bits per second.
    ///   - audioSampleRate: Audio sample rate in Hertz.
    public init(
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Int = 30,
        videoCodec: VideoCodec = .h264,
        videoBitsPerSecond: Int = 4_500_000,
        keyframeInterval: Int = 2,
        audioCodec: AudioCodec = .aac,
        audioBitsPerSecond: Int = 160_000,
        audioSampleRate: Int = 48_000
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.videoBitsPerSecond = videoBitsPerSecond
        self.keyframeInterval = keyframeInterval
        self.audioCodec = audioCodec
        self.audioBitsPerSecond = audioBitsPerSecond
        self.audioSampleRate = audioSampleRate
    }
}
