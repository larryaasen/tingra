//
//  LibraryItem.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition
import TingraPlugInKit
import UniformTypeIdentifiers

/// One row of the Library's list (GLOSSARY.md, "Library"): a file the show
/// uses, with what the list shows about it. Built from a project's media
/// items today; the Snapshots and Recordings tabs build the same value
/// from their folders when they land (ARCHITECTURE.md, "Media inputs and
/// the Library's Media tab").
struct LibraryItem: Identifiable, Equatable {
    /// What kind of file a row is, for its symbol.
    enum Kind: Equatable {
        /// A still image.
        case image

        /// A movie.
        case movie

        /// A text or Markdown document.
        case text

        /// A file whose type says none of the above.
        case other

        /// The SF Symbol the sidebar and the Library label the file with.
        var symbol: String {
            switch self {
            case .image: "photo"
            case .movie: "film"
            case .text: "doc.text"
            case .other: "doc"
            }
        }
    }

    /// The row's identity: the media item's.
    let id: MediaID

    /// The user-facing name: the file's name.
    let name: String

    /// The file.
    let url: URL

    /// What kind of file it is.
    let kind: Kind

    /// When the file was last modified, if the file system said.
    let modifiedAt: Date?

    /// The file's size in bytes, if the file system said.
    let byteCount: Int64?

    /// A movie's length in seconds, if known.
    let duration: TimeInterval?

    /// Whether the file is present and its input registered — a missing
    /// file's row draws with a warning, the layer list's dormant-input rule.
    let isAvailable: Bool

    /// The identifier of the input that plays the file.
    var inputID: InputID {
        id.inputID
    }

    /// The row's second line: the modification date, then the movie's
    /// length or the file's size — whichever the file has.
    var detail: String {
        Self.detail(modifiedAt: modifiedAt, byteCount: byteCount, duration: duration)
    }

    /// The kind a content type implies: movies before images (a movie type
    /// never conforms to `image`, but the order states the priority), then
    /// text, then anything else — including no type at all.
    ///
    /// - Parameter contentType: The file's type, or nil when unknown.
    /// - Returns: The kind.
    nonisolated static func kind(of contentType: UTType?) -> Kind {
        guard let contentType else { return .other }
        if contentType.conforms(to: .movie) { return .movie }
        if contentType.conforms(to: .image) { return .image }
        if contentType.conforms(to: .plainText) { return .text }
        return .other
    }

    /// The second-line text for the given facts, joined with a middle dot;
    /// a movie's length wins over its size, and a fact the file does not
    /// have is left out rather than shown as a placeholder.
    ///
    /// - Parameters:
    ///   - modifiedAt: The modification date, or nil.
    ///   - byteCount: The size in bytes, or nil.
    ///   - duration: The length in seconds, or nil.
    /// - Returns: The joined text, empty when nothing is known.
    nonisolated static func detail(modifiedAt: Date?, byteCount: Int64?, duration: TimeInterval?) -> String {
        var parts: [String] = []
        if let modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .omitted))
        }
        if let duration {
            parts.append(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
        } else if let byteCount {
            parts.append(byteCount.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    /// The rows for a project's media items, in the project's order.
    ///
    /// - Parameters:
    ///   - media: The project's media items.
    ///   - durations: Known movie lengths by item.
    ///   - isAvailable: Whether an item's input is registered.
    ///   - attributes: How to read a file's modification date and size (the
    ///     file system by default; a stub under test).
    /// - Returns: One row per item.
    static func items(
        from media: [ProjectMedia],
        durations: [MediaID: TimeInterval],
        isAvailable: (InputID) -> Bool,
        attributes: (URL) -> (modifiedAt: Date?, byteCount: Int64?) = fileAttributes
    ) -> [LibraryItem] {
        media.map { item in
            let facts = attributes(item.url)
            return LibraryItem(
                id: item.id,
                name: item.name,
                url: item.url,
                kind: kind(of: UTType(filenameExtension: item.url.pathExtension)),
                modifiedAt: facts.modifiedAt,
                byteCount: facts.byteCount,
                duration: durations[item.id],
                isAvailable: isAvailable(item.id.inputID)
            )
        }
    }

    /// A file's modification date and size from the file system, or nils
    /// for a file that is not there.
    ///
    /// - Parameter url: The file.
    /// - Returns: The facts the file system reports.
    nonisolated static func fileAttributes(of url: URL) -> (modifiedAt: Date?, byteCount: Int64?) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return (nil, nil)
        }
        return (values.contentModificationDate, values.fileSize.map(Int64.init))
    }
}
