//
//  SnapshotWriter.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// A snapshot encoded and ready to write: PNG bytes and what they hold.
nonisolated struct SnapshotPNG: Sendable, Equatable {
    /// The PNG file's bytes.
    let data: Data

    /// The picture's width in pixels.
    let width: Int

    /// The picture's height in pixels.
    let height: Int

    /// Whether the file carries an alpha channel — only when the picture has
    /// a pixel that is not fully opaque.
    let hasAlpha: Bool
}

/// Why a snapshot was not saved. `description` is developer-facing (the
/// `snapshot.save` error event's message, naming the cause and the fix,
/// never the folder's path — the media rule); ``operatorMessage`` is what
/// the monitor's badge says on hover.
nonisolated enum SnapshotError: Error, Equatable, CustomStringConvertible {
    /// The picture had no pixels to write — an empty or infinite extent.
    case emptyPicture

    /// Core Image could not render the picture into an image.
    case renderFailed

    /// ImageIO could not encode the image as PNG.
    case encodingFailed

    /// The snapshots folder could not be created.
    ///
    /// - Parameters:
    ///   - path: The folder, for the operator's message only.
    ///   - reason: The file system's own explanation.
    case folderUnavailable(path: String, reason: String)

    /// The file could not be written into the folder.
    ///
    /// - Parameters:
    ///   - path: The folder, for the operator's message only.
    ///   - reason: The file system's own explanation.
    case writeFailed(path: String, reason: String)

    /// The developer-facing explanation: the cause, then the fix.
    var description: String {
        switch self {
        case .emptyPicture:
            "the monitor's picture has no pixels (an empty extent); nothing to write"
        case .renderFailed:
            "Core Image returned no image for the monitor's picture; try again once the monitor shows a picture"
        case .encodingFailed:
            "ImageIO could not encode the picture as PNG; try again, and report it if it persists"
        case .folderUnavailable(_, let reason):
            "the snapshots folder could not be created (\(reason)); choose a writable folder in Settings ▸ General ▸ Snapshots"
        case .writeFailed(_, let reason):
            "the snapshot file could not be written (\(reason)); choose a writable folder in Settings ▸ General ▸ Snapshots"
        }
    }

    /// What the operator reads when they hover the Snapshot Not Saved badge:
    /// the cause in their language, with the folder where the folder is the
    /// problem.
    var operatorMessage: String {
        switch self {
        case .emptyPicture, .renderFailed, .encodingFailed:
            String(
                localized: "The picture could not be made into an image file. Try again.",
                comment: "Snapshot Not Saved badge tooltip: the picture could not be rendered or encoded")
        case .folderUnavailable(let path, let reason):
            String(
                localized: "The folder \(path) could not be created: \(reason)",
                comment:
                    "Snapshot Not Saved badge tooltip: the snapshots folder could not be created; the placeholders are the folder and the system's reason"
            )
        case .writeFailed(let path, let reason):
            String(
                localized: "The snapshot could not be saved in \(path): \(reason)",
                comment:
                    "Snapshot Not Saved badge tooltip: the file could not be written; the placeholders are the folder and the system's reason"
            )
        }
    }
}

/// Turns a monitor's picture into a PNG file (ARCHITECTURE.md, "Snapshots"):
/// **render concurrently, write serially, and hold the frame only for the
/// render.**
///
/// ``encode(_:)`` is `nonisolated` and `@concurrent`, so it runs off the
/// main actor and never queues behind the writer: a burst of snapshots
/// cannot build up a line of capture buffers waiting their turn. It renders
/// through the writer's **own** Metal-backed `CIContext` — a second context
/// for a rare job, rather than borrowing the monitors' main-actor one — and
/// lets go of the picture, and with it the pixel buffer, as soon as the
/// render finishes, before the PNG encode, which is the slow part at large
/// sizes (the frame ownership rule's fourth clause).
///
/// ``write(_:subject:at:in:)`` is the actor's one isolated job: pick the
/// name and write the bytes, one file at a time, so two snapshots in the
/// same second (a held ⌥⌘S repeats) can never choose the same name.
actor SnapshotWriter {
    /// The Core Image context the pictures render through.
    private let context: CIContext

    /// Creates a writer with its own Core Image context — Metal-backed when
    /// the Mac has a GPU, which every Apple Silicon Mac does.
    init() {
        context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0) } ?? CIContext()
    }

    /// Renders a picture to PNG bytes in sRGB — the monitors' own output
    /// space (``MonitorRenderContext/colorSpace``), with the profile
    /// embedded, so the file matches the monitor it was taken from. An
    /// opaque picture is written without an alpha channel; one with any
    /// transparent pixel (a Frame's rounded corners, a text overlay) keeps
    /// it.
    ///
    /// - Parameter image: The picture, exactly as the monitor would draw it.
    ///   Consumed: the render is its last use.
    /// - Returns: The encoded picture.
    /// - Throws: ``SnapshotError`` when the picture is empty or cannot be
    ///   rendered or encoded.
    @concurrent
    nonisolated func encode(_ image: consuming CIImage) async throws -> SnapshotPNG {
        let rendered = try Self.render(consume image, with: context)
        // The picture — and the pixel buffer behind it — is gone by here;
        // only the rendered bitmap is held through the encode.
        return try Self.encodePNG(rendered)
    }

    /// Names the file and writes the bytes, creating the folder first when
    /// it is not there yet. Never overwrites: the name is chosen free and
    /// the write refuses an existing file.
    ///
    /// - Parameters:
    ///   - png: The encoded snapshot.
    ///   - subject: What was saved, in the operator's language.
    ///   - date: The moment the snapshot was asked for — the file's
    ///     timestamp, not the moment of the write.
    ///   - folder: The snapshots folder.
    /// - Returns: The file written.
    /// - Throws: ``SnapshotError/folderUnavailable(path:reason:)`` or
    ///   ``SnapshotError/writeFailed(path:reason:)``.
    func write(_ png: SnapshotPNG, subject: String, at date: Date, in folder: URL) throws -> URL {
        let path = folder.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw SnapshotError.folderUnavailable(path: path, reason: error.localizedDescription)
        }
        let url = SnapshotFilename.url(in: folder, subject: subject, at: date)
        do {
            try png.data.write(to: url, options: .withoutOverwriting)
        } catch {
            throw SnapshotError.writeFailed(path: path, reason: error.localizedDescription)
        }
        return url
    }

    /// A rendered picture and whether it is opaque.
    private struct Rendered {
        /// The picture as an image, 8 bits per component, premultiplied.
        let image: CGImage

        /// Whether every pixel is fully opaque.
        let isOpaque: Bool
    }

    /// Renders the picture, moved to the origin, into an sRGB image.
    ///
    /// - Parameters:
    ///   - image: The picture; consumed.
    ///   - context: The context to render through.
    /// - Returns: The rendered image.
    /// - Throws: ``SnapshotError/emptyPicture`` or
    ///   ``SnapshotError/renderFailed``.
    private nonisolated static func render(_ image: consuming CIImage, with context: CIContext) throws -> Rendered {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull else { throw SnapshotError.emptyPicture }
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { throw SnapshotError.emptyPicture }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw SnapshotError.renderFailed }
        let placed = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let rendered = context.createCGImage(placed, from: bounds, format: .RGBA8, colorSpace: space) else {
            throw SnapshotError.renderFailed
        }
        return Rendered(image: rendered, isOpaque: placed.isOpaque || isOpaque(rendered))
    }

    /// Whether every pixel of an 8-bit RGBA image is fully opaque — read
    /// from the rendered bytes, since Core Image cannot know that a pixel
    /// buffer's alpha is all ones.
    ///
    /// - Parameter image: The rendered image.
    /// - Returns: Whether no pixel has alpha below one.
    private nonisolated static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        case .premultipliedLast, .last:
            break
        default:
            // A layout this code did not ask for: keep the alpha rather than
            // guess, since dropping it could lose transparency.
            return false
        }
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, let data = image.dataProvider?.data else {
            return false
        }
        // "Last" is in the pixel's 32-bit word; stored little-endian, the
        // word's last byte comes first in memory.
        let alphaOffset = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little ? 0 : 3
        let bytesPerRow = image.bytesPerRow
        let width = image.width
        let height = image.height
        return (data as Data).withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            for row in 0..<height {
                let start = row * bytesPerRow + alphaOffset
                for column in 0..<width where buffer[start + column * 4] != 0xFF {
                    return false
                }
            }
            return true
        }
    }

    /// Encodes a rendered picture as PNG, re-describing an opaque one as
    /// having no alpha so the file is RGB rather than RGBA.
    ///
    /// - Parameter rendered: The rendered picture.
    /// - Returns: The PNG.
    /// - Throws: ``SnapshotError/encodingFailed``.
    private nonisolated static func encodePNG(_ rendered: Rendered) throws -> SnapshotPNG {
        var image = rendered.image
        if rendered.isOpaque, let opaque = withoutAlpha(image) {
            image = opaque
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw SnapshotError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SnapshotError.encodingFailed }
        return SnapshotPNG(
            data: data as Data,
            width: image.width,
            height: image.height,
            hasAlpha: !rendered.isOpaque
        )
    }

    /// The same pixels described as RGBX — the alpha byte skipped — which
    /// ImageIO writes as an RGB PNG. Premultiplied colors over an alpha of
    /// one are the colors themselves, so nothing changes but the channel.
    ///
    /// - Parameter image: An opaque 8-bit RGBA image.
    /// - Returns: The image without alpha, or nil when it cannot be
    ///   re-described.
    private nonisolated static func withoutAlpha(_ image: CGImage) -> CGImage? {
        guard let provider = image.dataProvider, let space = image.colorSpace else { return nil }
        // Keep the byte order the bytes were rendered in; change only what
        // the fourth byte means.
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            bitsPerPixel: image.bitsPerPixel,
            bytesPerRow: image.bytesPerRow,
            space: space,
            bitmapInfo: byteOrder.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
