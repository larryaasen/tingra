//
//  AppDataStore.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost
import TingraPlugInKit

/// One kind of data Tingra writes to this Mac — the closed list the Data
/// settings pane inventories and Remove All Data clears.
///
/// A closed list rather than a scan of the file system, because the point is
/// to say **what** each thing is: an operator deciding whether to start over
/// needs to know that one file is the show and another is the log counter.
/// Every place the app persists has an entry here, and a new place that does
/// not add one is a place the pane cannot list — the rule ``SettingsPane``
/// follows for panes.
enum AppDataKind: String, CaseIterable, Identifiable, Sendable {
    /// The project document — the show: presets, shots, layers, and audio
    /// channels (``ProjectStore``), with the `.unreadable` sibling the app
    /// sets an undecodable document aside as.
    case project

    /// The operator's saved destinations — names and URLs, never keys
    /// (`DestinationStore`, DESTINATIONS.md).
    case destinations

    /// The stream keys, one Keychain item per destination that has one
    /// (`SecureStorage`).
    case streamKeys

    /// Machine-local preferences in the app's `UserDefaults` domain:
    /// appearance, the status bar, the monitor output, the recording folder
    /// and format, the sidebar's sections, the operator's last position
    /// (``SessionPreferences``), and the window positions the system stores
    /// there.
    case preferences

    /// The log session counter the host increments once per launch
    /// (`LogSession`).
    case logSession

    /// The log file the host's file sink appends every event to
    /// (`LogFile`), listed so the pane is complete and **kept** by Remove
    /// All Data — the record of what the app did, the removal and the quit
    /// included, is what a first-run check wants to read.
    case logFile

    /// The recordings in the recordings folder — the operator's work, listed
    /// so the pane is complete, and **kept** by Remove All Data.
    case recordings

    /// The kind itself, for `ForEach`.
    var id: Self { self }

    /// Whether Remove All Data removes this kind.
    ///
    /// Everything but the recordings and the log file. A recording is the
    /// show the operator made, not the app's state about it, and "the state
    /// before the app was ever used" is a state with no settings and no
    /// project — it says nothing about deleting the operator's movies. The
    /// log is the record of what the app did, the removal and the quit that
    /// follows included, which is exactly what a developer checking a first
    /// run by hand wants to read — and the file sink would recreate it on the
    /// very next event regardless (EVENTS.md, "File sink").
    var isRemovable: Bool {
        switch self {
        case .recordings, .logFile: false
        case .project, .destinations, .streamKeys, .preferences, .logSession: true
        }
    }
}

/// What ``AppDataStore`` found of one kind: how much, and where.
struct AppDataItem: Equatable, Identifiable, Sendable {
    /// The kind of data.
    let kind: AppDataKind

    /// How many there are — files for the documents, the counter, and the
    /// recordings; items for the stream keys; entries for the preferences.
    /// Zero means nothing of this kind is saved.
    let count: Int

    /// Bytes on disk, summed over the files, or `nil` where a size is not
    /// the app's to read (the Keychain reports none).
    let byteCount: Int64?

    /// Where it lives, as the operator would find it — the folder for the
    /// documents, the counter, and the recordings, the file for the
    /// preferences, with the home folder abbreviated to `~`; or the Keychain.
    let location: String

    /// The folder ``location`` names, when it is a folder that exists — what
    /// the pane opens in the Finder on a click. Nil for the Keychain, for the
    /// preferences file, and for a folder not yet on disk.
    let folderURL: URL?

    /// The kind, for `ForEach`.
    var id: AppDataKind { kind }

    /// Whether nothing of this kind is saved.
    var isEmpty: Bool { count == 0 }
}

/// One kind Remove All Data could not clear, with the reason as the
/// operator should read it.
struct AppDataRemovalFailure: Equatable, Identifiable, Sendable {
    /// The kind that was not removed.
    let kind: AppDataKind

    /// Why, in the operator's words — a file-system error's own description,
    /// or the secure store's.
    let reason: String

    /// The kind, for `ForEach`.
    var id: AppDataKind { kind }
}

/// Where everything Tingra saves on this Mac is, how much of it there is,
/// and how to remove it — the store behind the Data settings pane.
///
/// **Injected paths, not `Bundle.main` and `.standard` read here**, so a
/// test runs the real inventory and the real removal against a temporary
/// directory and a throwaway defaults suite, never the operator's own show.
/// The production store is built by ``EngineModel`` from the same
/// ``ProjectStore``, `DestinationStore`, and `SecureStorage` the engine
/// itself writes through, so what the pane lists and what the engine saves
/// cannot name different files.
///
/// **Removal is per kind and never stops early.** Each kind is attempted and
/// its own failure recorded (``AppDataRemovalFailure``), so a Keychain that
/// refuses this binary does not leave the project document in place, and
/// the operator is told exactly which kind is still there. The store never
/// throws and never traps (CLAUDE.md, "Never crash the process").
///
/// The Application Support directory itself is removed only if it is empty
/// afterwards — the daemon's socket lives there too, and a socket is not the
/// app's data to delete.
struct AppDataStore {
    /// The project document's store — its file, its `.unreadable` sibling,
    /// and the directory both share with the destinations and the counter.
    let projectStore: ProjectStore

    /// The destinations document.
    let destinationsFileURL: URL

    /// The log session counter file.
    let logSessionFileURL: URL

    /// The log file.
    let logFileURL: URL

    /// The preferences, read through the same `UserDefaults` the app's
    /// preference types write.
    let defaults: UserDefaults

    /// The preferences domain those defaults persist under — the app's
    /// bundle identifier in production, a throwaway suite name in tests.
    let defaultsDomain: String

    /// The secret store holding the stream keys.
    let secureStorage: any SecureStorage

    /// The recordings folder, read at inventory time because the operator can
    /// change it in the recording panel.
    let recordingFolder: () -> URL

    /// Creates a store over the places the app writes.
    ///
    /// - Parameters:
    ///   - projectStore: The project document's store.
    ///   - destinationsFileURL: The destinations document.
    ///   - logSessionFileURL: The log session counter file.
    ///   - logFileURL: The log file.
    ///   - defaults: The preferences.
    ///   - defaultsDomain: The domain those preferences persist under.
    ///   - secureStorage: The secret store holding the stream keys.
    ///   - recordingFolder: The recordings folder, read at inventory time.
    init(
        projectStore: ProjectStore,
        destinationsFileURL: URL,
        logSessionFileURL: URL,
        logFileURL: URL,
        defaults: UserDefaults,
        defaultsDomain: String,
        secureStorage: any SecureStorage,
        recordingFolder: @escaping () -> URL
    ) {
        self.projectStore = projectStore
        self.destinationsFileURL = destinationsFileURL
        self.logSessionFileURL = logSessionFileURL
        self.logFileURL = logFileURL
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
        self.secureStorage = secureStorage
        self.recordingFolder = recordingFolder
    }

    /// The `.unreadable` sibling ``ProjectStore/setAsideUnreadableFile()``
    /// moves an undecodable document to.
    var unreadableProjectFileURL: URL { projectStore.fileURL.appendingPathExtension("unreadable") }

    /// The preferences' backing file — where `cfprefsd` keeps a domain — for
    /// the size on disk. The entries themselves are read through
    /// ``defaults``, since the file can lag a write.
    var preferencesFileURL: URL {
        URL.libraryDirectory.appending(path: "Preferences").appending(path: "\(defaultsDomain).plist")
    }

    /// Everything the app has saved, one item per ``AppDataKind`` in the
    /// kinds' declared order — an empty kind is listed with a count of zero
    /// rather than omitted, so the pane always shows the whole picture.
    ///
    /// - Returns: The inventory.
    func inventory() -> [AppDataItem] {
        AppDataKind.allCases.map { kind in
            switch kind {
            case .project:
                return fileItem(
                    kind, files: [projectStore.fileURL, unreadableProjectFileURL], folder: projectStore.directoryURL)
            case .destinations:
                return fileItem(
                    kind, files: [destinationsFileURL], folder: destinationsFileURL.deletingLastPathComponent())
            case .streamKeys:
                // A store that refuses the read counts as holding nothing
                // here; the removal path is the one that reports a refusal.
                return AppDataItem(
                    kind: kind,
                    count: (try? secureStorage.accounts())?.count ?? 0,
                    byteCount: nil,
                    location: String(localized: "Keychain", comment: "Data settings: where the stream keys are stored"),
                    folderURL: nil
                )
            case .preferences:
                return AppDataItem(
                    kind: kind,
                    count: defaults.persistentDomain(forName: defaultsDomain)?.count ?? 0,
                    byteCount: Self.fileSize(of: preferencesFileURL),
                    location: Self.abbreviatedPath(of: preferencesFileURL),
                    folderURL: nil
                )
            case .logSession:
                return fileItem(kind, files: [logSessionFileURL], folder: logSessionFileURL.deletingLastPathComponent())
            case .logFile:
                return fileItem(kind, files: [logFileURL], folder: logFileURL.deletingLastPathComponent())
            case .recordings:
                let folder = recordingFolder()
                return fileItem(kind, files: Self.recordings(in: folder), folder: folder)
            }
        }
    }

    /// Removes every removable kind, each on its own, and says which could
    /// not be removed.
    ///
    /// - Returns: The kinds that were not removed, with the reason each; an
    ///   empty list means everything is gone.
    func removeAll() -> [AppDataRemovalFailure] {
        var failures: [AppDataRemovalFailure] = []
        for kind in AppDataKind.allCases where kind.isRemovable {
            do {
                try remove(kind)
            } catch {
                failures.append(AppDataRemovalFailure(kind: kind, reason: Self.reason(for: error)))
            }
        }
        removeSupportDirectoryIfEmpty()
        return failures
    }

    /// Removes one kind.
    ///
    /// - Parameter kind: The kind to remove; ``AppDataKind/recordings`` and
    ///   ``AppDataKind/logFile`` are never removed and are no-ops here.
    /// - Throws: The file-system or secure-store error that stopped it.
    private func remove(_ kind: AppDataKind) throws {
        switch kind {
        case .project:
            try Self.removeIfPresent(projectStore.fileURL)
            try Self.removeIfPresent(unreadableProjectFileURL)
        case .destinations:
            try Self.removeIfPresent(destinationsFileURL)
        case .streamKeys:
            try secureStorage.removeAllSecrets()
        case .preferences:
            defaults.removePersistentDomain(forName: defaultsDomain)
        case .logSession:
            try Self.removeIfPresent(logSessionFileURL)
        case .recordings, .logFile:
            break
        }
    }

    /// Removes the Application Support directory when nothing is left in it,
    /// so a first run finds no folder — and leaves it when anything remains
    /// (the daemon's socket, a file the operator put there). Best effort: a
    /// leftover empty folder is not data, so a failure here is not reported.
    private func removeSupportDirectoryIfEmpty() {
        let directory = projectStore.directoryURL
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
            contents.isEmpty
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// An item over a set of files in one folder, counting and sizing those
    /// that exist, located by the folder — openable while it is on disk.
    ///
    /// - Parameters:
    ///   - kind: The kind.
    ///   - files: The files that make up the kind.
    ///   - folder: The folder holding them.
    /// - Returns: The item.
    private func fileItem(_ kind: AppDataKind, files: [URL], folder: URL) -> AppDataItem {
        let sizes = files.compactMap(Self.fileSize(of:))
        var isDirectory: ObjCBool = false
        let folderExists =
            FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
        return AppDataItem(
            kind: kind,
            count: sizes.count,
            byteCount: sizes.isEmpty ? nil : sizes.reduce(0, +),
            location: Self.abbreviatedPath(of: folder),
            folderURL: folderExists ? folder : nil
        )
    }

    /// The recordings in a folder: the files ``RecordingFilename`` names —
    /// the `Tingra` stem in one of the recording containers — and nothing
    /// else the operator keeps in the same folder.
    ///
    /// - Parameter folder: The recordings folder.
    /// - Returns: The recordings, or none for a folder that does not exist.
    static func recordings(in folder: URL) -> [URL] {
        let extensions = Set(RecordingFile.Container.allCases.map(\.rawValue))
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return
            contents
            .filter { extensions.contains($0.pathExtension) }
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix("\(RecordingFilename.prefix) ") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A file's size in bytes, or `nil` when there is no such file.
    ///
    /// Read through `FileManager` rather than `URL.resourceValues`, which
    /// caches what it read for the rest of the run-loop pass — an inventory
    /// taken just before a removal would otherwise report the removed file's
    /// size again right after it.
    ///
    /// - Parameter url: The file.
    /// - Returns: Its size, or `nil`.
    static func fileSize(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard let size = attributes?[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// A path with the home folder abbreviated to `~`, the way the Finder's
    /// Go to Folder and Terminal write it.
    ///
    /// - Parameter url: The file or folder.
    /// - Returns: Its path for display.
    static func abbreviatedPath(of url: URL) -> String {
        // A directory URL's path ends in a slash; the operator's paths do not.
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        var home = URL.homeDirectory.path(percentEncoded: false)
        while home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty, path.hasPrefix(home + "/") || path == home else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Removes a file if it exists; a missing file is not an error, so
    /// removal is idempotent.
    ///
    /// - Parameter url: The file.
    /// - Throws: The file-system error when the file exists and cannot be
    ///   removed.
    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// An error as the operator should read it: the secure store's own
    /// developer-facing description (its `localizedDescription` is the generic
    /// Foundation one), otherwise the system's localized description.
    ///
    /// - Parameter error: The error.
    /// - Returns: The reason to show.
    private static func reason(for error: any Error) -> String {
        if let error = error as? SecureStorageError { return error.description }
        return error.localizedDescription
    }
}
