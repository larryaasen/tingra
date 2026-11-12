//
//  AudioFileInputTests.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio
import CoreMedia
import Foundation
import Testing
import TingraEventBus
import TingraPlugInKit
import UniformTypeIdentifiers

@testable import TingraMediaPlugIns

// A hung test fails by name after a minute instead of holding a CI runner
// until the job times out with nothing in its log; the suite runs in
// well under a second.
@Suite("AudioFileInput", .timeLimit(.minutes(1)))
struct AudioFileInputTests {
    /// The master time of the first tick: non-zero, so the remap onto the
    /// clock is visible.
    private static let startTime = CMTime(value: 100, timescale: 10)

    /// Tick times a tenth of a second apart, starting at ``startTime``.
    private static func ticks(_ count: Int) -> [CMTime] {
        (0..<count).map { CMTime(value: CMTimeValue(100 + $0), timescale: 10) }
    }

    /// What a test keeps of one delivered block.
    private struct Block {
        /// The block's presentation time on the master clock.
        let time: CMTime

        /// How long the block runs.
        let duration: CMTime

        /// How many sample frames it holds.
        let frames: Int

        /// The block's stream format.
        let format: AudioStreamBasicDescription

        /// Where the block ends on the master clock.
        var end: CMTime { CMTimeAdd(time, duration) }

        /// Reads the facts off a delivered block.
        init(_ audio: CapturedAudio) throws {
            let buffer = audio.sampleBuffer
            time = audio.presentationTime
            frames = CMSampleBufferGetNumSamples(buffer)
            let description = try #require(CMSampleBufferGetFormatDescription(buffer))
            format = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
            // From the frame count and the rate — what the mixer's intake
            // reads — rather than the retimed buffer's own duration field.
            duration = CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(format.mSampleRate))
        }
    }

    /// Starts an input over the file, collects its blocks until one begins
    /// at or after `seconds` past the first tick, then stops it.
    ///
    /// - Parameters:
    ///   - url: The audio file.
    ///   - seconds: How far past the start to collect.
    ///   - tickCount: How many tenth-of-a-second ticks the clock scripts;
    ///     it must reach past `seconds`.
    /// - Returns: The blocks, in delivery order.
    private func play(_ url: URL, past seconds: Double, tickCount: Int) async throws -> [Block] {
        let input = AudioFileInput(
            id: InputID(rawValue: "a1"), url: url, clock: SyntheticClock(tickTimes: Self.ticks(tickCount)))
        let audio = input.audio()
        try await input.start()
        let target = CMTimeAdd(Self.startTime, CMTime(seconds: seconds, preferredTimescale: 44100))
        var blocks: [Block] = []
        for await captured in audio {
            let block = try Block(captured)
            blocks.append(block)
            if block.time >= target { break }
        }
        await input.stop()
        return blocks
    }

    @Test("The provider claims the audio family and nothing a movie is, and makes a media input declaring sound only")
    func providerClaimsAudio() throws {
        let provider = AudioMediaProvider(clock: SyntheticClock())
        #expect(provider.id == AudioMediaProvider.providerID)
        #expect(provider.name == "Audio")
        #expect(provider.contentTypes == [.audio])
        let extensions = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]
        for ext in extensions {
            let type = try #require(UTType(filenameExtension: ext), "no type for .\(ext)")
            #expect(type.conforms(to: .audio), ".\(ext) is audio")
            // The movie provider must not take an audio file first.
            #expect(!type.conforms(to: .movie), ".\(ext) is not a movie")
        }
        // And the audio provider takes no movie.
        #expect(!UTType.quickTimeMovie.conforms(to: .audio))
        #expect(!UTType.mpeg4Movie.conforms(to: .audio))
        let input = try provider.makeInput(for: URL(filePath: "/nonexistent/song.mp3"), id: InputID(rawValue: "a1"))
        #expect(input.kind == .media)
        #expect(input.media == [.audio])
        #expect(!input.media.contains(.video))
        #expect(input.name == "song.mp3")
        #expect(input is AudioFileInput)
    }

    @Test("Blocks arrive as float32 deinterleaved PCM at the file's own rate and channel count")
    func blocksAreNormalizedToTheMixersForm() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        // A 16-bit integer interleaved file: nothing like what is delivered.
        let url = try fixtures.writeAudio(.wav, seconds: 1, sampleRate: 44100, channels: 2)
        let blocks = try await play(url, past: 0.5, tickCount: 20)
        #expect(!blocks.isEmpty)
        for block in blocks {
            #expect(block.format.mFormatID == kAudioFormatLinearPCM)
            #expect(block.format.mFormatFlags & kAudioFormatFlagIsFloat != 0)
            #expect(block.format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
            #expect(block.format.mBitsPerChannel == 32)
            #expect(block.format.mSampleRate == 44100)
            #expect(block.format.mChannelsPerFrame == 2)
            #expect(block.frames > 0)
        }
    }

    @Test("A mono file at another rate keeps its rate and channel count for the mixer to convert")
    func monoFileKeepsItsShape() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeAudio(.wav, seconds: 1, sampleRate: 22050, channels: 1)
        let blocks = try await play(url, past: 0.5, tickCount: 20)
        let first = try #require(blocks.first)
        #expect(first.format.mSampleRate == 22050)
        #expect(first.format.mChannelsPerFrame == 1)
        #expect(first.format.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    @Test("Timestamps start at the first tick's master time and run on in order, each block where the last ended")
    func timestampsFollowTheMasterClock() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeAudio(.wav, seconds: 1)
        let blocks = try await play(url, past: 0.8, tickCount: 20)
        let first = try #require(blocks.first)
        // The file's zero lands on the tick that started playback — never
        // on the file's own timeline, and never on a sample count from zero.
        #expect(first.time == Self.startTime)
        for (earlier, later) in zip(blocks, blocks.dropFirst()) {
            #expect(later.time > earlier.time)
            #expect(abs(later.time.seconds - earlier.end.seconds) < 0.0001)
        }
    }

    @Test("A block is delivered only once the clock has reached it")
    func blocksAreNeverDeliveredAheadOfTheClock() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeAudio(.wav, seconds: 1)
        // Three ticks reach 0.2 s into a one-second file, and the clock
        // then stays open with nothing more to say.
        let ticks = Self.ticks(3)
        let input = AudioFileInput(
            id: InputID(rawValue: "a1"), url: url, clock: SyntheticClock(tickTimes: ticks, staysOpen: true))
        var audio = input.audio().makeAsyncIterator()
        try await input.start()
        let first = try Block(try #require(await audio.next()))
        #expect(first.time == Self.startTime)
        await input.stop()
        var times = [first.time]
        while let next = await audio.next() {
            times.append(next.presentationTime)
        }
        let lastTick = try #require(ticks.last)
        #expect(times.allSatisfy { $0 <= lastTick })
    }

    @Test("Playback loops: the file's first sample follows its last with no gap, and every pass holds the whole file")
    func playbackLoopsAcrossTheEnd() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeAudio(.wav, seconds: 1, sampleRate: 44100)
        // Into the third pass of a one-second file.
        let blocks = try await play(url, past: 2.2, tickCount: 40)
        let second = CMTime(value: 1, timescale: 1)
        let passStarts = [
            Self.startTime, CMTimeAdd(Self.startTime, second), CMTimeAdd(Self.startTime, second + second),
        ]
        // Each pass begins exactly one file length after the one before.
        for start in passStarts {
            #expect(blocks.contains { abs($0.time.seconds - start.seconds) < 0.0001 }, "a block at \(start.seconds)")
        }
        // The first two passes are complete: 44,100 frames each, to the sample.
        let firstPass = blocks.filter { $0.time < passStarts[1] }
        let secondPass = blocks.filter { $0.time >= passStarts[1] && $0.time < passStarts[2] }
        #expect(firstPass.reduce(0) { $0 + $1.frames } == 44100)
        #expect(secondPass.reduce(0) { $0 + $1.frames } == 44100)
        // And the timeline never steps back or leaves a hole at a wrap.
        for (earlier, later) in zip(blocks, blocks.dropFirst()) {
            #expect(abs(later.time.seconds - earlier.end.seconds) < 0.0001)
        }
    }

    @Test("A compressed file plays and loops on where its decoded sound ended, so timestamps stay in order")
    func compressedFileLoops() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeAudio(.m4a, seconds: 1, sampleRate: 44100)
        let blocks = try await play(url, past: 2.5, tickCount: 50)
        #expect(blocks.count > 2)
        let first = try #require(blocks.first)
        #expect(first.format.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        #expect(first.format.mSampleRate == 44100)
        // An AAC file's first block need not sit at the file's zero (the
        // codec's priming), but it is within a block of the start tick.
        #expect(abs(first.time.seconds - Self.startTime.seconds) < 0.1)
        for (earlier, later) in zip(blocks, blocks.dropFirst()) {
            #expect(later.time > earlier.time)
            // No overlap at a wrap: a pass begins no earlier than the last ended.
            #expect(later.time.seconds - earlier.end.seconds > -0.0001)
        }
    }

    @Test("An audio file input produces no frames: its frame stream is already finished")
    func producesNoFrames() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeAudio(.wav, seconds: 1)
        let input = AudioFileInput(
            id: InputID(rawValue: "a1"), url: url, clock: SyntheticClock(tickTimes: Self.ticks(5), staysOpen: true))
        try await input.start()
        var frames = input.frames().makeAsyncIterator()
        #expect(await frames.next() == nil)
        await input.stop()
    }

    @Test("Starting twice starts one playback, and stopping cancels it and finishes the stream")
    func startIsIdempotentAndStopFinishes() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeAudio(.wav, seconds: 1)
        // A clock that never finishes: only the cancellation ends playback.
        let input = AudioFileInput(
            id: InputID(rawValue: "a1"), url: url, clock: SyntheticClock(tickTimes: Self.ticks(3), staysOpen: true))
        var audio = input.audio().makeAsyncIterator()
        try await input.start()
        try await input.start()
        #expect(await audio.next() != nil)
        // Returns only once the playback task has ended.
        await input.stop()
        var times: [CMTime] = [Self.startTime]
        while let block = await audio.next() {
            times.append(block.presentationTime)
        }
        // One playback: a second would have delivered the file's start twice.
        #expect(times.filter { $0 == Self.startTime }.count == 1)
        await input.stop()
    }

    @Test("A stopped input starts again from the top of the file")
    func restartsFromTheTop() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeAudio(.wav, seconds: 1)
        let input = AudioFileInput(
            id: InputID(rawValue: "a1"), url: url, clock: SyntheticClock(tickTimes: Self.ticks(4), staysOpen: true))
        for _ in 0..<2 {
            var audio = input.audio().makeAsyncIterator()
            try await input.start()
            let first = try #require(await audio.next())
            #expect(first.presentationTime == Self.startTime)
            await input.stop()
        }
    }

    @Test("A new audio consumer finishes the previous consumer's stream")
    func newConsumerFinishesThePrevious() async throws {
        let input = AudioFileInput(
            id: InputID(rawValue: "a1"), url: URL(filePath: "/nonexistent/song.wav"), clock: SyntheticClock())
        var first = input.audio().makeAsyncIterator()
        _ = input.audio()
        #expect(await first.next() == nil)
    }

    @Test("Starting a missing file throws fileUnreadable and reports a media.decode error naming the file")
    func missingFileThrowsAndReports() async throws {
        let missing = URL(filePath: "/nonexistent/tingra-media-tests/song.mp3")
        let bus = EventBus()
        var events = bus.events().makeAsyncIterator()
        let input = AudioFileInput(id: InputID(rawValue: "a1"), url: missing, clock: SyntheticClock(), eventBus: bus)
        await #expect(throws: MediaInputError.fileUnreadable(missing)) {
            try await input.start()
        }
        let event = try #require(await events.next())
        #expect(event.group == .error)
        #expect(event.name == "media.decode")
        #expect(event.domain == MediaPlugIn.domain)
        #expect(event.params?["id"] == .string("a1"))
        #expect(event.params?["file"] == .string("song.mp3"))
        // The file's folder is not the bus's business.
        #expect(event.params?.values.contains { "\($0)".contains("tingra-media-tests") } == false)
    }

    @Test("A zero-length file and a file of bytes that are not sound each throw a media input error at start")
    func unreadableFilesThrow() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let zeroLength = try fixtures.writeBytes([], name: "empty.mp3")
        await #expect(throws: MediaInputError.self) {
            try await AudioFileInput(id: InputID(rawValue: "a"), url: zeroLength, clock: SyntheticClock()).start()
        }
        let bogus = try fixtures.writeBytes(Array(repeating: 0x5A, count: 256), name: "bogus.wav")
        await #expect(throws: MediaInputError.self) {
            try await AudioFileInput(id: InputID(rawValue: "a"), url: bogus, clock: SyntheticClock()).start()
        }
    }

    @Test("A file with a header and no samples throws rather than starting a playback with nothing to play")
    func headerOnlyFileThrows() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeAudio(.wav, seconds: 0, name: "silent.wav")
        let input = AudioFileInput(id: InputID(rawValue: "a"), url: url, clock: SyntheticClock())
        await #expect(throws: MediaInputError.self) {
            try await input.start()
        }
        // Nothing started: a later stop has no task to wait for, and the
        // stream it finishes delivered nothing.
        var audio = input.audio().makeAsyncIterator()
        await input.stop()
        #expect(await audio.next() == nil)
    }

    @Test("A movie file with picture and no sound, offered as audio, throws noAudioTrack")
    func fileWithoutSoundThrows() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try await fixtures.writeMovie(frameCount: 3, frameRate: 12, withAudio: false, name: "picture.mov")
        await #expect(throws: MediaInputError.noAudioTrack(url)) {
            try await AudioFileInput(id: InputID(rawValue: "a"), url: url, clock: SyntheticClock()).start()
        }
    }

    @Test("The sound of a file that also holds a picture plays, and the picture is left alone")
    func soundOfAFileWithPicturePlays() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try await fixtures.writeMovie(frameCount: 12, frameRate: 12, withAudio: true, name: "both.mov")
        let blocks = try await play(url, past: 0.5, tickCount: 20)
        #expect(blocks.first?.time == Self.startTime)
        #expect(blocks.first?.format.mSampleRate == 48000)
    }

    @Test("The audio errors say what is wrong and how to fix it, and compare by case and file")
    func errorDescriptions() {
        let url = URL(filePath: "/tmp/song.m4a")
        let other = URL(filePath: "/tmp/other.m4a")
        #expect(MediaInputError.noAudioTrack(url).description.contains("song.m4a"))
        #expect(MediaInputError.noAudioTrack(url).description.contains("no sound"))
        #expect(MediaInputError.audioEmpty(url).description.contains("song.m4a"))
        #expect(MediaInputError.audioEmpty(url).description.contains("empty"))
        #expect(MediaInputError.readerRefused(url, reason: "why").description.contains("audio file"))
        #expect(MediaInputError.noAudioTrack(url) == .noAudioTrack(url))
        #expect(MediaInputError.noAudioTrack(url) != .noAudioTrack(other))
        #expect(MediaInputError.noAudioTrack(url) != .audioEmpty(url))
        #expect(MediaInputError.audioEmpty(url) == .audioEmpty(url))
        #expect(MediaInputError.audioEmpty(url) != .audioEmpty(other))
    }
}
