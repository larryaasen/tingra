//
//  ImageMediaProvider.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import TingraEventBus
import TingraPlugInKit
import UniformTypeIdentifiers

/// The provider for still images: every format ImageIO reads (`public.image`).
public struct ImageMediaProvider: MediaInputProvider {
    /// The provider's stable identifier.
    public static let providerID = MediaProviderID(rawValue: "com.moonwink.tingra.media.image")

    /// The stable identifier.
    public var id: MediaProviderID { Self.providerID }

    /// The user-facing name.
    public let name = "Image"

    /// Every image format ImageIO reads.
    public let contentTypes: [UTType] = [.image]

    /// The clock that stamps the still's delivery.
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

    /// Creates an image input for the file. Never throws: the file is
    /// opened at ``Input/start()``, where a problem is reported.
    public func makeInput(for url: URL, id: InputID) throws -> any Input {
        ImageInput(id: id, url: url, clock: clock, eventBus: eventBus)
    }
}

/// A still image as an input: decoded once at start into one BT.709-tagged
/// 32BGRA buffer, delivered once per consumer and held (ARCHITECTURE.md,
/// "Media inputs and the Library's Media tab").
public final class ImageInput: Input, Sendable {
    /// The longest side a decoded image may have, in pixels — a 4K canvas
    /// needs no more, and an unbounded photo would cost the compositor a
    /// scale on every tick.
    public static let maximumPixelSize = 3840

    /// The stable identifier — the project's identity for the file.
    public let id: InputID

    /// The user-facing name: the file's name.
    public let name: String

    /// Media is its own input kind (see GLOSSARY.md).
    public let kind = InputKind.media

    /// A picture and nothing else.
    public let media = InputMedia.video

    /// The image file.
    private let url: URL

    /// The event bus, for reporting a decode problem.
    private let eventBus: EventBus?

    /// The frame plumbing: one decoded frame, one consumer at a time.
    private let holder: StillFrameHolder

    /// Creates an image input for the file.
    ///
    /// - Parameters:
    ///   - id: The stable identifier the input reports.
    ///   - url: The image file.
    ///   - clock: The master clock, stamping deliveries.
    ///   - eventBus: The host's event bus, or nil for no diagnostics.
    public init(id: InputID, url: URL, clock: any EngineClock, eventBus: EventBus? = nil) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.eventBus = eventBus
        self.holder = StillFrameHolder(clock: clock)
    }

    /// Decodes the image into its buffer.
    ///
    /// - Throws: ``MediaInputError/fileUnreadable(_:)`` if the file cannot
    ///   be opened, ``MediaInputError/imageDecodeRefused(_:)`` if ImageIO
    ///   decodes nothing from it, or a buffer error. Reported as a
    ///   `media.decode` error event before it propagates.
    public func start() async throws {
        do {
            holder.hold(try Self.decode(url))
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

    /// Finishes the live stream and releases the picture. Safe to call more
    /// than once.
    public func stop() async {
        holder.stop()
    }

    /// Decodes the file into a BT.709-tagged 32BGRA `IOSurface` buffer at
    /// native size capped at ``maximumPixelSize`` on the long side, with the
    /// EXIF orientation applied and alpha kept.
    ///
    /// ImageIO's thumbnail path rather than `CGImageSourceCreateImageAtIndex`
    /// because it does three things in one decode: the size cap, the
    /// orientation transform, and — for a photo larger than the cap — a
    /// decode at the reduced size instead of a full decode followed by a
    /// scale.
    static func decode(_ url: URL) throws(MediaInputError) -> CVPixelBuffer {
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { throw .fileUnreadable(url) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw .imageDecodeRefused(url)
        }
        let buffer = try MediaPixelBuffer.make(width: image.width, height: image.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try MediaPixelBuffer.drawingContext(for: buffer)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Cleared first: a fresh buffer's contents are undefined, and the
        // alpha matters as much as the colour — a transparent PNG must
        // show the layers beneath it.
        context.clear(rect)
        context.draw(image, in: rect)
        MediaPixelBuffer.tagBT709IfUntagged(buffer)
        return buffer
    }
}
