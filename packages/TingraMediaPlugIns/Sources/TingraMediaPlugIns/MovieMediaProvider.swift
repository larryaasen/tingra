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
import Synchronization
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
/// is the next slice; this input is a looping source, the OBS default.
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

    /// The movie file.
    private let url: URL

    /// The clock that paces playback and stamps frames.
    private let clock: any EngineClock

    /// The event bus, for reporting a read problem.
    private let eventBus: EventBus?

    /// The live consumers and the playback task, behind one lock.
    private struct State {
        /// The frame stream's continuation, if a consumer holds it.
        var video: AsyncStream<CapturedFrame>.Continuation?

        /// The audio stream's continuation, if a consumer holds it.
        var audio: AsyncStream<CapturedAudio>.Continuation?

        /// The playback task, while started.
        var playback: Task<Void, Never>?
    }

    /// The state behind its lock, in a reference the playback task can
    /// capture — a `Mutex` itself cannot be copied out of the input.
    private final class Consumers: Sendable {
        /// The state behind its lock.
        let state = Mutex(State())
    }

    /// The live consumers and the playback task.
    private let consumers = Consumers()

    /// Creates a movie input for the file.
    ///
    /// - Parameters:
    ///   - id: The stable identifier the input reports.
    ///   - url: The movie file.
    ///   - clock: The master clock, pacing playback.
    ///   - eventBus: The host's event bus, or nil for no diagnostics.
    public init(id: InputID, url: URL, clock: any EngineClock, eventBus: EventBus? = nil) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.clock = clock
        self.eventBus = eventBus
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
        guard consumers.state.withLock({ $0.playback == nil }) else { return }
        let description: MovieDescription
        do {
            description = try await MovieDescription.load(url)
        } catch {
            eventBus?.error(
                "media.decode",
                domain: MediaPlugIn.domain,
                params: [
                    "id": .string(id.rawValue),
                    "file": .string(url.lastPathComponent),
                    "message": .string(error.description),
                ]
            )
            throw error
        }
        // The task captures the consumers, not the input: a deallocated
        // input's streams are already finished, and the task ends with its
        // clock or its cancellation.
        let consumers = self.consumers
        let task = Task { [url, clock, eventBus, id] in
            await Self.play(url, description, clock: clock, eventBus: eventBus, inputID: id) { frame in
                consumers.state.withLock { _ = $0.video?.yield(frame) }
            } deliverAudio: { audio in
                consumers.state.withLock { _ = $0.audio?.yield(audio) }
            }
        }
        consumers.state.withLock { $0.playback = task }
    }

    /// The stream of frames, one per tick while the file plays. Finishes any
    /// previous consumer's stream first.
    public func frames() -> AsyncStream<CapturedFrame> {
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream()
        consumers.state.withLock { state in
            state.video?.finish()
            state.video = continuation
        }
        return stream
    }

    /// The stream of audio blocks, as the file's timeline reaches them.
    /// Finishes any previous consumer's stream first.
    public func audio() -> AsyncStream<CapturedAudio> {
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        consumers.state.withLock { state in
            state.audio?.finish()
            state.audio = continuation
        }
        return stream
    }

    /// Stops playback and finishes both streams. Safe to call more than
    /// once.
    public func stop() async {
        let task = consumers.state.withLock { state in
            let task = state.playback
            state.playback = nil
            state.video?.finish()
            state.video = nil
            state.audio?.finish()
            state.audio = nil
            return task
        }
        task?.cancel()
        await task?.value
    }

    /// The playback loop: one pass per clock tick, reading every sample
    /// due by the tick's position in the file, delivering the latest video
    /// frame stamped with the tick time and every audio block retimed onto
    /// the master clock, and opening a fresh reader at the file's start
    /// whenever the current one runs out. The wrap happens **within the
    /// tick** that finds the reader exhausted with nothing to show, so a
    /// loop costs no blank tick; a file whose fresh reader is exhausted at
    /// once (no samples at all) ends playback rather than spinning.
    ///
    /// The reader lives entirely inside this task, per the frame ownership
    /// rule; frames leave it only through the delivery closures. A reader
    /// that cannot be opened mid-loop (the file deleted while playing) ends
    /// playback with a `media.decode` error — the layer then holds its last
    /// frame, the disconnected-device semantic.
    private static func play(
        _ url: URL,
        _ description: MovieDescription,
        clock: any EngineClock,
        eventBus: EventBus?,
        inputID: InputID,
        deliverFrame: @Sendable (CapturedFrame) -> Void,
        deliverAudio: @Sendable (CapturedAudio) -> Void
    ) async {
        let tickRate = min(description.frameRate, maximumTickRate)
        let interval = CMTime(value: 1, timescale: CMTimeScale(tickRate.rounded()))
        var reader: MovieReader?
        var startTime: CMTime?
        var loopOffset = CMTime.zero
        ticking: for await tickTime in clock.tick(every: interval) {
            guard !Task.isCancelled else { break }
            let start = startTime ?? tickTime
            startTime = start
            var opened = 0
            while true {
                if reader == nil {
                    do {
                        reader = try await MovieReader(url: url, description: description)
                        opened += 1
                    } catch {
                        eventBus?.error(
                            "media.decode",
                            domain: MediaPlugIn.domain,
                            params: [
                                "id": .string(inputID.rawValue),
                                "file": .string(url.lastPathComponent),
                                "message": .string(error.description),
                            ]
                        )
                        break ticking
                    }
                }
                guard let current = reader else { break ticking }
                let position = CMTimeSubtract(CMTimeSubtract(tickTime, start), loopOffset)
                let base = CMTimeAdd(start, loopOffset)
                for block in current.audio(upTo: position) {
                    if let retimed = CapturedAudio(sampleBuffer: block).rebased(by: CMTimeSubtract(.zero, base)) {
                        deliverAudio(retimed)
                    }
                }
                if let pixelBuffer = current.latestVideoFrame(upTo: position) {
                    MediaPixelBuffer.tagBT709IfUntagged(pixelBuffer)
                    deliverFrame(CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: tickTime))
                    break
                }
                // Nothing due and nothing left: loop, unless the reader just
                // opened — a file with no samples would otherwise spin.
                guard current.isAtEnd, opened < 2 else { break }
                loopOffset = CMTimeAdd(loopOffset, current.duration)
                reader = nil
            }
        }
    }
}

/// What ``MovieInput`` learns about a file at start and hands its playback
/// task: the tracks and the timing.
struct MovieDescription: Sendable {
    /// The file's video track, by identifier — a track object is not
    /// `Sendable`, so each reader resolves its own.
    let videoTrackID: CMPersistentTrackID

    /// The file's first audio track, by identifier, if any.
    let audioTrackID: CMPersistentTrackID?

    /// The file's duration.
    let duration: CMTime

    /// The video track's nominal frame rate, or the fallback.
    let frameRate: Double

    /// Loads the file's tracks and duration.
    ///
    /// - Throws: A ``MediaInputError`` naming the problem.
    static func load(_ url: URL) async throws(MediaInputError) -> MovieDescription {
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

/// One pass through a movie file: an `AVAssetReader` with a video output
/// in the working pixel format and, when the file has sound, an audio
/// output in the mixer's native float32 deinterleaved form, each read one
/// sample ahead so a tick can ask "everything due by now".
///
/// Not `Sendable` by design: it lives inside the playback task, the same
/// rule as the generators' renderers.
final class MovieReader {
    /// The reader.
    private let reader: AVAssetReader

    /// The video output.
    private let video: AVAssetReaderTrackOutput

    /// The audio output, when the file has an audio track.
    private let audio: AVAssetReaderTrackOutput?

    /// The next video sample not yet due, read ahead.
    private var pendingVideo: CMSampleBuffer?

    /// The next audio sample not yet due, read ahead.
    private var pendingAudio: CMSampleBuffer?

    /// Whether the video output has delivered its last sample.
    private var videoEnded = false

    /// Whether the audio output has delivered its last sample (true at once
    /// for a file without sound).
    private var audioEnded: Bool

    /// The file's duration, added to the loop offset when this pass ends.
    let duration: CMTime

    /// Opens a reader at the file's start.
    ///
    /// - Throws: ``MediaInputError/readerRefused(_:reason:)`` if
    ///   AVFoundation will not read the file, or
    ///   ``MediaInputError/noVideoTrack(_:)`` if the video track described
    ///   at start is gone (the file replaced while playing).
    init(url: URL, description: MovieDescription) async throws(MediaInputError) {
        let asset = AVURLAsset(url: url)
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        do {
            reader = try AVAssetReader(asset: asset)
            guard let track = try await asset.loadTrack(withTrackID: description.videoTrackID) else {
                throw MediaInputError.noVideoTrack(url)
            }
            videoTrack = track
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
        video = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
        )
        video.alwaysCopiesSampleData = false
        reader.add(video)
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
        duration = description.duration
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
        guard !videoEnded, let sample = video.copyNextSampleBuffer() else {
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
        return sample
    }
}
