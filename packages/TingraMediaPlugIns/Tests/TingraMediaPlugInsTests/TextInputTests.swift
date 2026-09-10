//
//  TextInputTests.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreText
import CoreVideo
import Foundation
import Testing
import TingraPlugInKit
import UniformTypeIdentifiers

@testable import TingraMediaPlugIns

@Suite("TextInput")
struct TextInputTests {
    /// The clock every text test stamps deliveries from.
    private let clock = SyntheticClock(tickTimes: [.zero])

    @Test("The provider opens plain text and Markdown, rendering Markdown only for a Markdown file")
    func providerMakesInput() throws {
        let provider = TextMediaProvider(clock: clock)
        #expect(provider.id == TextMediaProvider.providerID)
        #expect(provider.contentTypes == [.plainText])
        #expect(TextMediaProvider.markdown.conforms(to: .plainText))
        let plain = try provider.makeInput(for: URL(filePath: "/nonexistent/notes.txt"), id: InputID(rawValue: "t1"))
        #expect(plain.kind == .media)
        #expect(plain.media == .video)
        #expect(plain.name == "notes.txt")
        #expect(
            try provider.makeInput(for: URL(filePath: "/nonexistent/notes.md"), id: InputID(rawValue: "t2")).name
                == "notes.md")
    }

    @Test("Starting renders the text onto a transparent 1920x1080 BT.709-tagged canvas with type at the top left")
    func startRendersCanvas() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.writeText("Hello, program.")
        let input = TextInput(id: InputID(rawValue: "t1"), url: url, isMarkdown: false, clock: clock)
        try await input.start()
        var iterator = input.frames().makeAsyncIterator()
        let frame = try #require(await iterator.next())
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 1920)
        #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == 1080)
        #expect(MediaFixtures.isTaggedBT709(frame.pixelBuffer))
        // Some pixel in the first line's box is painted white; the far corner is untouched.
        var painted = false
        for y in stride(from: 80, to: 140, by: 4) {
            for x in stride(from: 80, to: 400, by: 4)
            where MediaFixtures.pixel(of: frame.pixelBuffer, x: x, y: y).a > 128 {
                painted = true
            }
        }
        #expect(painted)
        #expect(MediaFixtures.pixel(of: frame.pixelBuffer, x: 1900, y: 1060).a == 0)
        await input.stop()
    }

    @Test("Markdown headings render bold and larger than the body, and paragraphs are separated again")
    func markdownStyling() {
        let styled = TextInput.styled("# Title\n\nBody text with **bold**.\n\n- item", asMarkdown: true)
        let text = styled.string
        #expect(text.hasPrefix("Title\n"))
        #expect(text.contains("Body text with bold."))
        #expect(text.contains("•  item"))
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let titleFont = try? #require(styled.attribute(fontKey, at: 0, effectiveRange: nil) as! CTFont?)
        let bodyFont = try? #require(styled.attribute(fontKey, at: 8, effectiveRange: nil) as! CTFont?)
        let titleSize = titleFont.map(CTFontGetSize) ?? 0
        let bodySize = bodyFont.map(CTFontGetSize) ?? 0
        #expect(titleSize == TextInput.bodySize * 2)
        #expect(bodySize == TextInput.bodySize)
        #expect(titleFont.map { CTFontGetSymbolicTraits($0).contains(.boldTrait) } == true)
        #expect(bodyFont.map { CTFontGetSymbolicTraits($0).contains(.boldTrait) } == false)
    }

    @Test("Plain text renders verbatim in the body style, newlines included")
    func plainTextVerbatim() {
        let styled = TextInput.styled("# not a heading\nsecond line", asMarkdown: false)
        #expect(styled.string == "# not a heading\nsecond line")
    }

    @Test("Heading sizes step down from twice the body size to the body size")
    func headerSizes() {
        #expect(TextInput.headerSize(level: 1) == TextInput.bodySize * 2)
        #expect(TextInput.headerSize(level: 2) < TextInput.headerSize(level: 1))
        #expect(TextInput.headerSize(level: 4) < TextInput.headerSize(level: 3))
        #expect(TextInput.headerSize(level: 5) == TextInput.bodySize)
        #expect(TextInput.headerSize(level: 9) == TextInput.bodySize)
    }

    @Test("Starting a missing file throws fileUnreadable and a non-UTF-8 file throws textNotUTF8")
    func readErrors() async throws {
        let missing = URL(filePath: "/nonexistent/tingra-media-tests/notes.txt")
        await #expect(throws: MediaInputError.fileUnreadable(missing)) {
            try await TextInput(id: InputID(rawValue: "t"), url: missing, isMarkdown: false, clock: clock).start()
        }
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let bad = try fixtures.writeBytes([0xFF, 0xFE, 0xC3, 0x28], name: "bad.txt")
        await #expect(throws: MediaInputError.textNotUTF8(bad)) {
            try await TextInput(id: InputID(rawValue: "t"), url: bad, isMarkdown: false, clock: clock).start()
        }
    }
}
