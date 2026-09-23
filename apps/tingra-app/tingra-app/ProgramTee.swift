//
//  ProgramTee.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import TingraPlugInKit

/// A plain, lock-guarded holder for the latest program (or preview) pixel
/// buffer: the writer (the ``EngineModel``'s program drain, off the main
/// actor) and the reader (the `MTKView` coordinator, on it) share one
/// instance, so the monitor samples the program at display rate without
/// pushing 30 fps of state changes through SwiftUI — and without the drain
/// ever waiting for the main thread (ARCHITECTURE.md, "Bounded frame
/// streams").
///
/// Under the frame ownership rule the relay is the one holder; the
/// coordinator only reads it to draw. `CVPixelBuffer` is not `Sendable`, so
/// the buffer travels inside a ``CapturedFrame`` — the codebase's one
/// sanctioned carrier — and the class is `Sendable` by virtue of the lock,
/// the same reasoning as the frame itself.
///
/// The app's own monitors *sample* the relay; a plug-in's monitor cannot —
/// it is in another process — so the relay also **numbers every change**
/// and lets a caller wait for the one after a number it has seen
/// (``next(after:)``): how a frame reaches an app-tier plug-in the moment
/// it exists, with nobody polling (PLUGINS.md, "Frames across the
/// boundary"). With nobody waiting, a stored frame costs one empty
/// dictionary more than it did.
nonisolated final class ProgramFrameRelay: MonitorFrameSource, Sendable {
    /// One numbered state of the relay: what ``next(after:)`` returns.
    struct Update: Sendable {
        /// The change's number; pass it back to wait for the next.
        let sequence: UInt64

        /// The frame held after the change, or nil when the change emptied
        /// the relay.
        let frame: CapturedFrame?
    }

    /// What the lock guards: the held frame, and whether the relay is
    /// taking frames at all.
    private struct State {
        /// The most recent frame, or nil before the first — and, for the
        /// preview relay, again whenever preview is cleared.
        var frame: CapturedFrame?

        /// Whether ``store(_:)`` keeps what it is given. The preview relay
        /// stops accepting while nothing is staged, so a frame the tick
        /// rendered just before preview was cleared cannot repaint the
        /// monitor the clear just emptied.
        var isAccepting = true

        /// How many times ``frame`` has changed — stored, replaced, or
        /// emptied. `0` until the first.
        var sequence: UInt64 = 0

        /// The callers suspended in ``next(after:)``, each woken by the
        /// next change.
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]

        /// Replaces the held frame, numbering the change, and hands back
        /// the waiters to wake — outside the lock.
        mutating func change(to frame: CapturedFrame?) -> [AsyncStream<Void>.Continuation] {
            self.frame = frame
            sequence += 1
            guard !waiters.isEmpty else { return [] }
            defer { waiters = [:] }
            return Array(waiters.values)
        }
    }

    /// The guarded state.
    private let state = Mutex(State())

    /// Creates an empty, accepting relay.
    init() {}

    /// The most recent frame's pixel buffer, or nil before the first frame
    /// — and, for the preview relay, again whenever preview is cleared, so
    /// the monitor empties instead of holding a stale frame. Setting it
    /// wraps the buffer as a frame at time zero: the setter exists for
    /// clearing and for tests, the drain uses ``store(_:)``.
    var latest: CVPixelBuffer? {
        get { state.withLock { $0.frame?.pixelBuffer } }
        set {
            let frame = newValue.map { CapturedFrame(pixelBuffer: $0, presentationTime: .zero) }
            wake(state.withLock { $0.change(to: frame) })
        }
    }

    /// Keeps `frame` as the latest, unless the relay is not accepting.
    ///
    /// - Parameter frame: The frame the bus just yielded.
    func store(_ frame: CapturedFrame) {
        wake(
            state.withLock { state in
                guard state.isAccepting else { return [] }
                return state.change(to: frame)
            })
    }

    /// Turns frame intake on or off; turning it off also empties the relay.
    /// The preview relay stops accepting while nothing is staged.
    ///
    /// - Parameter isAccepting: Whether frames handed to ``store(_:)`` are
    ///   kept.
    func setAccepting(_ isAccepting: Bool) {
        wake(
            state.withLock { state in
                state.isAccepting = isAccepting
                guard !isAccepting, state.frame != nil else { return [] }
                return state.change(to: nil)
            })
    }

    /// The relay's state once it has changed past `sequence`: at once when
    /// it already has, otherwise as soon as the next frame is stored or the
    /// relay is emptied. Whatever changed in between is skipped — the
    /// newest wins, the monitors' rule.
    ///
    /// - Parameter sequence: The last change the caller saw; `0` for none.
    /// - Returns: The update, or nil when the calling task was cancelled
    ///   while waiting.
    func next(after sequence: UInt64) async -> Update? {
        while !Task.isCancelled {
            let waiter = UUID()
            let (signal, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let ready = state.withLock { state -> Update? in
                guard state.sequence <= sequence else { return Update(sequence: state.sequence, frame: state.frame) }
                state.waiters[waiter] = continuation
                return nil
            }
            if let ready { return ready }
            // Ends on the wake-up, or on cancellation.
            for await _ in signal { break }
            state.withLock { $0.waiters[waiter] = nil }
        }
        return nil
    }

    /// Wakes the callers a change found waiting.
    private func wake(_ waiters: [AsyncStream<Void>.Continuation]) {
        for waiter in waiters {
            waiter.yield(())
            waiter.finish()
        }
    }
}

/// The program tee: the one place the program drains hand each composited
/// frame and each mixed block to whatever session is live — the stream
/// session while streaming, the recording session while recording, both
/// at once when both are. Lock-guarded and nonisolated so the drains can
/// run off the main actor while the sessions attach and detach on it
/// (ARCHITECTURE.md, "Bounded frame streams").
///
/// Each leaf is an `AsyncStream` continuation the session consumes. A leaf
/// that is not attached simply receives nothing; detaching finishes the
/// leaf's stream, which is how a session learns the program has stopped
/// feeding it.
nonisolated final class ProgramTee: Sendable {
    /// The attached leaves.
    private struct Leaves {
        /// The stream session's video leaf.
        var streamVideo: AsyncStream<CapturedFrame>.Continuation?

        /// The stream session's audio leaf.
        var streamAudio: AsyncStream<CapturedAudio>.Continuation?

        /// The recording session's video leaf.
        var recordVideo: AsyncStream<CapturedFrame>.Continuation?

        /// The recording session's audio leaf.
        var recordAudio: AsyncStream<CapturedAudio>.Continuation?
    }

    /// The guarded leaves.
    private let leaves = Mutex(Leaves())

    /// Creates a tee with no leaf attached.
    init() {}

    /// Attaches the stream session's leaves, finishing any it replaces.
    ///
    /// - Parameters:
    ///   - video: The continuation feeding the session's program video.
    ///   - audio: The continuation feeding the session's program audio.
    func attachStream(video: AsyncStream<CapturedFrame>.Continuation, audio: AsyncStream<CapturedAudio>.Continuation) {
        let previous = leaves.withLock { leaves in
            let previous = (leaves.streamVideo, leaves.streamAudio)
            leaves.streamVideo = video
            leaves.streamAudio = audio
            return previous
        }
        previous.0?.finish()
        previous.1?.finish()
    }

    /// Detaches the stream session's leaves, finishing their streams.
    func detachStream() {
        let previous = leaves.withLock { leaves in
            let previous = (leaves.streamVideo, leaves.streamAudio)
            leaves.streamVideo = nil
            leaves.streamAudio = nil
            return previous
        }
        previous.0?.finish()
        previous.1?.finish()
    }

    /// Attaches the recording session's leaves, finishing any it replaces.
    ///
    /// - Parameters:
    ///   - video: The continuation feeding the session's program video.
    ///   - audio: The continuation feeding the session's program audio.
    func attachRecording(
        video: AsyncStream<CapturedFrame>.Continuation, audio: AsyncStream<CapturedAudio>.Continuation
    ) {
        let previous = leaves.withLock { leaves in
            let previous = (leaves.recordVideo, leaves.recordAudio)
            leaves.recordVideo = video
            leaves.recordAudio = audio
            return previous
        }
        previous.0?.finish()
        previous.1?.finish()
    }

    /// Detaches the recording session's leaves, finishing their streams.
    func detachRecording() {
        let previous = leaves.withLock { leaves in
            let previous = (leaves.recordVideo, leaves.recordAudio)
            leaves.recordVideo = nil
            leaves.recordAudio = nil
            return previous
        }
        previous.0?.finish()
        previous.1?.finish()
    }

    /// Hands one program frame to every attached video leaf.
    ///
    /// - Parameter frame: The composited frame.
    func yield(_ frame: CapturedFrame) {
        leaves.withLock { leaves in
            _ = leaves.streamVideo?.yield(frame)
            _ = leaves.recordVideo?.yield(frame)
        }
    }

    /// Hands one mixed block to every attached audio leaf.
    ///
    /// - Parameter block: The mixed block.
    func yield(_ block: CapturedAudio) {
        leaves.withLock { leaves in
            _ = leaves.streamAudio?.yield(block)
            _ = leaves.recordAudio?.yield(block)
        }
    }

    /// Whether the stream session's leaves are attached.
    var isStreamAttached: Bool {
        leaves.withLock { $0.streamVideo != nil }
    }

    /// Whether the recording session's leaves are attached.
    var isRecordingAttached: Bool {
        leaves.withLock { $0.recordVideo != nil }
    }
}
