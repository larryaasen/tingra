//
//  TextMediaProvider.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import TingraEventBus
import TingraPlugInKit
import UniformTypeIdentifiers

/// The provider for text and Markdown documents (`public.plain-text`, to
/// which Markdown conforms).
public struct TextMediaProvider: MediaInputProvider {
    /// The provider's stable identifier.
    public static let providerID = MediaProviderID(rawValue: "com.moonwink.tingra.media.text")

    /// Markdown's uniform type, `net.daringfireball.markdown` — declared by
    /// the system, but with no static member in the framework.
    public static let markdown = UTType("net.daringfireball.markdown") ?? .plainText

    /// The stable identifier.
    public var id: MediaProviderID { Self.providerID }

    /// The user-facing name.
    public let name = "Text"

    /// Plain text and everything conforming to it, Markdown included.
    public let contentTypes: [UTType] = [.plainText]

    /// The clock that stamps the canvas's delivery.
    private let clock: any EngineClock

    /// The event bus, for reporting a decode problem.
    private let eventBus: EventBus?

    /// Creates the provider.
    ///
    /// - Parameters:
    ///   - clock: The master clock, stamping deliveries.
    ///   - eventBus: The host's event bus, for decode diagnostics. Omit it
    ///     where those are not wanted (tests).
    public init(clock: any EngineClock, eventBus: EventBus? = nil) {
        self.clock = clock
        self.eventBus = eventBus
    }

    /// Creates a text input for the file, rendering as Markdown when the
    /// file's type says so. Never throws: the file is read at
    /// ``Input/start()``, where a problem is reported.
    public func makeInput(for url: URL, id: InputID) throws -> any Input {
        let type = UTType(filenameExtension: url.pathExtension) ?? .plainText
        return TextInput(
            id: id, url: url, isMarkdown: type.conforms(to: Self.markdown), clock: clock, eventBus: eventBus)
    }
}

/// A text or Markdown document as an input: rendered once at start onto a
/// transparent 1920×1080 canvas — white system type, so it composites as an
/// overlay and scales with its layer — delivered once per consumer and held
/// (ARCHITECTURE.md, "Media inputs and the Library's Media tab").
/// Typography is fixed in this iteration; controls are a later parameter
/// set.
public final class TextInput: Input, Sendable {
    /// The canvas size the text is laid out on.
    public static let canvasSize = (width: 1920, height: 1080)

    /// The margin between the canvas edge and the text, in pixels.
    static let margin: CGFloat = 80

    /// The body type size, in pixels on the canvas.
    static let bodySize: CGFloat = 48

    /// The stable identifier — the project's identity for the file.
    public let id: InputID

    /// The user-facing name: the file's name.
    public let name: String

    /// Media is its own input kind (see GLOSSARY.md).
    public let kind = InputKind.media

    /// A picture and nothing else.
    public let media = InputMedia.video

    /// The document file.
    private let url: URL

    /// Whether the file is rendered as Markdown rather than verbatim text.
    private let isMarkdown: Bool

    /// The event bus, for reporting a decode problem.
    private let eventBus: EventBus?

    /// The frame plumbing: one rendered frame, one consumer at a time.
    private let holder: StillFrameHolder

    /// Creates a text input for the file.
    ///
    /// - Parameters:
    ///   - id: The stable identifier the input reports.
    ///   - url: The document file.
    ///   - isMarkdown: Whether to interpret the file as Markdown.
    ///   - clock: The master clock, stamping deliveries.
    ///   - eventBus: The host's event bus, or nil for no diagnostics.
    public init(id: InputID, url: URL, isMarkdown: Bool, clock: any EngineClock, eventBus: EventBus? = nil) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.isMarkdown = isMarkdown
        self.eventBus = eventBus
        self.holder = StillFrameHolder(clock: clock)
    }

    /// Reads and renders the document onto its canvas.
    ///
    /// - Throws: ``MediaInputError/fileUnreadable(_:)`` if the file cannot
    ///   be read, ``MediaInputError/textNotUTF8(_:)`` if it is not UTF-8,
    ///   or a buffer error. Reported as a `media.decode` error event before
    ///   it propagates.
    public func start() async throws {
        do {
            let text = try Self.read(url)
            holder.hold(try Self.render(Self.styled(text, asMarkdown: isMarkdown)))
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
    }

    /// The held frame, once, then an open stream (see ``StillFrameHolder``).
    public func frames() -> AsyncStream<CapturedFrame> {
        holder.frames()
    }

    /// Finishes the live stream and releases the canvas. Safe to call more
    /// than once.
    public func stop() async {
        holder.stop()
    }

    /// Reads the file as UTF-8.
    static func read(_ url: URL) throws(MediaInputError) -> String {
        guard let data = try? Data(contentsOf: url) else { throw .fileUnreadable(url) }
        guard let text = String(data: data, encoding: .utf8) else { throw .textNotUTF8(url) }
        return text
    }

    /// The document as a Core Text attributed string: Markdown structure
    /// (headings, paragraphs, list items, emphasis, code) mapped onto a
    /// fixed white type ramp, or verbatim text in the body style.
    ///
    /// Foundation's Markdown parser drops the source's line breaks and
    /// carries block structure as presentation intents instead, so blocks
    /// are re-separated here: a newline between blocks, a blank line
    /// between paragraphs, a bullet before a list item. Markdown that will
    /// not parse renders verbatim rather than failing — a document with a
    /// stray character is still a document.
    static func styled(_ text: String, asMarkdown isMarkdown: Bool) -> NSAttributedString {
        guard isMarkdown,
            let parsed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
        else {
            return NSAttributedString(string: text, attributes: attributes(size: bodySize, bold: false))
        }
        let result = NSMutableAttributedString()
        var previousBlock: Int?
        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            let block = intents.first?.identity
            if let block, block != previousBlock {
                if previousBlock != nil {
                    result.append(NSAttributedString(string: "\n", attributes: attributes(size: bodySize, bold: false)))
                }
                if intents.contains(where: { if case .listItem = $0.kind { true } else { false } }) {
                    result.append(
                        NSAttributedString(string: "•  ", attributes: attributes(size: bodySize, bold: false)))
                }
            }
            previousBlock = block ?? previousBlock
            var size = bodySize
            var bold = false
            var italic = false
            var monospaced = false
            for intent in intents {
                if case .header(let level) = intent.kind {
                    size = headerSize(level: level)
                    bold = true
                }
                if case .codeBlock = intent.kind { monospaced = true }
            }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { bold = true }
                if inline.contains(.emphasized) { italic = true }
                if inline.contains(.code) { monospaced = true }
            }
            result.append(
                NSAttributedString(
                    string: String(parsed[run.range].characters),
                    attributes: attributes(size: size, bold: bold, italic: italic, monospaced: monospaced)))
        }
        return result
    }

    /// The type size for a Markdown heading level: two body sizes for a
    /// title, stepping down to the body size by level five.
    static func headerSize(level: Int) -> CGFloat {
        switch level {
        case ...1: bodySize * 2
        case 2: bodySize * 1.667
        case 3: bodySize * 1.333
        case 4: bodySize * 1.167
        default: bodySize
        }
    }

    /// Core Text attributes for one run: white, the system face (or a
    /// monospaced one) at the size, with the requested traits.
    static func attributes(
        size: CGFloat, bold: Bool, italic: Bool = false, monospaced: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        let base =
            monospaced
            ? CTFontCreateWithName("Menlo" as CFString, size, nil)
            : CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }
        if italic { traits.insert(.italicTrait) }
        let font = traits.isEmpty ? base : (CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base)
        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
    }

    /// Lays the text out inside the canvas's margins and draws it onto a
    /// transparent BT.709-tagged 32BGRA buffer. Text that overruns the
    /// canvas is clipped at the bottom, the way a slide clips.
    static func render(_ text: NSAttributedString) throws(MediaInputError) -> CVPixelBuffer {
        let buffer = try MediaPixelBuffer.make(width: canvasSize.width, height: canvasSize.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try MediaPixelBuffer.drawingContext(for: buffer)
        let canvas = CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        context.clear(canvas)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: canvas.insetBy(dx: margin, dy: margin), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil)
        CTFrameDraw(frame, context)
        MediaPixelBuffer.tagBT709IfUntagged(buffer)
        return buffer
    }
}
