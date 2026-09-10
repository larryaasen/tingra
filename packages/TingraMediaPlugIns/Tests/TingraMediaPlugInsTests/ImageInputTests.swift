//
//  ImageInputTests.swift
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

@Suite("ImageInput")
struct ImageInputTests {
    /// The clock every image test stamps deliveries from.
    private let clock = SyntheticClock(tickTimes: [CMTime(value: 7, timescale: 30)])

    @Test("The provider opens every image type and makes a media input named after the file")
    func providerMakesInput() throws {
        let provider = ImageMediaProvider(clock: clock)
        #expect(provider.id == ImageMediaProvider.providerID)
        #expect(provider.contentTypes == [.image])
        #expect(UTType.png.conforms(to: .image))
        let input = try provider.makeInput(for: URL(filePath: "/nonexistent/poster.png"), id: InputID(rawValue: "m1"))
        #expect(input.id == InputID(rawValue: "m1"))
        #expect(input.name == "poster.png")
        #expect(input.kind == .media)
        #expect(input.media == .video)
    }

    @Test("Starting decodes the file into a BT.709-tagged BGRA buffer of the image's size with alpha kept")
    func startDecodesImage() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writePNG(width: 64, height: 48)
        let input = ImageInput(id: InputID(rawValue: "m1"), url: url, clock: clock)
        try await input.start()
        var iterator = input.frames().makeAsyncIterator()
        let frame = try #require(await iterator.next())
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 64)
        #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == 48)
        #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil)
        #expect(MediaFixtures.isTaggedBT709(frame.pixelBuffer))
        #expect(frame.presentationTime == CMTime(value: 7, timescale: 30))
        let left = MediaFixtures.pixel(of: frame.pixelBuffer, x: 8, y: 24)
        #expect(left.r > 200 && left.g < 20 && left.b < 20 && left.a == 255)
        let right = MediaFixtures.pixel(of: frame.pixelBuffer, x: 56, y: 24)
        #expect(right.a == 0)
        await input.stop()
    }

    @Test("A consumer attached before start receives the frame when it decodes, and a second stream finishes the first")
    func consumerBeforeStartAndOneHolderAtATime() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writePNG()
        let input = ImageInput(id: InputID(rawValue: "m1"), url: url, clock: clock)
        let first = input.frames()
        var firstIterator = first.makeAsyncIterator()
        try await input.start()
        #expect(await firstIterator.next() != nil)
        var secondIterator = input.frames().makeAsyncIterator()
        // The first stream finished when the second was made.
        #expect(await firstIterator.next() == nil)
        #expect(await secondIterator.next() != nil)
        await input.stop()
        #expect(await secondIterator.next() == nil)
    }

    @Test("Starting a missing file throws fileUnreadable")
    func missingFileThrows() async throws {
        let url = URL(filePath: "/nonexistent/tingra-media-tests/poster.png")
        let input = ImageInput(id: InputID(rawValue: "m1"), url: url, clock: clock)
        await #expect(throws: MediaInputError.fileUnreadable(url)) {
            try await input.start()
        }
    }

    @Test("Starting a file that is not an image throws imageDecodeRefused")
    func undecodableFileThrows() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeBytes([0, 1, 2, 3, 4, 5, 6, 7], name: "broken.png")
        let input = ImageInput(id: InputID(rawValue: "m1"), url: url, clock: clock)
        await #expect(throws: MediaInputError.imageDecodeRefused(url)) {
            try await input.start()
        }
    }

    @Test("Stopping before any consumer, and stopping twice, is harmless")
    func stopIsIdempotent() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let input = ImageInput(id: InputID(rawValue: "m1"), url: try fixtures.writePNG(), clock: clock)
        await input.stop()
        try await input.start()
        await input.stop()
        await input.stop()
        var iterator = input.frames().makeAsyncIterator()
        // Stopped: the picture was released, so a new stream delivers nothing until started again.
        await input.stop()
        #expect(await iterator.next() == nil)
    }

    @Test("Media input errors describe the file and the fix, and compare equal only when matching")
    func errorDescriptions() {
        let url = URL(filePath: "/tmp/poster.png")
        #expect(MediaInputError.fileUnreadable(url).description.contains("poster.png"))
        #expect(MediaInputError.imageDecodeRefused(url).description.contains("PNG"))
        #expect(MediaInputError.textNotUTF8(url).description.contains("UTF-8"))
        #expect(MediaInputError.noVideoTrack(url).description.contains("video track"))
        #expect(MediaInputError.readerRefused(url, reason: "why").description.contains("why"))
        #expect(MediaInputError.pixelBufferUnavailable(-6662).description.contains("-6662"))
        #expect(!MediaInputError.drawingContextUnavailable.description.isEmpty)
        #expect(MediaInputError.fileUnreadable(url) == .fileUnreadable(url))
        #expect(MediaInputError.fileUnreadable(url) != .imageDecodeRefused(url))
    }
}
