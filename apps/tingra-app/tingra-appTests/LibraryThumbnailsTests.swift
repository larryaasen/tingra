//
//  LibraryThumbnailsTests.swift
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

@Suite("LibraryThumbnails")
struct LibraryThumbnailsTests {
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

    @Test("An available image row gets a Quick Look thumbnail, once")
    @MainActor
    func loadsThumbnailForImage() async throws {
        let folder = URL.temporaryDirectory.appending(path: "tingra-thumbnail-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writePNG(into: folder)
        let item = LibraryItem(
            id: MediaID(rawValue: "m"), name: "poster.png", url: url, kind: .image, modifiedAt: nil, byteCount: nil,
            duration: nil, isAvailable: true)
        let thumbnails = LibraryThumbnails()
        let bus = EventBus()
        await thumbnails.load(item, reporting: bus)
        let image = try #require(thumbnails.images[item.id])
        #expect(image.width > 0 && image.height > 0)
    }

    @Test("A row that was unavailable when first seen gets its thumbnail once it becomes available")
    @MainActor
    func loadsOnceRowBecomesAvailable() async throws {
        let folder = URL.temporaryDirectory.appending(path: "tingra-thumbnail-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writePNG(into: folder)
        let pending = LibraryItem(
            id: MediaID(rawValue: "m"), name: "poster.png", url: url, kind: .image, modifiedAt: nil, byteCount: nil,
            duration: nil, isAvailable: false)
        let thumbnails = LibraryThumbnails()
        await thumbnails.load(pending, reporting: nil)
        #expect(thumbnails.images.isEmpty)
        let available = LibraryItem(
            id: pending.id, name: pending.name, url: url, kind: .image, modifiedAt: nil, byteCount: nil, duration: nil,
            isAvailable: true)
        await thumbnails.load(available, reporting: nil)
        #expect(thumbnails.images[pending.id] != nil)
    }

    @Test("A missing file's row is never asked for a thumbnail")
    @MainActor
    func skipsUnavailableRow() async {
        let item = LibraryItem(
            id: MediaID(rawValue: "m"), name: "gone.png", url: URL(filePath: "/nonexistent/gone.png"), kind: .image,
            modifiedAt: nil, byteCount: nil, duration: nil, isAvailable: false)
        let thumbnails = LibraryThumbnails()
        await thumbnails.load(item, reporting: nil)
        #expect(thumbnails.images.isEmpty)
    }
}
