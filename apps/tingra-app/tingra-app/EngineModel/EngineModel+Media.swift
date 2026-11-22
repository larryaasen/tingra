//
//  EngineModel+Media.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import TingraComposition
import TingraEventBus
import TingraHost
import TingraMediaPlugIns
import TingraPlugInKit
import UniformTypeIdentifiers

/// Media inputs: the images, video and audio files, and text a project holds.
extension EngineModel {
    /// Whether a media item's input is registered, for the Library's rows.
    /// Asks both media-role lists: no layer can bind to an audio file, so
    /// ``isInputAvailable(_:)`` would call every audio file missing.
    ///
    /// - Parameter id: The media item's input.
    /// - Returns: Whether that input is discovered, as picture or as sound.
    func isMediaAvailable(_ id: InputID) -> Bool {
        videoInputs.contains { $0.id == id } || audioInputs.contains { $0.id == id }
    }

    /// The media item whose input has the given identifier, if any — the
    /// item's id *is* the input's.
    ///
    /// - Parameter id: An input identifier.
    /// - Returns: The item, or nil for an input that is not media.
    func mediaItem(forInput id: InputID) -> ProjectMedia? {
        media.first { $0.id.inputID == id }
    }

    /// Adds files to the project as media: each becomes an item and, when a
    /// registered provider opens it, an input. A file no provider opens, or
    /// that cannot be read, is reported and skipped.
    ///
    /// - Parameter urls: The files to add.
    func addMedia(urls: [URL]) async {
        var added = false
        for url in urls {
            let item = ProjectMedia(url: url)
            guard await registerMedia(item) else { continue }
            media.append(item)
            added = true
            eventBus.event(
                "media.added",
                domain: .capture,
                params: [
                    "id": .string(item.id.rawValue),
                    "name": .string(item.name),
                    "type": .string(MediaRegistry.contentType(of: url)?.identifier ?? ""),
                ]
            )
        }
        guard added else { return }
        await readDeviceLists()
        await refreshMixerStrips()
        scheduleAutosave()
    }

    /// Removes a media item from the project and its input from the registry;
    /// the reconfigure pass stops it if it was playing. Never edits shots: a
    /// bound layer stays bound and dormant, and the file is untouched.
    ///
    /// - Parameter id: The item to remove.
    func removeMedia(_ id: MediaID) async {
        guard let index = media.firstIndex(where: { $0.id == id }) else { return }
        let item = media.remove(at: index)
        mediaDurations[id] = nil
        await registry.unregister(id.inputID)
        eventBus.event(
            "media.removed",
            domain: .capture,
            params: ["id": .string(item.id.rawValue), "name": .string(item.name)]
        )
        await readDeviceLists()
        await refreshMixerStrips()
        await reconfigure()
        // An audio file is in no shot, so the pass above never sees it: the
        // audio pass is what stops one playing on an unmuted strip, now
        // that the registry no longer holds it. The strip stays, dormant.
        await reconfigureAudio()
        scheduleAutosave()
    }

    /// Registers the inputs for the loaded project's media list, at boot.
    /// An item that cannot register stays in the list, dormant.
    func registerProjectMedia() async {
        for item in media {
            _ = await registerMedia(item)
        }
    }

    /// Makes and registers the input for one media item, and loads a
    /// movie's or an audio file's duration for the Library.
    ///
    /// - Parameter item: The item to register.
    /// - Returns: Whether the input registered. A missing file reports
    ///   `media.unavailable`, an ordinary event; one no provider opens or the
    ///   registry refuses reports a `media.add` error.
    private func registerMedia(_ item: ProjectMedia) async -> Bool {
        let url = item.url
        guard FileManager.default.isReadableFile(atPath: item.path) else {
            eventBus.event(
                "media.unavailable",
                domain: .capture,
                params: ["id": .string(item.id.rawValue), "name": .string(item.name)]
            )
            return false
        }
        do {
            let input = try await mediaRegistry.makeInput(for: url, id: item.id.inputID)
            try await registry.register(input)
        } catch {
            eventBus.error(
                "media.add",
                domain: .capture,
                params: [
                    "id": .string(item.id.rawValue),
                    "name": .string(item.name),
                    "error": .string(String(describing: error)),
                ]
            )
            return false
        }
        let type = MediaRegistry.contentType(of: url)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true,
            let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric
        {
            mediaDurations[item.id] = duration.seconds
        }
        if let size = await Self.pictureSize(of: url, type: type) {
            mediaSizes[item.id] = size
        }
        return true
    }

    /// A media file's picture size in pixels, read without decoding it: an
    /// image's properties with the EXIF orientation applied, a movie's video
    /// track size with its preferred transform, or a document's text canvas.
    ///
    /// - Parameters:
    ///   - url: The file.
    ///   - type: Its content type, or nil when unknown.
    /// - Returns: The picture size, or nil.
    nonisolated static func pictureSize(of url: URL, type: UTType?) async -> CGSize? {
        guard let type else { return nil }
        if type.conforms(to: .movie) {
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
            else { return nil }
            let transformed = natural.applying(transform)
            let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            return size.width > 0 && size.height > 0 ? size : nil
        }
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Double,
                let height = properties[kCGImagePropertyPixelHeight] as? Double,
                width > 0, height > 0
            else { return nil }
            // Orientations 5 through 8 are rotated a quarter turn, so the
            // picture the operator sees has the file's width and height
            // swapped (the image input applies the same transform).
            let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
            return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        if type.conforms(to: .plainText) {
            return CGSize(width: TextInput.canvasSize.width, height: TextInput.canvasSize.height)
        }
        return nil
    }
}
