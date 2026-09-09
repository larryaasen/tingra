//
//  AppDataStoreTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraComposition
import TingraHost
import TingraPlugInKit

@testable import TingraApp

/// An in-memory `SecureStorage`, with a switch that makes the clear refuse —
/// the stand-in for a Keychain that rejects this binary, which a test cannot
/// otherwise reach.
final class InMemorySecureStorage: SecureStorage {
    /// The stored secrets, keyed by account.
    private let secrets = Mutex<[String: String]>([:])

    /// The error ``removeAllSecrets()`` throws, or nil to clear normally.
    private let clearFailure: SecureStorageError?

    /// Creates a double.
    ///
    /// - Parameter clearFailure: An error the clear throws, or nil.
    init(clearFailure: SecureStorageError? = nil) {
        self.clearFailure = clearFailure
    }

    func setSecret(_ secret: String, forAccount account: String) throws {
        secrets.withLock { $0[account] = secret }
    }

    func secret(forAccount account: String) throws -> String? {
        secrets.withLock { $0[account] }
    }

    func removeSecret(forAccount account: String) throws {
        secrets.withLock { $0[account] = nil }
    }

    func accounts() throws -> [String] {
        secrets.withLock { $0.keys.sorted() }
    }

    func removeAllSecrets() throws {
        if let clearFailure { throw clearFailure }
        secrets.withLock { $0.removeAll() }
    }
}

/// A store over a temporary directory, a throwaway defaults suite, and an
/// in-memory secret store — everything the real store touches, none of it
/// the operator's.
@MainActor
struct AppDataFixture {
    /// The Application Support stand-in.
    let supportDirectory: URL

    /// The recordings folder stand-in.
    let recordingsFolder: URL

    /// The throwaway defaults suite.
    let defaults: UserDefaults

    /// The suite's name, its persistence domain.
    let domain: String

    /// The secret store.
    let secureStorage: InMemorySecureStorage

    /// The store under test.
    let store: AppDataStore

    /// Creates the fixture, with the directories not yet on disk — a fresh
    /// install.
    ///
    /// - Parameter clearFailure: An error the secret store's clear throws.
    init(clearFailure: SecureStorageError? = nil) throws {
        let root = URL.temporaryDirectory.appending(path: "tingra-appdata-\(UUID().uuidString)")
        supportDirectory = root.appending(path: "Tingra")
        recordingsFolder = root.appending(path: "Movies")
        domain = "tingra.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: domain))
        secureStorage = InMemorySecureStorage(clearFailure: clearFailure)
        let projectStore = ProjectStore(directory: supportDirectory)
        let folder = recordingsFolder
        store = AppDataStore(
            projectStore: projectStore,
            destinationsFileURL: supportDirectory.appending(path: "destinations.json"),
            logSessionFileURL: supportDirectory.appending(path: "log-session-id"),
            logFileURL: root.appending(path: "Logs/Tingra/Tingra.log"),
            defaults: defaults,
            defaultsDomain: domain,
            secureStorage: secureStorage,
            recordingFolder: { folder }
        )
    }

    /// Removes everything the fixture put on disk.
    func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: supportDirectory.deletingLastPathComponent())
    }

    /// Writes a file with the given number of bytes.
    ///
    /// - Parameters:
    ///   - url: The file.
    ///   - byteCount: How many bytes to write.
    func write(_ url: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: byteCount).write(to: url)
    }

    /// Whether a file exists.
    ///
    /// - Parameter url: The file.
    /// - Returns: Whether it is on disk.
    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// A one-preset project, for the project document.
    var sampleProject: Project {
        Project(
            presets: [
                Preset(
                    id: PresetID(rawValue: "default"),
                    name: "Default",
                    shots: [
                        Shot(
                            id: ShotID(rawValue: "full"),
                            name: "Full",
                            layers: ProgramLayout.layers(
                                displayID: InputID(rawValue: "display-1"),
                                cameraID: InputID(rawValue: "camera-1")
                            )
                        )
                    ]
                )
            ],
            destinations: []
        )
    }
}

/// Exercises the Data settings pane's store: what it counts, what it sizes,
/// what it removes, what it keeps, and how a refusal is reported.
@MainActor
@Suite("AppDataStore")
struct AppDataStoreTests {
    @Test("a fresh install lists every kind as empty, in the kinds' declared order")
    func freshInstallIsEmpty() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }

        let items = fixture.store.inventory()
        #expect(items.map(\.kind) == AppDataKind.allCases)
        for item in items {
            #expect(item.count == 0, "\(item.kind)")
            #expect(item.byteCount == nil, "\(item.kind)")
            #expect(item.isEmpty)
        }
    }

    @Test("the project document is counted with its unreadable sibling and sized as their sum")
    func projectDocumentCountsBothFiles() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        try fixture.store.projectStore.save(fixture.sampleProject)
        let documentSize = try #require(AppDataStore.fileSize(of: fixture.store.projectStore.fileURL))
        try fixture.write(fixture.store.unreadableProjectFileURL, byteCount: 10)

        let item = try #require(fixture.store.inventory().first { $0.kind == .project })
        #expect(item.count == 2)
        #expect(item.byteCount == documentSize + 10)
        #expect(item.location == fixture.supportDirectory.path(percentEncoded: false))
        #expect(item.folderURL?.standardizedFileURL == fixture.supportDirectory.standardizedFileURL)
    }

    @Test("a folder not yet on disk is named but not openable, and the Keychain and preferences never are")
    func missingFolderIsNotOpenable() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }

        let items = fixture.store.inventory()
        for item in items {
            #expect(item.folderURL == nil, "\(item.kind)")
        }
        let project = try #require(items.first { $0.kind == .project })
        #expect(project.location == fixture.supportDirectory.path(percentEncoded: false))

        try fixture.write(fixture.store.logSessionFileURL, byteCount: 3)
        let after = fixture.store.inventory()
        #expect(after.first { $0.kind == .logSession }?.folderURL != nil)
        #expect(after.first { $0.kind == .destinations }?.folderURL != nil)
        #expect(after.first { $0.kind == .preferences }?.folderURL == nil)
        #expect(after.first { $0.kind == .streamKeys }?.folderURL == nil)
    }

    @Test("the destinations document and the log counter are counted from their files")
    func destinationsAndCounterAreCounted() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        try fixture.write(fixture.store.destinationsFileURL, byteCount: 120)
        try fixture.write(fixture.store.logSessionFileURL, byteCount: 3)

        let items = fixture.store.inventory()
        let destinations = try #require(items.first { $0.kind == .destinations })
        #expect(destinations.count == 1)
        #expect(destinations.byteCount == 120)
        let counter = try #require(items.first { $0.kind == .logSession })
        #expect(counter.count == 1)
        #expect(counter.byteCount == 3)
    }

    @Test("stream keys are counted from the secret store's accounts, with no size")
    func streamKeysAreCountedNotSized() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        try fixture.secureStorage.setSecret("live_a", forAccount: "a")
        try fixture.secureStorage.setSecret("live_b", forAccount: "b")

        let item = try #require(fixture.store.inventory().first { $0.kind == .streamKeys })
        #expect(item.count == 2)
        #expect(item.byteCount == nil)
        #expect(!item.location.contains("live_"))
    }

    @Test("preferences are counted from the defaults domain")
    func preferencesAreCounted() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        fixture.defaults.set("dark", forKey: "appearance.mode")
        fixture.defaults.set(true, forKey: "statusBar.visible")
        fixture.defaults.set(0.5, forKey: "monitor.level")

        let item = try #require(fixture.store.inventory().first { $0.kind == .preferences })
        #expect(item.count == 3)
        #expect(item.location.hasSuffix("\(fixture.domain).plist"))
    }

    @Test("recordings count only Tingra's movies in the folder, and are kept by remove all")
    func recordingsAreCountedAndKept() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        let kept = [
            fixture.recordingsFolder.appending(path: "Tingra 2026-09-07 10.00.00.mov"),
            fixture.recordingsFolder.appending(path: "Tingra 2026-09-07 10.00.00 2.mp4"),
        ]
        let ignored = [
            fixture.recordingsFolder.appending(path: "Holiday.mov"),
            fixture.recordingsFolder.appending(path: "Tingra notes.txt"),
            fixture.recordingsFolder.appending(path: "Tingrafied.mov"),
        ]
        for url in kept { try fixture.write(url, byteCount: 1000) }
        for url in ignored { try fixture.write(url, byteCount: 5) }

        let item = try #require(fixture.store.inventory().first { $0.kind == .recordings })
        #expect(item.count == 2)
        #expect(item.byteCount == 2000)
        #expect(item.location == fixture.recordingsFolder.path(percentEncoded: false).replacing(/\/$/, with: ""))
        #expect(item.folderURL?.standardizedFileURL == fixture.recordingsFolder.standardizedFileURL)
        #expect(
            AppDataStore.recordings(in: fixture.recordingsFolder).map(\.lastPathComponent).sorted()
                == kept.map(\.lastPathComponent).sorted())

        #expect(fixture.store.removeAll().isEmpty)
        for url in kept + ignored {
            #expect(fixture.exists(url), Comment(rawValue: url.lastPathComponent))
        }
        #expect(!AppDataKind.recordings.isRemovable)
        #expect(!AppDataKind.logFile.isRemovable)
        #expect(
            AppDataKind.allCases.filter(\.isRemovable) == [
                .project, .destinations, .streamKeys, .preferences, .logSession,
            ])
    }

    @Test("the log file is counted from its file, located by its folder, and kept by remove all")
    func logFileCountedAndKept() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        try fixture.write(fixture.store.logFileURL, byteCount: 40)

        let item = try #require(fixture.store.inventory().first { $0.kind == .logFile })
        #expect(item.count == 1)
        #expect(item.byteCount == 40)
        #expect(item.location.hasSuffix("/Logs/Tingra"))
        #expect(
            item.folderURL?.standardizedFileURL
                == fixture.store.logFileURL.deletingLastPathComponent().standardizedFileURL)

        #expect(fixture.store.removeAll().isEmpty)
        #expect(fixture.exists(fixture.store.logFileURL))
        #expect(fixture.store.inventory().first { $0.kind == .logFile }?.byteCount == 40)
    }

    @Test("remove all clears every removable kind, removes the emptied support directory, and reports nothing")
    func removeAllClearsEverything() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        try fixture.store.projectStore.save(fixture.sampleProject)
        try fixture.write(fixture.store.unreadableProjectFileURL, byteCount: 10)
        try fixture.write(fixture.store.destinationsFileURL, byteCount: 120)
        try fixture.write(fixture.store.logSessionFileURL, byteCount: 3)
        try fixture.secureStorage.setSecret("live_a", forAccount: "a")
        fixture.defaults.set("dark", forKey: "appearance.mode")

        let failures = fixture.store.removeAll()

        #expect(failures.isEmpty)
        #expect(!fixture.exists(fixture.store.projectStore.fileURL))
        #expect(!fixture.exists(fixture.store.unreadableProjectFileURL))
        #expect(!fixture.exists(fixture.store.destinationsFileURL))
        #expect(!fixture.exists(fixture.store.logSessionFileURL))
        #expect(try fixture.secureStorage.accounts().isEmpty)
        #expect(fixture.defaults.persistentDomain(forName: fixture.domain) == nil)
        #expect(!fixture.exists(fixture.supportDirectory))
        for item in fixture.store.inventory() {
            #expect(item.isEmpty, "\(item.kind)")
        }
    }

    @Test("remove all leaves the support directory when something not the app's is still in it")
    func removeAllKeepsSharedDirectory() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        try fixture.store.projectStore.save(fixture.sampleProject)
        let socket = fixture.supportDirectory.appending(path: "tingra.sock")
        try fixture.write(socket, byteCount: 0)

        #expect(fixture.store.removeAll().isEmpty)
        #expect(!fixture.exists(fixture.store.projectStore.fileURL))
        #expect(fixture.exists(socket))
        #expect(fixture.exists(fixture.supportDirectory))
    }

    @Test("a secret store that refuses the clear is reported by kind, and every other kind still goes")
    func refusedClearIsReportedAndOthersProceed() throws {
        let fixture = try AppDataFixture(clearFailure: .keychain(-34018))
        defer { fixture.tearDown() }
        try fixture.store.projectStore.save(fixture.sampleProject)
        try fixture.secureStorage.setSecret("live_a", forAccount: "a")
        fixture.defaults.set("dark", forKey: "appearance.mode")

        let failures = fixture.store.removeAll()

        #expect(failures.map(\.kind) == [.streamKeys])
        #expect(failures.first?.reason == SecureStorageError.keychain(-34018).description)
        #expect(!fixture.exists(fixture.store.projectStore.fileURL))
        #expect(fixture.defaults.persistentDomain(forName: fixture.domain) == nil)
        #expect(try fixture.secureStorage.accounts() == ["a"])
    }

    @Test("remove all on a fresh install removes nothing and reports nothing")
    func removeAllOnFreshInstallIsQuiet() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }

        #expect(fixture.store.removeAll().isEmpty)
        #expect(fixture.store.removeAll().isEmpty)
    }

    @Test("a path under the home folder is shown with a tilde, and one outside it as is")
    func pathsAbbreviateHome() {
        let home = URL.homeDirectory
        #expect(
            AppDataStore.abbreviatedPath(of: home.appending(path: "Library/Application Support/Tingra/x"))
                == "~/Library/Application Support/Tingra/x")
        #expect(AppDataStore.abbreviatedPath(of: home) == "~")
        #expect(AppDataStore.abbreviatedPath(of: URL(filePath: "/Volumes/Show/x")) == "/Volumes/Show/x")
        // A sibling of the home folder that merely shares its prefix is not
        // inside it.
        let sibling = URL(filePath: home.path(percentEncoded: false).replacing(/\/$/, with: "") + "2/x")
        #expect(!AppDataStore.abbreviatedPath(of: sibling).hasPrefix("~"))
    }

    @Test("the amount reads None when empty, the count alone for keys, and count with size for files")
    func amountsRead() {
        let empty = AppDataItem(kind: .project, count: 0, byteCount: nil, location: "x", folderURL: nil)
        #expect(AppDataRow.amount(of: empty) == "None")

        let keys = AppDataItem(kind: .streamKeys, count: 2, byteCount: nil, location: "Keychain", folderURL: nil)
        let keysAmount = AppDataRow.amount(of: keys)
        #expect(keysAmount.contains("2"))
        #expect(!keysAmount.contains(","))

        let files = AppDataItem(kind: .recordings, count: 3, byteCount: 4096, location: "x", folderURL: nil)
        let filesAmount = AppDataRow.amount(of: files)
        #expect(filesAmount.contains("3"))
        #expect(filesAmount.contains(","))
        #expect(filesAmount.contains(Int64(4096).formatted(.byteCount(style: .file))))
    }
}
