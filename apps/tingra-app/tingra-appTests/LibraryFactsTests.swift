//
//  LibraryFactsTests.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import TingraComposition
import TingraEventBus
import UniformTypeIdentifiers

@testable import TingraApp

/// Records which files a ``LibraryFacts`` asked for a length, answering each
/// with a fixed one — so the rule is tested without encoding a movie.
@MainActor
private final class DurationReader {
    /// The files asked about, in order.
    private(set) var asked: [URL] = []

    /// The length every file answers with, or nil to refuse.
    let answer: TimeInterval?

    /// Creates a reader.
    ///
    /// - Parameter answer: The length to answer with, or nil to refuse.
    init(answer: TimeInterval?) {
        self.answer = answer
    }

    /// Reads a length, recording the ask.
    ///
    /// - Parameter url: The file.
    /// - Returns: ``answer``.
    func read(_ url: URL) async -> TimeInterval? {
        asked.append(url)
        return answer
    }
}

@Suite("LibraryFacts")
struct LibraryFactsTests {
    /// Writes a small opaque PNG into a throwaway folder.
    private func writePNG(into folder: URL) throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(context.makeImage())
        let url = folder.appending(path: "poster.png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    /// A movie file row, as the Recordings tab builds one.
    ///
    /// - Parameters:
    ///   - name: The file's name.
    ///   - isRecording: Whether it is the take being written.
    private func movieRow(_ name: String, isRecording: Bool = false) -> LibraryItem {
        let url = URL(filePath: "/tmp/tingra-facts-tests/\(name)")
        return LibraryItem(
            id: .file(url), name: name, url: url, kind: .movie, modifiedAt: nil, byteCount: nil, duration: nil,
            isAvailable: true, isRecording: isRecording)
    }

    @Test("An available image row gets a Quick Look thumbnail, once")
    @MainActor
    func loadsThumbnailForImage() async throws {
        let folder = URL.temporaryDirectory.appending(path: "tingra-thumbnail-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writePNG(into: folder)
        let item = LibraryItem(
            id: .media(MediaID(rawValue: "m")), name: "poster.png", url: url, kind: .image, modifiedAt: nil,
            byteCount: nil,
            duration: nil, isAvailable: true)
        let reader = DurationReader(answer: 12)
        let facts = LibraryFacts(durationOf: reader.read)
        let bus = EventBus()
        await facts.load(item, reporting: bus)
        let image = try #require(facts.images[item.id])
        #expect(image.width > 0 && image.height > 0)
        // An image is never measured.
        #expect(reader.asked.isEmpty)
        #expect(facts.durations.isEmpty)
    }

    @Test("A row that was unavailable when first seen gets its thumbnail once it becomes available")
    @MainActor
    func loadsOnceRowBecomesAvailable() async throws {
        let folder = URL.temporaryDirectory.appending(path: "tingra-thumbnail-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writePNG(into: folder)
        let pending = LibraryItem(
            id: .media(MediaID(rawValue: "m")), name: "poster.png", url: url, kind: .image, modifiedAt: nil,
            byteCount: nil,
            duration: nil, isAvailable: false)
        let facts = LibraryFacts()
        await facts.load(pending, reporting: nil)
        #expect(facts.images.isEmpty)
        let available = LibraryItem(
            id: pending.id, name: pending.name, url: url, kind: .image, modifiedAt: nil, byteCount: nil, duration: nil,
            isAvailable: true)
        await facts.load(available, reporting: nil)
        #expect(facts.images[pending.id] != nil)
    }

    @Test("A missing file's row is never asked for a thumbnail")
    @MainActor
    func skipsUnavailableRow() async {
        let item = LibraryItem(
            id: .media(MediaID(rawValue: "m")), name: "gone.png", url: URL(filePath: "/nonexistent/gone.png"),
            kind: .image,
            modifiedAt: nil, byteCount: nil, duration: nil, isAvailable: false)
        let facts = LibraryFacts()
        await facts.load(item, reporting: nil)
        #expect(facts.images.isEmpty)
    }

    @Test("A finished movie file row is measured once, and its length kept")
    @MainActor
    func measuresMovieOnce() async {
        let reader = DurationReader(answer: 125)
        let facts = LibraryFacts(durationOf: reader.read)
        let take = movieRow("Tingra 2026-09-12 10.00.00.mov")

        await facts.load(take, reporting: nil)
        await facts.load(take, reporting: nil)

        #expect(reader.asked == [take.url])
        #expect(facts.durations[take.id] == 125)
    }

    @Test("The take being written is not asked for anything until its row turns finished")
    @MainActor
    func takeBeingWrittenWaitsForFinalize() async {
        let reader = DurationReader(answer: 30)
        let facts = LibraryFacts(durationOf: reader.read)
        let rolling = movieRow("Tingra 2026-09-12 10.00.00.mov", isRecording: true)

        await facts.load(rolling, reporting: nil)
        #expect(reader.asked.isEmpty)
        #expect(facts.durations.isEmpty)

        let finished = movieRow("Tingra 2026-09-12 10.00.00.mov")
        await facts.load(finished, reporting: nil)
        #expect(reader.asked == [finished.url])
        #expect(facts.durations[finished.id] == 30)
    }

    @Test("A media movie that carries its own length is not measured again")
    @MainActor
    func carriedLengthIsNotReRead() async {
        let reader = DurationReader(answer: 99)
        let facts = LibraryFacts(durationOf: reader.read)
        let clip = LibraryItem(
            id: .media(MediaID(rawValue: "m")), name: "clip.mov",
            url: URL(filePath: "/tmp/tingra-facts-tests/clip.mov"),
            kind: .movie, modifiedAt: nil, byteCount: nil, duration: 42, isAvailable: true)

        await facts.load(clip, reporting: nil)

        #expect(reader.asked.isEmpty)
        #expect(facts.durations.isEmpty)
    }

    @Test("A movie whose length cannot be read keeps no length and says so in a trace")
    @MainActor
    func unreadableLengthTraces() async throws {
        let reader = DurationReader(answer: nil)
        let facts = LibraryFacts(durationOf: reader.read)
        let take = movieRow("Broken.mov")
        let bus = EventBus()
        let stream = bus.events()

        await facts.load(take, reporting: bus)
        bus.shutdown()
        var events: [EventBusEvent] = []
        for await event in stream { events.append(event) }

        #expect(facts.durations.isEmpty)
        let trace = try #require(events.first { $0.name == "library.duration" })
        #expect(trace.group == .trace)
        #expect(trace.params?["id"] == .string("Broken.mov"))
    }

    @Test("A real file AVFoundation cannot open has no length")
    @MainActor
    func assetDurationOfNonMovie() async throws {
        let folder = URL.temporaryDirectory.appending(path: "tingra-duration-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appending(path: "not-a-movie.mov")
        try Data("not a movie".utf8).write(to: fake)

        #expect(await LibraryFacts.assetDuration(of: fake) == nil)
    }
}
