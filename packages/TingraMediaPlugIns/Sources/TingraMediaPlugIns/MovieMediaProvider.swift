//
//  MovieMediaProvider.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import TingraEventBus
import TingraPlugInKit
import UniformTypeIdentifiers

/// The provider for video files: every container and codec AVFoundation
/// reads (`public.movie`).
public struct MovieMediaProvider: MediaInputProvider {
    /// The provider's stable identifier.
    public static let providerID = MediaProviderID(rawValue: "com.moonwink.tingra.media.movie")

    /// The stable identifier.
    public var id: MediaProviderID { Self.providerID }

    /// The user-facing name.
    public let name = "Movie"

    /// Every movie format AVFoundation reads.
    public let contentTypes: [UTType] = [.movie]

    /// The clock that paces playback and stamps frames.
    private let clock: any EngineClock

    /// The event bus, for reporting a read problem.
    private let eventBus: EventBus?

    /// Creates the provider.
    ///
    /// - Parameters:
    ///   - clock: The master clock, pacing playback.
    ///   - eventBus: The host's event bus, for read diagnostics. Omit it
    ///     where those are not wanted (tests).
    public init(clock: any EngineClock, eventBus: EventBus? = nil) {
        self.clock = clock
        self.eventBus = eventBus
    }

    /// Creates a movie input for the file. Never throws: the file is opened
    /// at ``Input/start()``, where a problem is reported.
    public func makeInput(for url: URL, id: InputID) throws -> any Input {
        MovieInput(id: id, url: url, clock: clock, eventBus: eventBus)
    }
}

/// A video file as an input: read through `AVAssetReader`, paced by the
/// master clock at the file's own frame rate, its presentation times
/// remapped onto the clock from the moment playback starts, **looping
/// continuously** while started (ARCHITECTURE.md, "Media inputs and the
/// Library's Media tab"). The audio track, when there is one, arrives as
/// ``CapturedAudio`` blocks on the same timeline, so the file gets a
/// channel strip.
///
/// Declares both media whether or not the file has an audio track: which
/// tracks a file holds is known only once the asset loads, after the
/// declaration is read, and a strip that stays silent costs less than a
/// file whose sound is never offered.
///
/// Per-layer playback behaviour — once, hold last frame, restart on take —
/// is the next slice; this input loops, the usual default for a video file.
public final class MovieInput: Input, Sendable {
    /// The tick cadence ceiling: a file faster than this is still read at
    /// its own rate but sampled at this one, latest wins.
    static let maximumTickRate: Double = 60

    /// The tick cadence for a file that reports no frame rate.
    static let fallbackFrameRate: Double = 30

    /// The stable identifier — the project's identity for the file.
    public let id: InputID

    /// The user-facing name: the file's name.
    public let name: String

    /// Media is its own input kind (see GLOSSARY.md).
    public let kind = InputKind.media

    /// Picture, and sound when the file has any (see the type note).
    public let media: InputMedia = [.video, .audio]

    /// The clock-paced, looping playback this input shares with
    /// ``AudioFileInput`` (``MediaFilePlayback``).
    private let playback: MediaFilePlayback

    /// Creates a movie input for the file.
    ///
    /// - Parameters:
    ///   - id: The stable identifier the input reports.
    ///   - url: The movie file.
    ///   - clock: The master clock, pacing playback.
    ///   - eventBus: The host's event bus, or nil for no diagnostics.
    public init(id: InputID, url: URL, clock: any EngineClock, eventBus: EventBus? = nil) {
        self.id = id
        self.name = url.lastPathComponent
        self.playback = MediaFilePlayback(id: id, url: url, content: .movie, clock: clock, eventBus: eventBus)
    }

    /// Opens the file, checks it has a video track, and starts the clock-
    /// paced playback task. Starting an already started input does nothing.
    ///
    /// - Throws: ``MediaInputError/fileUnreadable(_:)`` if the file cannot
    ///   be read, ``MediaInputError/noVideoTrack(_:)`` if it has no picture,
    ///   or ``MediaInputError/readerRefused(_:reason:)`` if AVFoundation
    ///   will not read it. Reported as a `media.decode` error event before
    ///   it propagates.
    public func start() async throws {
        try await playback.start()
    }

    /// The stream of frames, one per tick while the file plays. Finishes any
    /// previous consumer's stream first.
    public func frames() -> AsyncStream<CapturedFrame> {
        playback.frames()
    }

    /// The stream of audio blocks, as the file's timeline reaches them.
    /// Finishes any previous consumer's stream first.
    public func audio() -> AsyncStream<CapturedAudio> {
        playback.audio()
    }

    /// Stops playback and finishes both streams. Safe to call more than
    /// once.
    public func stop() async {
        await playback.stop()
    }
}

/// What a file input (``MovieInput``, ``AudioFileInput``) learns about a
/// file at start and hands its playback task: the tracks and the timing.
struct MovieDescription: Sendable {
    /// The file's video track, by identifier — a track object is not
    /// `Sendable`, so each reader resolves its own. Nil for a file played
    /// for its sound alone.
    let videoTrackID: CMPersistentTrackID?

    /// The file's first audio track, by identifier, if any.
    let audioTrackID: CMPersistentTrackID?

    /// The file's duration.
    let duration: CMTime

    /// The video track's nominal frame rate, or the fallback; for a file
    /// played for its sound alone, the cadence its blocks are delivered at
    /// (``AudioFileInput/deliveryRate``).
    let frameRate: Double

    /// Loads the file's tracks and duration.
    ///
    /// - Parameters:
    ///   - url: The file.
    ///   - content: What the file is played for, which decides the track it
    ///     must hold: a movie its picture, an audio file its sound.
    /// - Throws: A ``MediaInputError`` naming the problem:
    ///   ``MediaInputError/fileUnreadable(_:)`` for a file that cannot be
    ///   opened, ``MediaInputError/readerRefused(_:reason:)`` when
    ///   AVFoundation will not read it, ``MediaInputError/noVideoTrack(_:)``
    ///   for a movie without picture, and
    ///   ``MediaInputError/noAudioTrack(_:)`` or
    ///   ``MediaInputError/audioEmpty(_:)`` for an audio file with no sound
    ///   track or no samples in it.
    static func load(_ url: URL, content: MediaFileContent) async throws(MediaInputError) -> MovieDescription {
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            throw .fileUnreadable(url)
        }
        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        let duration: CMTime
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw .readerRefused(url, reason: error.localizedDescription)
        }
        if content == .sound {
            // A picture track in an audio file (cover art some containers
            // carry as video) is not played: the input declares sound only.
            guard let audioTrack = audioTracks.first else { throw .noAudioTrack(url) }
            guard duration.isNumeric, duration > .zero else { throw .audioEmpty(url) }
            return MovieDescription(
                videoTrackID: nil,
                audioTrackID: audioTrack.trackID,
                duration: duration,
                frameRate: AudioFileInput.deliveryRate
            )
        }
        guard let videoTrack = videoTracks.first else { throw .noVideoTrack(url) }
        let nominal = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
        return MovieDescription(
            videoTrackID: videoTrack.trackID,
            audioTrackID: audioTracks.first?.trackID,
            duration: duration,
            frameRate: nominal > 0 ? Double(nominal) : MovieInput.fallbackFrameRate
        )
    }
}

/// One pass through a movie or audio file: an `AVAssetReader` with, when
/// the file is played for its picture, a video output in the working pixel
/// format and, when the file has sound, an audio output in the mixer's
/// native float32 deinterleaved form, each read one sample ahead so a tick
/// can ask "everything due by now".
///
/// Not `Sendable` by design: it lives inside the playback task, the same
/// rule as the generators' renderers.
final class MovieReader {
    /// The reader.
    private let reader: AVAssetReader

    /// The video output, when the file is played for its picture.
    private let video: AVAssetReaderTrackOutput?

    /// The audio output, when the file has an audio track.
    private let audio: AVAssetReaderTrackOutput?

    /// The next video sample not yet due, read ahead.
    private var pendingVideo: CMSampleBuffer?

    /// The next audio sample not yet due, read ahead.
    private var pendingAudio: CMSampleBuffer?

    /// Whether the video output has delivered its last sample (true at once
    /// for a file played for its sound alone).
    private var videoEnded: Bool

    /// Where the audio read so far ends on the file's timeline — the end of
    /// the latest audio sample read — or invalid before the first.
    private var audioEnd = CMTime.invalid

    /// Whether the audio output has delivered its last sample (true at once
    /// for a file without sound).
    private var audioEnded: Bool

    /// The file's duration as its asset reports it.
    private let assetDuration: CMTime

    /// Whether this pass reads a picture.
    var hasVideo: Bool { video != nil }

    /// How long this pass ran, added to the loop offset when it ends. A
    /// movie's is the file's duration. An audio file's is **where its last
    /// decoded sample ended**: a compressed file's reported duration is an
    /// estimate that can sit a few milliseconds either side of what the
    /// decoder hands over, and looping on the measured end puts the next
    /// pass's first block exactly where this pass's last one stopped —
    /// timestamps that neither overlap nor gap.
    var duration: CMTime {
        guard !hasVideo, hasReadAudio else { return assetDuration }
        return audioEnd
    }

    /// Whether this pass has read any sound: at least one audio sample, with
    /// a length. False for a pass over a file that holds none, which is how
    /// the playback loop tells an empty file from one that merely ended.
    var hasReadAudio: Bool {
        audioEnd.isNumeric && audioEnd > .zero
    }

    /// Opens a reader at the file's start.
    ///
    /// - Throws: ``MediaInputError/readerRefused(_:reason:)`` if
    ///   AVFoundation will not read the file, or
    ///   ``MediaInputError/noVideoTrack(_:)`` if the video track described
    ///   at start is gone (the file replaced while playing).
    init(url: URL, description: MovieDescription) async throws(MediaInputError) {
        let asset = AVURLAsset(url: url)
        let videoTrack: AVAssetTrack?
        let audioTrack: AVAssetTrack?
        do {
            reader = try AVAssetReader(asset: asset)
            if let videoID = description.videoTrackID {
                guard let track = try await asset.loadTrack(withTrackID: videoID) else {
                    throw MediaInputError.noVideoTrack(url)
                }
                videoTrack = track
            } else {
                videoTrack = nil
            }
            if let audioID = description.audioTrackID {
                audioTrack = try await asset.loadTrack(withTrackID: audioID)
            } else {
                audioTrack = nil
            }
        } catch let error as MediaInputError {
            throw error
        } catch {
            throw .readerRefused(url, reason: error.localizedDescription)
        }
        if let track = videoTrack {
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ]
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            video = output
            videoEnded = false
        } else {
            video = nil
            videoEnded = true
        }
        if let track = audioTrack {
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                    AVLinearPCMIsBigEndianKey: false,
                ]
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            audio = output
            audioEnded = false
        } else {
            audio = nil
            audioEnded = true
        }
        assetDuration = description.duration
        guard reader.startReading() else {
            throw .readerRefused(url, reason: reader.error?.localizedDescription ?? "the reader would not start")
        }
    }

    /// Whether both outputs have delivered their last sample.
    var isAtEnd: Bool {
        videoEnded && audioEnded
    }

    /// The latest video frame whose presentation time is at or before
    /// `position` in the file, or nil when none is due yet. Frames due
    /// before it are skipped — latest wins.
    func latestVideoFrame(upTo position: CMTime) -> CVPixelBuffer? {
        var latest: CVPixelBuffer?
        while let sample = nextVideo(), CMSampleBufferGetPresentationTimeStamp(sample) <= position {
            pendingVideo = nil
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                latest = pixelBuffer
            }
        }
        return latest
    }

    /// Every audio block whose presentation time is at or before
    /// `position` in the file, in order, still on the file's timeline.
    func audio(upTo position: CMTime) -> [CMSampleBuffer] {
        var due: [CMSampleBuffer] = []
        while let sample = nextAudio(), CMSampleBufferGetPresentationTimeStamp(sample) <= position {
            pendingAudio = nil
            due.append(sample)
        }
        return due
    }

    /// The pending video sample, reading one ahead when there is none.
    private func nextVideo() -> CMSampleBuffer? {
        if let pendingVideo { return pendingVideo }
        guard !videoEnded, let video, let sample = video.copyNextSampleBuffer() else {
            videoEnded = true
            return nil
        }
        pendingVideo = sample
        return sample
    }

    /// The pending audio sample, reading one ahead when there is none.
    private func nextAudio() -> CMSampleBuffer? {
        if let pendingAudio { return pendingAudio }
        guard !audioEnded, let audio, let sample = audio.copyNextSampleBuffer() else {
            audioEnded = true
            return nil
        }
        pendingAudio = sample
        audioEnd = CMTimeAdd(
            CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample))
        return sample
    }
}
