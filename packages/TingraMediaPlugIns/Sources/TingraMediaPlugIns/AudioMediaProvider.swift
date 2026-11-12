//
//  AudioMediaProvider.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus
import TingraPlugInKit
import UniformTypeIdentifiers

/// The provider for audio files: every sound format AVFoundation reads
/// (`public.audio` — MP3, AAC in an `.m4a` or bare `.aac`, WAV, AIFF, CAF,
/// FLAC, and the rest of the family).
///
/// The family is claimed whole, the way ``MovieMediaProvider`` claims
/// `public.movie`: a member AVFoundation cannot decode on this Mac (a MIDI
/// file, a format with no system decoder) is then refused at
/// ``Input/start()`` with the reason, rather than by a file panel that
/// greys it out and says nothing. No audio type conforms to `public.movie`
/// and no movie type to `public.audio`, so the two providers never compete
/// for a file.
public struct AudioMediaProvider: MediaInputProvider {
    /// The provider's stable identifier.
    public static let providerID = MediaProviderID(rawValue: "com.moonwink.tingra.media.audio")

    /// The stable identifier.
    public var id: MediaProviderID { Self.providerID }

    /// The user-facing name.
    public let name = "Audio"

    /// Every audio format AVFoundation reads.
    public let contentTypes: [UTType] = [.audio]

    /// The clock that paces playback and stamps audio blocks.
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

    /// Creates an audio file input for the file. Never throws: the file is
    /// opened at ``Input/start()``, where a problem is reported.
    public func makeInput(for url: URL, id: InputID) throws -> any Input {
        AudioFileInput(id: id, url: url, clock: clock, eventBus: eventBus)
    }
}

/// An audio file as an input: read through `AVAssetReader`, its blocks
/// delivered as ``CapturedAudio`` in the mixer's native float32
/// deinterleaved form at the file's own sample rate and channel count (the
/// mixer's intake converts both), their presentation times remapped onto
/// the master clock from the moment playback starts, **looping
/// continuously** while started (ARCHITECTURE.md, "Audio files as media
/// inputs").
///
/// It is the sound half of ``MovieInput`` with no picture: both run the
/// same ``MediaFilePlayback``, so a file's sound reaches the mixer one way
/// whether or not a picture comes with it. The input declares audio alone
/// and never produces a frame — its ``Input/frames()`` is the protocol's
/// finished stream — so it is a channel strip and never a layer.
///
/// Playing a file once, pausing it, and playing a list of files in order
/// are later slices; this input loops from the top each time it starts.
public final class AudioFileInput: Input, Sendable {
    /// How many times a second the blocks that have fallen due are handed
    /// over. The file is read ahead of this cadence only by the one block
    /// held pending, and the mixer queues what arrives, so the rate bounds
    /// how late a block can reach the mixer (one period) rather than
    /// setting a block size.
    static let deliveryRate: Double = 50

    /// The stable identifier — the project's identity for the file.
    public let id: InputID

    /// The user-facing name: the file's name.
    public let name: String

    /// Media is its own input kind (see GLOSSARY.md).
    public let kind = InputKind.media

    /// Sound only: an audio file has no picture to offer a layer.
    public let media: InputMedia = [.audio]

    /// The clock-paced, looping playback this input shares with
    /// ``MovieInput`` (``MediaFilePlayback``).
    private let playback: MediaFilePlayback

    /// Creates an audio file input for the file.
    ///
    /// - Parameters:
    ///   - id: The stable identifier the input reports.
    ///   - url: The audio file.
    ///   - clock: The master clock, pacing playback.
    ///   - eventBus: The host's event bus, or nil for no diagnostics.
    public init(id: InputID, url: URL, clock: any EngineClock, eventBus: EventBus? = nil) {
        self.id = id
        self.name = url.lastPathComponent
        self.playback = MediaFilePlayback(id: id, url: url, content: .sound, clock: clock, eventBus: eventBus)
    }

    /// Opens the file, checks it has sound to play, and starts the clock-
    /// paced playback task from the top of the file. Starting an already
    /// started input does nothing.
    ///
    /// - Throws: ``MediaInputError/fileUnreadable(_:)`` if the file cannot
    ///   be read, ``MediaInputError/noAudioTrack(_:)`` if it holds no sound,
    ///   ``MediaInputError/audioEmpty(_:)`` if its sound has no length, or
    ///   ``MediaInputError/readerRefused(_:reason:)`` if AVFoundation will
    ///   not read it. Reported as a `media.decode` error event before it
    ///   propagates.
    public func start() async throws {
        try await playback.start()
    }

    /// The stream of audio blocks, as the file's timeline reaches them.
    /// Finishes any previous consumer's stream first.
    public func audio() -> AsyncStream<CapturedAudio> {
        playback.audio()
    }

    /// Stops playback and finishes the stream. Safe to call more than once.
    public func stop() async {
        await playback.stop()
    }
}
