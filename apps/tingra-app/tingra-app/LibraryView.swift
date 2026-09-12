//
//  LibraryView.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import TingraComposition
import TingraEventBus
import UniformTypeIdentifiers

/// The **Library** panel (GLOSSARY.md): the files a show uses, at the
/// bottom of the trailing sidebar under the layer inspector, in three tabs
/// on a segmented control in its header (ARCHITECTURE.md, "Snapshots" and
/// "The Recordings tab"):
///
/// - **Media** — the project's media files, with Add Media…, drop-to-add,
///   and each row's Quick Look, Reveal in Finder, and Remove from Project
///   ("Media inputs and the Library's Media tab"). A row drags to the shot
///   bank and the layer list as any input row does.
/// - **Snapshots** — the images in the snapshots folder, newest first, with
///   each row's Quick Look, Reveal in Finder, Add to Media, and Move to
///   Trash. A row drags as a file, to the Finder, Mail, or an upload form.
/// - **Recordings** — the movies in the recordings folder, newest first, on
///   the Snapshots tab's terms, with the take being written listed first as
///   its own row: Reveal in Finder only, and no drag, until it is finalized.
///
/// The header's trailing control belongs to the tab: Media keeps Add
/// Media…, and the two file tabs have none, because snapshots and
/// recordings are made, not imported. The tab persists
/// (``LibraryPreferences``), and the panel never switches tabs on its own.
/// Every tab draws ``LibraryList`` over ``LibraryItem`` rows, and selecting
/// a row changes nothing on air.
struct LibraryView: View {
    /// The engine model whose media, snapshots, and recordings the panel
    /// lists and edits.
    let model: EngineModel

    /// Where the tab persists.
    private let preferences: LibraryPreferences

    /// The tab showing.
    @State private var tab: LibraryTab

    /// Whether the Add Media… file importer is up.
    @State private var isImporterPresented = false

    /// The file Quick Look is showing, or nil while it is closed.
    @State private var previewURL: URL?

    /// The rows' read-once facts — thumbnails and lengths — kept for the
    /// panel's lifetime.
    @State private var facts = LibraryFacts()

    /// The Snapshots tab's rows, as last read from the folder.
    @State private var snapshots: [LibraryItem] = []

    /// The Recordings tab's rows, as last read from the folder.
    @State private var recordings: [LibraryItem] = []

    /// The file waiting on the Move to Trash confirmation, or nil while none
    /// is asked about.
    @State private var fileToTrash: LibraryFileOnTab?

    /// Why the last Move to Trash did not happen, or nil while no such alert
    /// is up.
    @State private var trashFailure: LibraryTrashFailure?

    /// The panel's inner padding.
    private static let padding: CGFloat = 12

    /// The width the header's trailing slot keeps whether or not the tab
    /// has a control there, so switching tabs never slides the tab strip.
    private static let trailingControlWidth: CGFloat = 20

    /// Creates the panel.
    ///
    /// - Parameters:
    ///   - model: The engine model.
    ///   - preferences: Where the tab persists (the standard defaults by
    ///     default).
    init(model: EngineModel, preferences: LibraryPreferences = LibraryPreferences()) {
        self.model = model
        self.preferences = preferences
        _tab = State(initialValue: preferences.tab())
    }

    /// The rows for the project's media, in project order.
    private var mediaItems: [LibraryItem] {
        LibraryItem.items(from: model.media, durations: model.mediaDurations, isAvailable: model.isInputAvailable)
    }

    /// The content types the importer and the drop target accept: whatever
    /// the media providers open, or any file when none registered — the
    /// registry then refuses it with a reported error rather than the panel
    /// refusing silently.
    private var acceptedTypes: [UTType] {
        model.mediaContentTypes.isEmpty ? [.item] : model.mediaContentTypes
    }

    /// The panel: the header with its tabs, then the tab's content.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.padding)
                .padding(.vertical, 8)
            Divider()
            switch tab {
            case .media: mediaContent
            case .snapshots: snapshotsContent
            case .recordings: recordingsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fileImporter(
            isPresented: $isImporterPresented, allowedContentTypes: acceptedTypes, allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.addMedia(urls: urls) }
        }
        .quickLookPreview($previewURL)
        .alert(
            Text("Move to Trash?", comment: "Title of the alert confirming a snapshot used as media goes to the Trash"),
            isPresented: isTrashConfirmationPresented,
            presenting: fileToTrash
        ) { pending in
            Button(role: .destructive) {
                model.eventBus.tap(
                    "\(pending.tab.fileTapPrefix)TrashConfirm.button", domain: pending.tab.tapDomain,
                    params: ["file": .string(pending.item.eventID)])
                Task { await trash(pending.item, from: pending.tab) }
            } label: {
                Text("Move to Trash", comment: "Library snapshot context menu item, and its confirmation button")
            }
            Button(role: .cancel) {
                model.eventBus.tap(
                    "\(pending.tab.fileTapPrefix)TrashCancel.button", domain: pending.tab.tapDomain,
                    params: ["file": .string(pending.item.eventID)])
            } label: {
                Text("Cancel", comment: "Cancel button of the alert confirming a snapshot goes to the Trash")
            }
        } message: { pending in
            Text(
                "“\(pending.item.name)” is used as media in this project. Layers showing it will show nothing until it is put back and Tingra is reopened.",
                comment:
                    "Message of the alert confirming a snapshot used as media goes to the Trash; the placeholder is the file's name"
            )
        }
        .alert(
            Text(
                "Couldn’t Move to Trash", comment: "Title of the alert when a snapshot could not be moved to the Trash"),
            isPresented: isTrashFailurePresented,
            presenting: trashFailure
        ) { failure in
            Button {
                model.eventBus.tap("\(failure.tab.fileTapPrefix)TrashError.button", domain: failure.tab.tapDomain)
            } label: {
                Text("OK", comment: "Button dismissing an alert that reports a problem")
            }
        } message: { failure in
            Text(verbatim: failure.reason)
        }
        .accessibilityLabel(Text("Library", comment: "Heading of the Library panel listing the show's files"))
    }

    /// The header: the **Library** heading, the tab strip, then the tab's
    /// own control. When the column is too narrow for all three segments
    /// beside the heading, the heading yields — the panel keeps it as its
    /// accessibility label — and the tab titles are never abbreviated.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showsHeading: true)
            headerRow(showsHeading: false)
        }
    }

    /// One arrangement of the header.
    ///
    /// - Parameter showsHeading: Whether the **Library** heading is drawn.
    private func headerRow(showsHeading: Bool) -> some View {
        HStack(spacing: 8) {
            if showsHeading {
                Text("Library", comment: "Heading of the Library panel listing the show's files")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            Picker(selection: tabSelection) {
                ForEach(LibraryTab.allCases) { tab in
                    tab.title.tag(tab)
                }
            } label: {
                Text("Library", comment: "Heading of the Library panel listing the show's files")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Group {
                if tab == .media {
                    addMediaButton
                }
            }
            .frame(width: Self.trailingControlWidth)
        }
    }

    /// The tab strip's binding: switching reports the click, then persists
    /// the tab.
    private var tabSelection: Binding<LibraryTab> {
        Binding {
            tab
        } set: { newTab in
            model.eventBus.tap("libraryTab.picker", domain: .composition, params: ["tab": .string(newTab.rawValue)])
            tab = newTab
            preferences.setTab(newTab)
        }
    }

    /// The Media tab's Add Media… button, the one place media is added.
    private var addMediaButton: some View {
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

    // MARK: Media

    /// The Media tab: the project's media, or its empty state — the drop
    /// target for files, so a drop never adds media while another tab shows.
    private var mediaContent: some View {
        Group {
            let items = mediaItems
            if items.isEmpty {
                mediaEmptyState
            } else {
                LibraryList(items: items, facts: facts, eventBus: model.eventBus) { item in
                    mediaMenu(for: item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.eventBus.tap("libraryDrop.panel", domain: .composition, params: ["count": .int(files.count)])
            Task { await model.addMedia(urls: files) }
            return true
        }
    }

    /// What the Media tab shows with no media: what to add, and that files
    /// can be dropped.
    private var mediaEmptyState: some View {
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

    /// A media row's context menu: Quick Look, Reveal in Finder, and Remove
    /// from Project — which drops the reference and never deletes the file.
    @ViewBuilder private func mediaMenu(for item: LibraryItem) -> some View {
        Button {
            model.eventBus.tap("libraryQuickLook.menuItem", domain: .composition, params: ["id": .string(item.eventID)])
            previewURL = item.url
        } label: {
            Text("Quick Look", comment: "Library row context menu item opening the file in Quick Look")
        }
        .disabled(!item.isAvailable)
        Button {
            model.eventBus.tap("libraryReveal.menuItem", domain: .composition, params: ["id": .string(item.eventID)])
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } label: {
            Text("Reveal in Finder", comment: "Menu item that reveals the file in Finder")
        }
        Divider()
        Button(role: .destructive) {
            model.eventBus.tap(
                "libraryRemoveMedia.menuItem", domain: .composition,
                params: ["id": .string(item.eventID), "name": .string(item.name)])
            guard let id = item.mediaID else { return }
            Task { await model.removeMedia(id) }
        } label: {
            Text("Remove from Project", comment: "Library row context menu item removing the file from the project")
        }
    }

    // MARK: Snapshots

    /// The Snapshots tab: the folder's images, or its empty state.
    ///
    /// The listing is re-read on events, never by a watcher: when the tab
    /// appears, when the folder or Tingra's own writes change it
    /// (``EngineModel/snapshotRevision``), and when the app becomes active —
    /// a change made in the Finder needs the Finder frontmost first.
    private var snapshotsContent: some View {
        Group {
            if snapshots.isEmpty {
                snapshotsEmptyState
            } else {
                LibraryList(items: snapshots, facts: facts, eventBus: model.eventBus) { item in
                    fileMenu(for: item, on: .snapshots)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: FolderListingKey(folder: model.snapshotFolder, revision: model.snapshotRevision, recording: nil)) {
            reloadSnapshots()
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                reloadSnapshots()
            }
        }
    }

    /// What the Snapshots tab shows with none saved: how to make one.
    private var snapshotsEmptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Snapshots", comment: "Library Snapshots tab empty state title")
            } icon: {
                Image(systemName: "camera.viewfinder")
            }
        } description: {
            Text(
                "Right-click a monitor and choose Save Snapshot, or press ⌥⌘S to save the program.",
                comment: "Library Snapshots tab empty state description"
            )
        }
    }

    /// Reads the snapshots folder into the tab's rows.
    private func reloadSnapshots() {
        snapshots = LibraryItem.snapshots(in: model.snapshotFolder)
    }

    // MARK: Recordings

    /// The Recordings tab: the folder's movies, or its empty state.
    ///
    /// Re-read on the Snapshots tab's events, with the recording's own two
    /// added (``EngineModel/recordingRevision``): a take starting, so its row
    /// appears, and a take finalized, so its row becomes a playable one.
    private var recordingsContent: some View {
        Group {
            if recordings.isEmpty {
                recordingsEmptyState
            } else {
                LibraryList(items: recordings, facts: facts, eventBus: model.eventBus) { item in
                    fileMenu(for: item, on: .recordings)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(
            id: FolderListingKey(
                folder: model.recordingFolder, revision: model.recordingRevision, recording: model.fileBeingRecorded)
        ) {
            reloadRecordings()
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                reloadRecordings()
            }
        }
    }

    /// What the Recordings tab shows with none made: where Record is.
    private var recordingsEmptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Recordings", comment: "Library Recordings tab empty state title")
            } icon: {
                Image(systemName: "record.circle")
            }
        } description: {
            Text(
                "Press Record (⌘R) to record the program.",
                comment: "Library Recordings tab empty state description"
            )
        }
    }

    /// Reads the recordings folder into the tab's rows, marking the take
    /// being written.
    private func reloadRecordings() {
        recordings = LibraryItem.recordings(in: model.recordingFolder, recording: model.fileBeingRecorded)
    }

    // MARK: File tabs

    /// A file row's context menu, shared by the Snapshots and Recordings
    /// tabs: Quick Look, Reveal in Finder, Add to Media — the one route from
    /// a file to a layer, disabled once the file is in the project — and
    /// Move to Trash, confirmed only when the project uses the file as media.
    /// The take being written offers Reveal in Finder alone: it cannot be
    /// previewed, must not become media, and must never be trashed under its
    /// writer.
    ///
    /// - Parameters:
    ///   - item: The row.
    ///   - tab: The tab the row is listed on, which names its taps.
    @ViewBuilder private func fileMenu(for item: LibraryItem, on tab: LibraryTab) -> some View {
        let isMedia = model.mediaItem(forFile: item.url) != nil
        Button {
            model.eventBus.tap(
                "\(tab.fileTapPrefix)QuickLook.menuItem", domain: tab.tapDomain,
                params: ["file": .string(item.eventID)])
            previewURL = item.url
        } label: {
            Text("Quick Look", comment: "Library row context menu item opening the file in Quick Look")
        }
        .disabled(item.isRecording)
        Button {
            model.eventBus.tap(
                "\(tab.fileTapPrefix)Reveal.menuItem", domain: tab.tapDomain, params: ["file": .string(item.eventID)])
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } label: {
            Text("Reveal in Finder", comment: "Menu item that reveals the file in Finder")
        }
        Divider()
        Button {
            model.eventBus.tap(
                "\(tab.fileTapPrefix)AddMedia.menuItem", domain: tab.tapDomain,
                params: ["file": .string(item.eventID)])
            Task { await model.addMedia(urls: [item.url]) }
        } label: {
            Text("Add to Media", comment: "Library snapshot context menu item adding the image to the project as media")
        }
        .disabled(isMedia || item.isRecording)
        Divider()
        Button(role: .destructive) {
            model.eventBus.tap(
                "\(tab.fileTapPrefix)Trash.menuItem", domain: tab.tapDomain,
                params: ["file": .string(item.eventID), "usedAsMedia": .bool(isMedia)])
            if isMedia {
                fileToTrash = LibraryFileOnTab(item: item, tab: tab)
            } else {
                Task { await trash(item, from: tab) }
            }
        } label: {
            Text("Move to Trash", comment: "Library snapshot context menu item, and its confirmation button")
        }
        .disabled(item.isRecording)
    }

    /// Moves a snapshot or a recording to the Trash, reporting a refusal in
    /// an alert.
    ///
    /// - Parameters:
    ///   - item: The file's row.
    ///   - tab: The tab it is listed on, which says whose trash it is.
    private func trash(_ item: LibraryItem, from tab: LibraryTab) async {
        let reason: String?
        switch tab {
        case .recordings:
            reason = await model.trashRecording(at: item.url)
        case .media, .snapshots:
            reason = await model.trashSnapshot(at: item.url)
        }
        trashFailure = reason.map { LibraryTrashFailure(reason: $0, tab: tab) }
    }

    /// Whether the Move to Trash confirmation is up.
    private var isTrashConfirmationPresented: Binding<Bool> {
        Binding {
            fileToTrash != nil
        } set: { presented in
            if !presented { fileToTrash = nil }
        }
    }

    /// Whether the trash-refused alert is up.
    private var isTrashFailurePresented: Binding<Bool> {
        Binding {
            trashFailure != nil
        } set: { presented in
            if !presented { trashFailure = nil }
        }
    }
}

/// What a file tab's listing depends on: the folder, Tingra's own changes to
/// it, and — for recordings — the take being written; the `task(id:)` that
/// re-reads on any of them.
private struct FolderListingKey: Equatable {
    /// The folder the tab lists.
    let folder: URL

    /// The model's revision counter for that folder when the listing was
    /// asked for.
    let revision: Int

    /// The file being recorded, or nil (always nil for snapshots).
    let recording: URL?
}

/// A file row together with the tab it is listed on — what the Move to
/// Trash confirmation needs to name its taps and pick whose trash to call.
private struct LibraryFileOnTab {
    /// The row.
    let item: LibraryItem

    /// The tab it is listed on.
    let tab: LibraryTab
}

/// Why a Move to Trash did not happen, and on which tab — what the
/// Couldn't Move to Trash alert shows and names its tap by.
private struct LibraryTrashFailure {
    /// The reason, in the operator's words.
    let reason: String

    /// The tab the file is listed on.
    let tab: LibraryTab
}

extension LibraryTab {
    /// The stem of a file tab's row taps — `librarySnapshotTrash.menuItem`,
    /// `libraryRecordingReveal.menuItem` — so the two tabs' clicks stay
    /// distinguishable in the log while sharing one menu.
    fileprivate var fileTapPrefix: String {
        switch self {
        case .media: "libraryMedia"
        case .snapshots: "librarySnapshot"
        case .recordings: "libraryRecording"
        }
    }

    /// The domain a tab's row taps belong to: recordings are the output
    /// area's files, the rest composition's (the domains of their events).
    fileprivate var tapDomain: EventDomain {
        self == .recordings ? .output : .composition
    }
}

/// The one file list every Library tab draws: a thumbnail, the name, and a
/// detail line per row, each row draggable — a media row as its input, a
/// file row as its file, the take being written not at all — and carrying
/// the tab's context menu.
struct LibraryList<Menu: View>: View {
    /// The rows, in display order.
    let items: [LibraryItem]

    /// The rows' read-once facts: thumbnails and lengths.
    let facts: LibraryFacts

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
            draggableRow(item)
                .contextMenu { menu(item) }
                // Keyed on the whole row, not its id: a file added from the
                // panel appears a moment before its input registers, and a
                // task keyed on the id alone would have run once for the
                // unavailable row and never again (found on first use,
                // 2026-09-10).
                // The flip from the take being written to a finalized one
                // changes the row too, which is what asks for its facts once
                // the file is playable.
                .task(id: item) { await facts.load(item, reporting: eventBus) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    /// A row with its drag payload, chosen by what the row is: a media row
    /// drags as its input, to the shot bank and the layer list; a file row
    /// drags as the file, to the Finder, Mail, or an upload form — a
    /// snapshot or a take is not an input until it is added as media. The
    /// take being written does not drag: an unfinalized movie handed to Mail
    /// is an unplayable attachment.
    ///
    /// - Parameter item: The row.
    @ViewBuilder private func draggableRow(_ item: LibraryItem) -> some View {
        if item.isRecording {
            row(item)
        } else if let inputID = item.inputID {
            row(item).draggable(DraggedInput(id: inputID))
        } else {
            row(item).draggable(item.url)
        }
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
                Text(item.detail(knownDuration: facts.durations[item.id]))
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
    /// generated or when there is none. The take being written shows the
    /// red record symbol instead, the Record control's own mark.
    private func thumbnail(for item: LibraryItem) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if item.isRecording {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            } else if let image = facts.images[item.id] {
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

/// The Library rows' read-once display facts: each file's thumbnail,
/// generated by Quick Look, and a movie file's length, read from the asset —
/// asked for once per file and kept, display data only, never on the bus
/// except as a trace when a file refuses (ARCHITECTURE.md, "The Recordings
/// tab"). It was `LibraryThumbnails` until the Recordings tab needed a
/// take's length beside its picture.
@Observable
final class LibraryFacts {
    /// The generated images by item.
    private(set) var images: [LibraryItem.Identity: CGImage] = [:]

    /// The measured lengths, in seconds, by item — for rows that do not
    /// carry their own (a media movie's comes from the model).
    private(set) var durations: [LibraryItem.Identity: TimeInterval] = [:]

    /// The items whose facts are in flight or done, so a row that
    /// re-appears does not ask twice.
    @ObservationIgnored private var requested: Set<LibraryItem.Identity> = []

    /// How a movie file's length is read (the asset by default; a stub under
    /// test, so no movie has to be encoded to test the rule).
    @ObservationIgnored private let durationOf: (URL) async -> TimeInterval?

    /// The size thumbnails are generated at, in points; the row scales
    /// them down, so 2× the drawn size keeps them crisp on Retina.
    private static let size = CGSize(width: 96, height: 54)

    /// Creates an empty cache.
    ///
    /// - Parameter durationOf: How a movie file's length is read, nil when it
    ///   cannot be.
    init(durationOf: @escaping (URL) async -> TimeInterval? = LibraryFacts.assetDuration(of:)) {
        self.durationOf = durationOf
    }

    /// A movie file's length from its asset, or nil for a file AVFoundation
    /// cannot open or whose length is not a number.
    ///
    /// - Parameter url: The movie file.
    /// - Returns: The length in seconds, or nil.
    static func assetDuration(of url: URL) async -> TimeInterval? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else {
            return nil
        }
        return duration.seconds
    }

    /// Reads an item's facts, once: its thumbnail and, for a movie that
    /// carries no length of its own, its length. A missing file and the take
    /// being written are not asked at all — the take is not yet playable, and
    /// asking would remember a refusal — so each is asked when its row
    /// changes to one that can answer. A file Quick Look cannot thumbnail
    /// leaves the row on its symbol.
    ///
    /// - Parameters:
    ///   - item: The row.
    ///   - eventBus: Where a refusal is traced.
    func load(_ item: LibraryItem, reporting eventBus: EventBus?) async {
        guard item.isAvailable, !item.isRecording, requested.insert(item.id).inserted else { return }
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
                params: ["id": .string(item.eventID), "reason": .string(String(describing: error))]
            )
        }
        guard item.kind == .movie, item.duration == nil else { return }
        if let seconds = await durationOf(item.url) {
            durations[item.id] = seconds
        } else {
            eventBus?.trace("library.duration", domain: .platform, params: ["id": .string(item.eventID)])
        }
    }
}
