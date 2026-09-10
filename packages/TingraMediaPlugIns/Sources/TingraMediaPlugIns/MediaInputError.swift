//
//  MediaInputError.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo
import Foundation

/// Errors a media input throws from ``Input/start()`` — all recoverable,
/// all descriptive, per the never-crash rule (CLAUDE.md). A file that
/// cannot be played is reported and its layers contribute nothing; it
/// never takes down the host.
public enum MediaInputError: Error, Equatable {
    /// The file could not be opened for reading — missing, moved, or not
    /// readable by this user.
    case fileUnreadable(URL)

    /// ImageIO opened the file but could not decode an image from it.
    case imageDecodeRefused(URL)

    /// The text file is not valid UTF-8.
    case textNotUTF8(URL)

    /// The movie has no video track, so there is nothing to show.
    case noVideoTrack(URL)

    /// AVFoundation refused to read the movie; the payload is its reason.
    case readerRefused(URL, reason: String)

    /// Core Video would not vend a pixel buffer; the payload is its status.
    case pixelBufferUnavailable(CVReturn)

    /// Core Graphics would not create a drawing context over the buffer.
    case drawingContextUnavailable
}

extension MediaInputError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileUnreadable(let url):
            return """
                The media file '\(url.lastPathComponent)' could not be read. Check that it still exists at \
                its path and that you have permission to read it; if it moved, remove it from the project \
                and add it again from its new location.
                """
        case .imageDecodeRefused(let url):
            return """
                The image '\(url.lastPathComponent)' could not be decoded. The file may be damaged or in a \
                format ImageIO does not read; export it as PNG, JPEG, or HEIC and add that.
                """
        case .textNotUTF8(let url):
            return """
                The text file '\(url.lastPathComponent)' is not valid UTF-8. Save it as UTF-8 and add it again.
                """
        case .noVideoTrack(let url):
            return """
                The movie '\(url.lastPathComponent)' has no video track, so there is nothing to show. Add a \
                movie with picture; audio-only files are not media inputs yet.
                """
        case .readerRefused(let url, let reason):
            return """
                The movie '\(url.lastPathComponent)' could not be read: \(reason). The file may be damaged \
                or use a codec this Mac cannot decode; re-export it as H.264 or HEVC in a .mov or .mp4.
                """
        case .pixelBufferUnavailable(let status):
            return """
                Core Video would not provide a pixel buffer for the media (CVReturn \(status)). This is \
                a resource problem on this Mac rather than a problem with the file; free memory and retry.
                """
        case .drawingContextUnavailable:
            return """
                Core Graphics would not create a drawing context for the media. This is a defect worth \
                reporting rather than a problem with the file.
                """
        }
    }
}
