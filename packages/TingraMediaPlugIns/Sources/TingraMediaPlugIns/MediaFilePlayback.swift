//
//  MediaFilePlayback.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-11-11.
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

/// What a file AVFoundation reads is played for — the one difference
/// between ``MovieInput`` and ``AudioFileInput``, which share everything
/// else through ``MediaFilePlayback``.
enum MediaFileContent: Sendable {
    /// A video file: the picture is required, the sound comes along when
    /// the file has any.
    case movie

    /// An audio file: the sound is required and is all that is played.
    case sound

    /// The name of the thread a playback of this content reads on, so a
    /// process sample says which kind of file each reader thread serves.
    var threadName: String {
        switch self {
        case .movie: "com.moonwink.tingra.media.movie"
        case .sound: "com.moonwink.tingra.media.audio"
        }
    }
}

/// The playback both file inputs run: an `AVAssetReader` pass paced by the
/// master clock, its presentation times remapped onto the clock from the
/// moment playback starts, **looping continuously** while started
/// (ARCHITECTURE.md, "Media inputs and the Library's Media tab" and "Audio
/// files as media inputs"). It was ``MovieInput``'s own body until audio
/// files became inputs; one implementation serves both so a file's sound
/// reaches the mixer the same way whether or not a picture comes with it.
///
/// Holds the consumers' stream continuations and the playback task; the
/// public input types are thin shells that declare what they produce and
/// delegate here.
final class MediaFilePlayback: Sendable {
    /// The identifier of the input this playback serves, for its events.
    private let id: InputID

    /// The file.
    private let url: URL

    /// What the file is played for.
    private let content: MediaFileContent

    /// The clock that paces playback and stamps frames and audio blocks.
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
    /// capture — a `Mutex` itself cannot be copied out of the playback.
    private final class Consumers: Sendable {
        /// The state behind its lock.
        let state = Mutex(State())
    }

    /// The live consumers and the playback task.
    private let consumers = Consumers()

    /// Creates a playback for the file.
    ///
    /// - Parameters:
    ///   - id: The identifier of the input this playback serves.
    ///   - url: The file.
    ///   - content: What the file is played for.
    ///   - clock: The master clock, pacing playback.
    ///   - eventBus: The host's event bus, or nil for no diagnostics.
    init(id: InputID, url: URL, content: MediaFileContent, clock: any EngineClock, eventBus: EventBus?) {
        self.id = id
        self.url = url
        self.content = content
        self.clock = clock
        self.eventBus = eventBus
    }

    /// Opens the file, checks it holds the track its content requires, and
    /// starts the clock-paced playback task. Starting an already started
    /// playback does nothing.
    ///
    /// - Throws: A ``MediaInputError`` naming the problem
    ///   (``MovieDescription/load(_:content:)``), reported as a
    ///   `media.decode` error event before it propagates.
    func start() async throws {
        guard consumers.state.withLock({ $0.playback == nil }) else { return }
        let description: MovieDescription
        do {
            description = try await MovieDescription.load(url, content: content)
        } catch {
            Self.reportDecodeError(error, url: url, inputID: id, on: eventBus)
            throw error
        }
        // The task captures the consumers, not the playback: a deallocated
        // input's streams are already finished, and the task ends with its
        // clock or its cancellation.
        let consumers = self.consumers
        // The reader's sample reads block (`DedicatedThreadExecutor`), so the
        // task runs on a thread of its own rather than the cooperative pool;
        // the thread exits when playback ends.
        let executor = DedicatedThreadExecutor(name: content.threadName)
        let task = Task(executorPreference: executor) { [url, clock, eventBus, id] in
            defer { executor.shutDown() }
            await Self.play(url, description, clock: clock, eventBus: eventBus, inputID: id) {
                consumers.state.withLock { $0.audio != nil }
            } deliverFrame: { frame in
                consumers.state.withLock { _ = $0.video?.yield(frame) }
            } deliverAudio: { audio in
                consumers.state.withLock { _ = $0.audio?.yield(audio) }
            }
        }
        consumers.state.withLock { $0.playback = task }
    }

    /// The stream of frames, one per tick while a file with a picture
    /// plays. Finishes any previous consumer's stream first.
    func frames() -> AsyncStream<CapturedFrame> {
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream()
        consumers.state.withLock { state in
            state.video?.finish()
            state.video = continuation
        }
        return stream
    }

    /// The stream of audio blocks, as the file's timeline reaches them.
    /// Finishes any previous consumer's stream first.
    func audio() -> AsyncStream<CapturedAudio> {
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        consumers.state.withLock { state in
            state.audio?.finish()
            state.audio = continuation
        }
        return stream
    }

    /// Stops playback and finishes both streams. Safe to call more than
    /// once.
    func stop() async {
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

    /// Reports a read problem as a `media.decode` error in the plug-in's
    /// domain, naming the input and the file — never the file's folder.
    ///
    /// - Parameters:
    ///   - error: The problem.
    ///   - url: The file.
    ///   - inputID: The input playing it.
    ///   - eventBus: The bus to report on, or nil for no diagnostics.
    private static func reportDecodeError(_ error: MediaInputError, url: URL, inputID: InputID, on eventBus: EventBus?)
    {
        eventBus?.error(
            "media.decode",
            domain: MediaPlugIn.domain,
            params: [
                "id": .string(inputID.rawValue),
                "file": .string(url.lastPathComponent),
                "message": .string(error.description),
            ]
        )
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
    /// A file played for its sound has no frame to deliver, so its tick is
    /// done once the audio due has gone out, and it wraps on the tick that
    /// delivers its last block: the next pass's first block then falls due
    /// exactly where the last one ended (``MovieReader/duration``). It wraps
    /// as many times as one tick spans — a file shorter than the tick
    /// interval, or ticks the clock skipped — because each pass that read
    /// sound moves the loop offset forward by a positive length; only a pass
    /// that read **no** sound at all (the file replaced by an empty one
    /// while playing) ends playback.
    ///
    /// A file played for its sound also **waits for its listener**: its
    /// timeline starts on the first tick that finds an audio consumer
    /// attached, not on the first tick after ``start()``. The app starts its
    /// inputs concurrently and subscribes the mixer only once all of them
    /// are running, so a slow neighbor (a camera opening) would otherwise
    /// let the file run on unheard and come in partway through. A movie does
    /// not wait: its picture is on the clock from the moment it is staged.
    ///
    /// - Parameter hasAudioConsumer: Whether a consumer holds the audio
    ///   stream right now.
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
        hasAudioConsumer: @Sendable () -> Bool,
        deliverFrame: @Sendable (CapturedFrame) -> Void,
        deliverAudio: @Sendable (CapturedAudio) -> Void
    ) async {
        let tickRate = min(description.frameRate, MovieInput.maximumTickRate)
        let interval = CMTime(value: 1, timescale: CMTimeScale(tickRate.rounded()))
        var reader: MovieReader?
        var startTime: CMTime?
        var loopOffset = CMTime.zero
        ticking: for await tickTime in clock.tick(every: interval) {
            guard !Task.isCancelled else { break }
            // Sound alone starts when someone is listening (see above).
            if startTime == nil, description.videoTrackID == nil, !hasAudioConsumer() { continue }
            let start = startTime ?? tickTime
            startTime = start
            var opened = 0
            while true {
                if reader == nil {
                    do {
                        reader = try await MovieReader(url: url, description: description)
                        opened += 1
                    } catch {
                        reportDecodeError(error, url: url, inputID: inputID, on: eventBus)
                        break ticking
                    }
                }
                guard let current = reader else { break ticking }
                // One autorelease pool per pull: the reader's sample buffers
                // come out of AVFoundation, and a loop that has fallen
                // behind always finds its next tick already waiting, so it
                // never suspends and nothing else drains the thread's pool —
                // every decoded frame's `IOSurface` would stay alive (the
                // compositor's tick loop leaked exactly this way).
                let tickIsDone = autoreleasepool { () -> Bool in
                    let position = CMTimeSubtract(CMTimeSubtract(tickTime, start), loopOffset)
                    let base = CMTimeAdd(start, loopOffset)
                    for block in current.audio(upTo: position) {
                        if let retimed = CapturedAudio(sampleBuffer: block).rebased(by: CMTimeSubtract(.zero, base)) {
                            deliverAudio(retimed)
                        }
                    }
                    // Sound alone: nothing to show, so the tick is done
                    // unless this pass just ran out and the next must open.
                    guard current.hasVideo else { return !current.isAtEnd }
                    guard let pixelBuffer = current.latestVideoFrame(upTo: position) else { return false }
                    MediaPixelBuffer.tagBT709IfUntagged(pixelBuffer)
                    deliverFrame(CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: tickTime))
                    return true
                }
                if tickIsDone { break }
                // Nothing due and nothing left: loop, unless the reader just
                // opened — a file with no samples would otherwise spin.
                guard current.isAtEnd else { break }
                if current.hasVideo {
                    guard opened < 2 else { break }
                } else if !current.hasReadAudio {
                    // An audio file whose pass held no samples (the file
                    // replaced by an empty one while playing) has nothing
                    // left to offer at all: say so once and end. A pass that
                    // did read sound always wraps, however many passes one
                    // tick spans — its length is positive, so the wraps end
                    // once the loop offset catches up with the tick.
                    reportDecodeError(.audioEmpty(url), url: url, inputID: inputID, on: eventBus)
                    break ticking
                }
                loopOffset = CMTimeAdd(loopOffset, current.duration)
                reader = nil
            }
        }
    }
}
