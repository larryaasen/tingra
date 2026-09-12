//
//  SnapshotWriterTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import Foundation
import ImageIO
import Testing

@testable import TingraApp

/// The snapshot render and write, against a temporary folder (ARCHITECTURE.md,
/// "Snapshots"): PNG in sRGB, alpha only where the picture has it, and never
/// two snapshots under one name.
@Suite("SnapshotWriter")
struct SnapshotWriterTests {
    /// A throwaway folder, not yet on disk — the writer creates it.
    private static func makeFolder() -> URL {
        URL.temporaryDirectory
            .appending(path: "tingra-snapshot-tests-\(UUID().uuidString)")
            .appending(path: "Tingra Snapshots", directoryHint: .isDirectory)
    }

    /// A solid picture of the given size and color.
    private static func picture(width: Int, height: Int, color: CIColor) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// The properties ImageIO reads back from a written file.
    private static func properties(of url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// Whether a written file decodes with an alpha channel — ImageIO
    /// reports `HasAlpha` only when there is one, so the decoded image's
    /// alpha layout is the answer either way.
    private static func decodesWithAlpha(_ url: URL) throws -> Bool {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// 2026-09-10 14:03:12 in the machine's own time zone.
    private static func moment() throws -> Date {
        try #require(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 9, day: 10, hour: 14, minute: 3, second: 12)))
    }

    @Test("An opaque picture becomes an sRGB PNG of its size, without an alpha channel")
    func opaquePictureHasNoAlpha() async throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let writer = SnapshotWriter()

        let png = try await writer.encode(
            Self.picture(width: 64, height: 36, color: CIColor(red: 0, green: 0, blue: 1)))
        let url = try await writer.write(png, subject: "Program", at: try Self.moment(), in: folder)

        #expect(png.width == 64)
        #expect(png.height == 36)
        #expect(!png.hasAlpha)
        #expect(url.lastPathComponent == "Tingra Program 2026-09-10 14.03.12.png")
        let properties = try Self.properties(of: url)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 64)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 36)
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool != true)
        #expect(try !Self.decodesWithAlpha(url))
        let profile = try #require(properties[kCGImagePropertyProfileName] as? String)
        #expect(profile.localizedStandardContains("sRGB"))
    }

    @Test("A picture with transparent pixels keeps its alpha channel")
    func transparentPictureKeepsAlpha() async throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let writer = SnapshotWriter()
        let opaque = Self.picture(width: 40, height: 40, color: CIColor(red: 1, green: 0, blue: 0))
        // A picture with a clear border: the Frame effect's corners, in
        // miniature.
        let bordered = opaque.transformed(by: CGAffineTransform(translationX: 4, y: 4))
            .composited(over: Self.picture(width: 48, height: 48, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)))

        let png = try await writer.encode(bordered)
        let url = try await writer.write(png, subject: "Title Layer", at: try Self.moment(), in: folder)

        #expect(png.hasAlpha)
        #expect(png.width == 48)
        #expect(try Self.properties(of: url)[kCGImagePropertyHasAlpha] as? Bool == true)
        #expect(try Self.decodesWithAlpha(url))
    }

    @Test("A picture away from the origin is written from its own extent")
    func offsetPictureIsMovedToTheOrigin() async throws {
        let writer = SnapshotWriter()
        let picture = Self.picture(width: 30, height: 20, color: CIColor(red: 0, green: 1, blue: 0))
            .transformed(by: CGAffineTransform(translationX: 100, y: 50))
        let png = try await writer.encode(picture)
        #expect(png.width == 30)
        #expect(png.height == 20)
        #expect(!png.hasAlpha)
    }

    @Test("Two snapshots in the same second get two names")
    func sameSecondGetsTwoNames() async throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let writer = SnapshotWriter()
        let date = try Self.moment()
        let png = try await writer.encode(Self.picture(width: 8, height: 8, color: CIColor(red: 1, green: 1, blue: 1)))

        async let first = writer.write(png, subject: "Program", at: date, in: folder)
        async let second = writer.write(png, subject: "Program", at: date, in: folder)
        let names = try await Set([first.lastPathComponent, second.lastPathComponent])

        #expect(
            names == ["Tingra Program 2026-09-10 14.03.12.png", "Tingra Program 2026-09-10 14.03.12 2.png"])
    }

    @Test("A folder that cannot be created throws, with the reason and the fix")
    func unwritableFolderThrows() async throws {
        let root = URL.temporaryDirectory.appending(path: "tingra-snapshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A file where the folder's parent should be: no folder can be made
        // beneath it.
        let blocker = root.appending(path: "not-a-folder")
        try Data("x".utf8).write(to: blocker)
        let writer = SnapshotWriter()
        let png = try await writer.encode(Self.picture(width: 8, height: 8, color: CIColor(red: 1, green: 1, blue: 1)))

        await #expect {
            _ = try await writer.write(png, subject: "Program", at: .now, in: blocker.appending(path: "Snapshots"))
        } throws: { error in
            guard case .folderUnavailable(let path, let reason) = error as? SnapshotError else { return false }
            let description = (error as? SnapshotError)?.description ?? ""
            return path.hasSuffix("Snapshots") && !reason.isEmpty && description.contains("Settings")
                && !description.contains(path)
        }
    }

    @Test("A picture with no pixels throws rather than writing an empty file")
    func emptyPictureThrows() async {
        let writer = SnapshotWriter()
        await #expect(throws: SnapshotError.emptyPicture) {
            _ = try await writer.encode(CIImage.empty())
        }
        await #expect(throws: SnapshotError.emptyPicture) {
            _ = try await writer.encode(CIImage(color: CIColor(red: 1, green: 0, blue: 0)))
        }
    }

    @Test("The operator's message names the folder; the event's description never does")
    func messagesKeepThePathOutOfTheEvent() {
        let error = SnapshotError.writeFailed(path: "/Volumes/Shows/Stills", reason: "The volume is read only.")
        #expect(error.operatorMessage.contains("/Volumes/Shows/Stills"))
        #expect(!error.description.contains("/Volumes/Shows/Stills"))
        #expect(error.description.contains("The volume is read only."))
    }
}
