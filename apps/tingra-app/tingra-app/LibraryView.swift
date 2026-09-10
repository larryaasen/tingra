//
//  LibraryView.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import TingraComposition
import TingraEventBus
import UniformTypeIdentifiers

/// The **Library** panel (GLOSSARY.md): the files a show uses, at the
/// bottom of the trailing sidebar under the layer inspector. This iteration
/// holds the Media tab alone — the project's media files, with Add Media…,
/// drop-to-add, and each row's Quick Look, Reveal in Finder, and Remove from
/// Project — and the tab strip arrives with the Snapshots tab
/// (ARCHITECTURE.md, "Media inputs and the Library's Media tab").
///
/// The list is ``LibraryList``, one component every tab shares, over
/// ``LibraryItem`` rows. Selecting a row changes nothing on air: staging
/// is the sidebar's Media section, and a row drags to the shot bank and the
/// layer list as any input row does.
struct LibraryView: View {
    /// The engine model whose media the panel lists and edits.
    let model: EngineModel

    /// Whether the Add Media… file importer is up.
    @State private var isImporterPresented = false

    /// The file Quick Look is showing, or nil while it is closed.
    @State private var previewURL: URL?

    /// The rows' thumbnails, generated once per file and kept for the
    /// panel's lifetime.
    @State private var thumbnails = LibraryThumbnails()

    /// The panel's inner padding.
    private static let padding: CGFloat = 12

    /// The rows for the project's media, in project order.
    private var items: [LibraryItem] {
        LibraryItem.items(from: model.media, durations: model.mediaDurations, isAvailable: model.isInputAvailable)
    }

    /// The content types the importer and the drop target accept: whatever
    /// the media providers open, or any file when none registered — the
    /// registry then refuses it with a reported error rather than the panel
    /// refusing silently.
    private var acceptedTypes: [UTType] {
        model.mediaContentTypes.isEmpty ? [.item] : model.mediaContentTypes
    }

    /// The panel: the heading with its Add button, then the list or the
    /// empty state, the whole panel a drop target for files.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.padding)
                .padding(.vertical, 8)
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                LibraryList(items: items, thumbnails: thumbnails, eventBus: model.eventBus) { item in
                    rowMenu(for: item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fileImporter(
            isPresented: $isImporterPresented, allowedContentTypes: acceptedTypes, allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.addMedia(urls: urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.eventBus.tap("libraryDrop.panel", domain: .composition, params: ["count": .int(files.count)])
            Task { await model.addMedia(urls: files) }
            return true
        }
        .quickLookPreview($previewURL)
        .accessibilityLabel(Text("Library", comment: "Heading of the Library panel listing the show's files"))
    }

    /// The heading — **Library** — with the Add Media… button at its
    /// trailing end, the one place media is added.
    private var header: some View {
        HStack {
            Text("Library", comment: "Heading of the Library panel listing the show's files")
                .font(.headline)
            Spacer()
            Button {
                model.eventBus.tap("libraryAddMedia.button", domain: .composition)
                isImporterPresented = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(
                Text(
                    "Add images, movies, or text files to the project",
                    comment: "Tooltip on the Library's Add Media button")
            )
            .accessibilityLabel(Text("Add Media…", comment: "Library button adding files to the project as media"))
        }
    }

    /// What the panel shows with no media: what to add, and that files can
    /// be dropped.
    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Media", comment: "Library empty state title")
            } icon: {
                Image(systemName: "photo.on.rectangle")
            }
        } description: {
            Text(
                "Add images, movies, or text files, or drop them here.",
                comment: "Library empty state description"
            )
        }
    }

    /// A row's context menu: Quick Look, Reveal in Finder, and Remove from
    /// Project — which drops the reference and never deletes the file.
    @ViewBuilder private func rowMenu(for item: LibraryItem) -> some View {
        Button {
            model.eventBus.tap(
                "libraryQuickLook.menuItem", domain: .composition, params: ["id": .string(item.id.rawValue)])
            previewURL = item.url
        } label: {
            Text("Quick Look", comment: "Library row context menu item opening the file in Quick Look")
        }
        .disabled(!item.isAvailable)
        Button {
            model.eventBus.tap(
                "libraryReveal.menuItem", domain: .composition, params: ["id": .string(item.id.rawValue)])
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } label: {
            Text("Reveal in Finder", comment: "Menu item that reveals the file in Finder")
        }
        Divider()
        Button(role: .destructive) {
            model.eventBus.tap(
                "libraryRemoveMedia.menuItem", domain: .composition,
                params: ["id": .string(item.id.rawValue), "name": .string(item.name)])
            Task { await model.removeMedia(item.id) }
        } label: {
            Text("Remove from Project", comment: "Library row context menu item removing the file from the project")
        }
    }
}

/// The one file list every Library tab draws: a thumbnail, the name, and a
/// detail line per row, each row draggable as its input and carrying the
/// tab's context menu.
struct LibraryList<Menu: View>: View {
    /// The rows, in display order.
    let items: [LibraryItem]

    /// The rows' thumbnails.
    let thumbnails: LibraryThumbnails

    /// The event bus a refused thumbnail is traced on.
    let eventBus: EventBus?

    /// The context menu for a row.
    @ViewBuilder let menu: (LibraryItem) -> Menu

    /// The thumbnail's size: a 16:9 picture at a row's height. An instance
    /// constant because a generic type cannot hold a static stored one.
    private let thumbnailSize = CGSize(width: 48, height: 27)

    /// The list.
    var body: some View {
        List(items) { item in
            row(item)
                .draggable(DraggedInput(id: item.inputID))
                .contextMenu { menu(item) }
                // Keyed on the whole row, not its id: a file added from the
                // panel appears a moment before its input registers, and a
                // task keyed on the id alone would have run once for the
                // unavailable row and never again (found on first use,
                // 2026-09-10).
                .task(id: item) { await thumbnails.load(item, reporting: eventBus) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    /// One row: the thumbnail (or the kind's symbol until it arrives), the
    /// name over the detail line, and a warning for a missing file.
    private func row(_ item: LibraryItem) -> some View {
        HStack(spacing: 8) {
            thumbnail(for: item)
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(.rect(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !item.isAvailable {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .help(Text("Missing file", comment: "Tooltip on a Library row whose file is not at its path"))
            }
        }
        .opacity(item.isAvailable ? 1 : 0.6)
    }

    /// The row's picture: the generated thumbnail **fitted whole** inside the
    /// tile on a quiet background — the layer list's letterboxed reading, so
    /// a square photo shows as a square — or the kind's symbol while it is
    /// generated or when there is none.
    private func thumbnail(for item: LibraryItem) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image = thumbnails.images[item.id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.kind.symbol)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The Library rows' thumbnails, generated by Quick Look once per file and
/// kept — display data only, never on the bus.
@Observable
final class LibraryThumbnails {
    /// The generated images by item.
    private(set) var images: [MediaID: CGImage] = [:]

    /// The items whose generation is in flight or done, so a row that
    /// re-appears does not ask twice.
    @ObservationIgnored private var requested: Set<MediaID> = []

    /// The size thumbnails are generated at, in points; the row scales
    /// them down, so 2× the drawn size keeps them crisp on Retina.
    private static let size = CGSize(width: 96, height: 54)

    /// Generates the thumbnail for an item, once. A file Quick Look cannot
    /// thumbnail (missing, or a type with no representation) leaves the
    /// row on its symbol.
    ///
    /// - Parameter item: The row.
    func load(_ item: LibraryItem, reporting eventBus: EventBus?) async {
        guard item.isAvailable, requested.insert(item.id).inserted else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: Self.size, scale: 2, representationTypes: .thumbnail)
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            images[item.id] = representation.cgImage
        } catch {
            // Display data only, so a refusal costs the row its picture and
            // nothing else — but it is worth a trace, since Quick Look says
            // why (a type with no thumbnailer, a file it cannot read).
            eventBus?.trace(
                "library.thumbnail",
                domain: .platform,
                params: ["id": .string(item.id.rawValue), "reason": .string(String(describing: error))]
            )
        }
    }
}
