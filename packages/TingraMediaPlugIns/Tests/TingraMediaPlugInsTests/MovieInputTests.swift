//
//  MovieInputTests.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import Testing
import TingraPlugInKit
import UniformTypeIdentifiers

@testable import TingraMediaPlugIns

@Suite("MovieInput")
struct MovieInputTests {
    /// Tick times at the fixture's 12 fps, starting at a non-zero master
    /// time so the remap onto the clock is visible.
    private static func ticks(_ count: Int) -> [CMTime] {
        (0..<count).map { CMTime(value: CMTimeValue(120 + $0), timescale: 12) }
    }

    @Test("The provider opens every movie type and makes a media input declaring picture and sound")
    func providerMakesInput() throws {
        let provider = MovieMediaProvider(clock: SyntheticClock())
        #expect(provider.id == MovieMediaProvider.providerID)
        #expect(provider.contentTypes == [.movie])
        #expect(UTType.quickTimeMovie.conforms(to: .movie))
        #expect(UTType.mpeg4Movie.conforms(to: .movie))
        let input = try provider.makeInput(for: URL(filePath: "/nonexistent/clip.mov"), id: InputID(rawValue: "v1"))
        #expect(input.kind == .media)
        #expect(input.media == [.video, .audio])
        #expect(input.name == "clip.mov")
    }

    @Test("Frames arrive one per tick, stamped with the tick time, advancing through the file and looping at its end")
    func framesFollowTicksAndLoop() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try await fixtures.writeMovie(frameCount: 12, frameRate: 12, withAudio: false)
        let ticks = Self.ticks(18)
        let input = MovieInput(id: InputID(rawValue: "v1"), url: url, clock: SyntheticClock(tickTimes: ticks))
        let frames = input.frames()
        try await input.start()
        var received: [CapturedFrame] = []
        for await frame in frames {
            received.append(frame)
            if received.count == ticks.count { break }
        }
        await input.stop()
        #expect(received.map(\.presentationTime) == ticks)
        let grays = received.map { Int(MediaFixtures.centerGray(of: $0.pixelBuffer)) }
        let expected = (0..<18).map { ($0 % 12) * MediaFixtures.grayStep }
        for (gray, target) in zip(grays, expected) {
            #expect(abs(gray - target) <= 12, "gray \(gray) vs \(target)")
        }
        // Tagged, but with what the track declares: the reader's colorimetry
        // is preserved, and only an untagged buffer is filled in as BT.709.
        #expect(received.allSatisfy { MediaFixtures.hasColorTags($0.pixelBuffer) })
        #expect(received.allSatisfy { CVPixelBufferGetPixelFormatType($0.pixelBuffer) == kCVPixelFormatType_32BGRA })
    }

    @Test(
        "Audio blocks arrive retimed onto the master clock from the start tick, in order, and keep going across the loop"
    )
    func audioIsRetimedAndLoops() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try await fixtures.writeMovie(frameCount: 12, frameRate: 12, withAudio: true)
        let ticks = Self.ticks(16)
        let input = MovieInput(id: InputID(rawValue: "v1"), url: url, clock: SyntheticClock(tickTimes: ticks))
        let frames = input.frames()
        let audio = input.audio()
        try await input.start()
        let framesTask = Task {
            var count = 0
            for await _ in frames {
                count += 1
                if count == ticks.count { break }
            }
        }
        await framesTask.value
        await input.stop()
        var blocks: [CMTime] = []
        for await block in audio {
            blocks.append(block.presentationTime)
        }
        #expect(!blocks.isEmpty)
        #expect(blocks.first == ticks[0])
        #expect(blocks == blocks.sorted(by: <))
        // The second pass through the file lands after the first pass's full second.
        let secondPassStart = CMTimeAdd(ticks[0], CMTime(value: 1, timescale: 1))
        #expect(blocks.contains { $0 >= secondPassStart })
    }

    @Test("Starting twice starts one playback, and stopping finishes both streams")
    func startIsIdempotentAndStopFinishes() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try await fixtures.writeMovie(frameCount: 3, frameRate: 12, withAudio: false)
        let input = MovieInput(
            id: InputID(rawValue: "v1"), url: url, clock: SyntheticClock(tickTimes: Self.ticks(3), staysOpen: true))
        var frames = input.frames().makeAsyncIterator()
        var audio = input.audio().makeAsyncIterator()
        try await input.start()
        try await input.start()
        #expect(await frames.next() != nil)
        await input.stop()
        #expect(await frames.next() == nil)
        #expect(await audio.next() == nil)
        await input.stop()
    }

    @Test("Starting a missing file throws fileUnreadable, and a file that is not a movie throws readerRefused")
    func startErrors() async throws {
        let missing = URL(filePath: "/nonexistent/tingra-media-tests/clip.mov")
        await #expect(throws: MediaInputError.fileUnreadable(missing)) {
            try await MovieInput(id: InputID(rawValue: "v"), url: missing, clock: SyntheticClock()).start()
        }
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let bogus = try fixtures.writeBytes(Array(repeating: 0, count: 64), name: "bogus.mov")
        let input = MovieInput(id: InputID(rawValue: "v"), url: bogus, clock: SyntheticClock())
        await #expect(throws: MediaInputError.self) {
            try await input.start()
        }
    }
}
