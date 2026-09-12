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
/// items for the Media tab, from the snapshots folder for the Snapshots tab
/// (ARCHITECTURE.md, "Snapshots"), and from the recordings folder for the
/// Recordings tab ("The Recordings tab").
struct LibraryItem: Identifiable, Equatable {
    /// What a row is the row of: a project media item, which is an input
    /// and drags as one, or a file in a folder, which drags as a file.
    enum Identity: Hashable {
        /// A project media item.
        case media(MediaID)

        /// A file in a folder the tab lists — a snapshot or a recording.
        case file(URL)
    }

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

    /// The row's identity: the media item's, or the file's.
    let id: Identity

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

    /// Whether this is the recording being written right now: a file that
    /// is not yet playable, so its row offers Reveal in Finder alone, is
    /// never thumbnailed or measured, and does not drag (ARCHITECTURE.md,
    /// "The Recordings tab").
    let isRecording: Bool

    /// Creates a row.
    ///
    /// - Parameters:
    ///   - id: The media item's or the file's identity.
    ///   - name: The user-facing name.
    ///   - url: The file.
    ///   - kind: What kind of file it is.
    ///   - modifiedAt: When the file was last modified, if known.
    ///   - byteCount: The file's size in bytes, if known.
    ///   - duration: A movie's length in seconds, if known.
    ///   - isAvailable: Whether the file is present and its input registered.
    ///   - isRecording: Whether the file is the recording being written.
    init(
        id: Identity, name: String, url: URL, kind: Kind, modifiedAt: Date?, byteCount: Int64?,
        duration: TimeInterval?, isAvailable: Bool, isRecording: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.modifiedAt = modifiedAt
        self.byteCount = byteCount
        self.duration = duration
        self.isAvailable = isAvailable
        self.isRecording = isRecording
    }

    /// The media item the row is, or nil for a file row.
    var mediaID: MediaID? {
        guard case .media(let id) = id else { return nil }
        return id
    }

    /// What the row's events name it by: the media item's id, or a file
    /// row's file name — never its folder (the media rule).
    var eventID: String {
        switch id {
        case .media(let id): id.rawValue
        case .file(let url): url.lastPathComponent
        }
    }

    /// The identifier of the input that plays the file, or nil for a file
    /// row — a snapshot is not an input until it is added as media.
    var inputID: InputID? {
        mediaID?.inputID
    }

    /// The row's second line with only the facts the row itself carries
    /// (``detail(knownDuration:)``).
    var detail: String {
        detail(knownDuration: nil)
    }

    /// The row's second line: the modification date, then the movie's
    /// length, then the file's size — whichever the file has. A file row's
    /// date carries the time too, since a show's snapshots and takes share a
    /// day. The recording being written says only that it is recording: its
    /// size and date are changing, and the elapsed time is the Record
    /// control's to show.
    ///
    /// - Parameter knownDuration: A length measured for the row elsewhere
    ///   (``LibraryFacts``), used when the row carries none of its own.
    /// - Returns: The line.
    func detail(knownDuration: TimeInterval?) -> String {
        guard !isRecording else {
            return String(
                localized: "Recording…", comment: "Library Recordings tab: detail line of the take being recorded now")
        }
        return Self.detail(
            modifiedAt: modifiedAt, byteCount: byteCount, duration: duration ?? knownDuration,
            includesTime: mediaID == nil)
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

    /// The second-line text for the given facts, joined with a middle dot:
    /// the date, the length, then the size — a movie shows both, since how
    /// long a take runs and how much it weighs to send are different
    /// questions — and a fact the file does not have is left out rather than
    /// shown as a placeholder.
    ///
    /// - Parameters:
    ///   - modifiedAt: The modification date, or nil.
    ///   - byteCount: The size in bytes, or nil.
    ///   - duration: The length in seconds, or nil.
    ///   - includesTime: Whether the date carries the time of day.
    /// - Returns: The joined text, empty when nothing is known.
    nonisolated static func detail(
        modifiedAt: Date?, byteCount: Int64?, duration: TimeInterval?, includesTime: Bool = false
    ) -> String {
        var parts: [String] = []
        if let modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: includesTime ? .shortened : .omitted))
        }
        if let duration {
            parts.append(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
        }
        if let byteCount {
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
                id: .media(item.id),
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

    /// The rows for the images in the snapshots folder, newest first
    /// (``FolderListing``).
    ///
    /// - Parameter folder: The snapshots folder.
    /// - Returns: One row per image; none for a folder not yet created.
    static func snapshots(in folder: URL) -> [LibraryItem] {
        FolderListing.files(in: folder, conformingTo: .image).map { file in
            LibraryItem(
                id: .file(file.url),
                name: file.url.lastPathComponent,
                url: file.url,
                kind: .image,
                modifiedAt: file.modifiedAt,
                byteCount: file.byteCount,
                duration: nil,
                isAvailable: true
            )
        }
    }

    /// The rows for the movies in the recordings folder, newest first
    /// (``FolderListing``), with the recording being written — if it is in
    /// this folder — marked and first, whatever its date says.
    ///
    /// - Parameters:
    ///   - folder: The recordings folder.
    ///   - recording: The file being recorded now, or nil when nothing is.
    /// - Returns: One row per movie; none for a folder not yet created.
    static func recordings(in folder: URL, recording: URL?) -> [LibraryItem] {
        let rows = FolderListing.files(in: folder, conformingTo: .movie).map { file in
            LibraryItem(
                id: .file(file.url),
                name: file.url.lastPathComponent,
                url: file.url,
                kind: .movie,
                modifiedAt: file.modifiedAt,
                byteCount: file.byteCount,
                duration: nil,
                isAvailable: true,
                isRecording: recording.map { FolderListing.isSameFile($0, file.url) } ?? false
            )
        }
        return rows.filter(\.isRecording) + rows.filter { !$0.isRecording }
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
