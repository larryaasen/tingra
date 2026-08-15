//
//  DestinationStoreTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-08-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraHost

/// A temporary directory that stands in for `~/Library/Application
/// Support/Tingra`, so every test writes a real destinations file and never
/// the operator's own (DESTINATIONS.md: the store is operator state).
private final class TemporaryDirectory {
    /// The directory's location.
    let url: URL

    /// Creates (and makes) a unique temporary directory.
    init() throws {
        url = URL.temporaryDirectory.appending(path: "tingra-destinations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Removes the directory and everything in it when the test's fixture
    /// goes out of scope.
    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A store over a temporary directory, its in-memory secret store, and the
/// bus its change events land on — the four things nearly every test needs.
private final class Fixture {
    /// The temporary directory, retained so it outlives the store and is
    /// removed when the test ends.
    private let directory: TemporaryDirectory

    /// The store's secret store, read directly to assert on filed keys.
    let secureStorage: InMemorySecureStorage

    /// The change events the store emitted.
    let events: CollectedEvents

    /// The task draining the bus into ``events``.
    private let eventsTask: Task<Void, Never>

    /// The store under test.
    let store: DestinationStore

    /// The destinations file's location, read once so tests reach it without
    /// hopping onto the store's actor.
    let fileURL: URL

    /// Builds a fixture.
    ///
    /// - Parameter readFailure: An error the secret store's reads throw, or
    ///   nil for one that reads normally.
    init(readFailure: SecureStorageError? = nil) throws {
        directory = try TemporaryDirectory()
        secureStorage = InMemorySecureStorage(readFailure: readFailure)
        let eventBus = EventBus()
        events = CollectedEvents()
        eventsTask = events.consume(eventBus.events())
        store = DestinationStore(directory: directory.url, secureStorage: secureStorage, eventBus: eventBus)
        fileURL = directory.url.appending(path: DestinationStore.fileName)
    }

    deinit {
        eventsTask.cancel()
    }
}

/// A destination fixed to one id, so a test can assert on both the record and
/// its secure-storage account.
private func makeDestination(
    id: String = "dest-1",
    name: String = "Twitch",
    url: String = "rtmp://live.twitch.tv/app"
) -> StoredDestination {
    StoredDestination(id: DestinationID(rawValue: id), name: name, url: URL(string: url) ?? URL.temporaryDirectory)
}

@Suite("StoredDestination")
struct StoredDestinationTests {
    @Test("a destination round-trips through JSON unchanged")
    func roundTrips() throws {
        let destination = makeDestination()
        let data = try JSONEncoder().encode(destination)
        #expect(try JSONDecoder().decode(StoredDestination.self, from: data) == destination)
    }

    @Test("the encoded keys are the documented camelCase contract, and hold no key material")
    func encodedKeys() throws {
        let data = try JSONEncoder().encode(makeDestination())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name", "url"])
    }

    @Test("decoding without an id throws keyNotFound")
    func missingIdThrows() throws {
        let json = Data(#"{"name":"Twitch","url":"rtmp://live.twitch.tv/app"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StoredDestination.self, from: json)
        }
    }

    @Test("decoding without a name throws keyNotFound")
    func missingNameThrows() throws {
        let json = Data(#"{"id":"dest-1","url":"rtmp://live.twitch.tv/app"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StoredDestination.self, from: json)
        }
    }

    @Test("decoding without a url throws keyNotFound")
    func missingURLThrows() throws {
        let json = Data(#"{"id":"dest-1","name":"Twitch"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StoredDestination.self, from: json)
        }
    }

    @Test("two destinations with the same id, name, and url are equal")
    func equalDestinations() {
        #expect(makeDestination() == makeDestination())
    }

    @Test("destinations differing in any field are not equal")
    func unequalDestinations() {
        #expect(makeDestination() != makeDestination(id: "dest-2"))
        #expect(makeDestination() != makeDestination(name: "YouTube"))
        #expect(makeDestination() != makeDestination(url: "rtmp://other.example/app"))
    }
}

@Suite("DestinationStore")
struct DestinationStoreTests {

    // MARK: - Reading and writing

    @Test("a store with no file yet is empty")
    func emptyStore() async throws {
        let fixture = try Fixture()
        #expect(try await fixture.store.destinations().isEmpty)
    }

    @Test("an added destination reads back from the file")
    func addAndRead() async throws {
        let fixture = try Fixture()
        let destination = makeDestination()

        try await fixture.store.add(destination)

        #expect(try await fixture.store.destinations() == [destination])
        #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path(percentEncoded: false)))
    }

    @Test("destinations are read from the file every time, so another process's edit is seen")
    func readsThroughToTheFile() async throws {
        let fixture = try Fixture()
        try await fixture.store.add(makeDestination())

        // Stand in for the app editing the document while the daemon holds
        // its own store: rewrite the file behind the store's back.
        let renamed = makeDestination(name: "Twitch main")
        let encoded = try JSONEncoder().encode([renamed])
        try encoded.write(to: fixture.fileURL, options: [.atomic])

        #expect(try await fixture.store.destinations() == [renamed])
    }

    @Test("adding a second destination keeps the first, in file order")
    func addPreservesOrder() async throws {
        let fixture = try Fixture()
        let first = makeDestination()
        let second = makeDestination(id: "dest-2", name: "YouTube", url: "rtmps://a.rtmps.youtube.com/live2")

        try await fixture.store.add(first)
        try await fixture.store.add(second)

        #expect(try await fixture.store.destinations() == [first, second])
    }

    @Test("adding a destination whose id is already saved throws, so two never share a key")
    func duplicateIdThrows() async throws {
        let fixture = try Fixture()
        try await fixture.store.add(makeDestination())

        let error = await #expect(throws: DestinationStoreError.self) {
            try await fixture.store.add(makeDestination(name: "A different name"))
        }

        #expect(error == .duplicateID(DestinationID(rawValue: "dest-1")))
        #expect(error?.identifier == .invalidArgument)
        #expect(try await fixture.store.destinations() == [makeDestination()])
    }

    @Test("an update replaces the name and url and keeps the id")
    func updateReplaces() async throws {
        let fixture = try Fixture()
        try await fixture.store.add(makeDestination())
        let edited = makeDestination(name: "Twitch backup", url: "rtmp://backup.example/app")

        try await fixture.store.update(edited)

        #expect(try await fixture.store.destinations() == [edited])
    }

    @Test("updating a destination that is not saved reports it as not found")
    func updateUnknownReportsNotFound() async throws {
        let fixture = try Fixture()
        await #expect(throws: DestinationStoreError.notFound(selector: "dest-1")) {
            try await fixture.store.update(makeDestination())
        }
    }

    @Test("a removed destination is gone from the file and its key is cleared")
    func removeClearsRecordAndKey() async throws {
        let fixture = try Fixture()
        let destination = makeDestination()
        try await fixture.store.add(destination)
        try await fixture.store.setKey("live_abc123", for: destination)

        try await fixture.store.remove(id: destination.id)

        #expect(try await fixture.store.destinations().isEmpty)
        let account = DestinationStore.secureStorageAccount(for: destination.id)
        #expect(try fixture.secureStorage.secret(forAccount: account) == nil)
    }

    @Test("removing a destination that is not saved changes nothing")
    func removeUnknownIsNoOp() async throws {
        let fixture = try Fixture()
        let destination = makeDestination()
        try await fixture.store.add(destination)

        try await fixture.store.remove(id: DestinationID(rawValue: "dest-absent"))

        #expect(try await fixture.store.destinations() == [destination])
    }

    @Test("the stream key account is the destination id under the destination prefix")
    func accountConvention() {
        #expect(DestinationStore.secureStorageAccount(for: DestinationID(rawValue: "dest-1")) == "destination:dest-1")
    }

    // MARK: - An unreadable document

    @Test("a document that does not decode reports the file path and is left untouched")
    func unreadableStoreIsPreserved() async throws {
        let fixture = try Fixture()
        let fileURL = fixture.fileURL
        let garbage = Data("this is not a destinations document".utf8)
        try garbage.write(to: fileURL, options: [.atomic])

        await #expect(throws: DestinationStoreError.self) {
            _ = try await fixture.store.destinations()
        }
        // A write also refuses rather than overwriting the operator's file.
        await #expect(throws: DestinationStoreError.self) {
            try await fixture.store.add(makeDestination())
        }
        #expect(try Data(contentsOf: fileURL) == garbage)
    }

    @Test("the unreadable-document error names the file and reports as a pipeline error")
    func unreadableStoreError() async throws {
        let fixture = try Fixture()
        let fileURL = fixture.fileURL
        try Data("{".utf8).write(to: fileURL, options: [.atomic])

        let error = await #expect(throws: DestinationStoreError.self) {
            _ = try await fixture.store.destinations()
        }
        #expect(error?.identifier == .pipelineError)
        #expect(String(describing: try #require(error)).contains(DestinationStore.fileName))
    }

    // MARK: - Selector resolution

    @Test("an exact id resolves outright")
    func resolvesById() async throws {
        let fixture = try Fixture()
        let destination = makeDestination()
        try await fixture.store.add(destination)

        #expect(try await fixture.store.resolve(selector: "dest-1") == destination)
    }

    @Test("a case-insensitive name fragment resolves")
    func resolvesByName() async throws {
        let fixture = try Fixture()
        let destination = makeDestination(name: "My Twitch")
        try await fixture.store.add(destination)

        #expect(try await fixture.store.resolve(selector: "twitch") == destination)
    }

    @Test("an id match wins over a destination merely named that id")
    func idBeatsName() async throws {
        let fixture = try Fixture()
        let byName = makeDestination(id: "dest-2", name: "dest-1", url: "rtmp://named.example/app")
        let byId = makeDestination()
        try await fixture.store.add(byName)
        try await fixture.store.add(byId)

        #expect(try await fixture.store.resolve(selector: "dest-1") == byId)
    }

    @Test("a selector matching nothing reports destinationNotFound")
    func unresolvedSelector() async throws {
        let fixture = try Fixture()
        try await fixture.store.add(makeDestination())

        let error = await #expect(throws: DestinationStoreError.self) {
            _ = try await fixture.store.resolve(selector: "vimeo")
        }
        #expect(error == .notFound(selector: "vimeo"))
        #expect(error?.identifier == .destinationNotFound)
    }

    @Test("a name matching several destinations reports destinationAmbiguous and lists them")
    func ambiguousSelector() async throws {
        let fixture = try Fixture()
        try await fixture.store.add(makeDestination(name: "Twitch main"))
        try await fixture.store.add(
            makeDestination(id: "dest-2", name: "Twitch backup", url: "rtmp://backup.example/app"))

        let error = await #expect(throws: DestinationStoreError.self) {
            _ = try await fixture.store.resolve(selector: "twitch")
        }
        #expect(error == .ambiguous(selector: "twitch", matches: ["Twitch main", "Twitch backup"]))
        #expect(error?.identifier == .destinationAmbiguous)
    }

    @Test("resolving against an empty store reports destinationNotFound")
    func resolveEmptyStore() async throws {
        let fixture = try Fixture()
        let error = await #expect(throws: DestinationStoreError.self) {
            _ = try await fixture.store.resolve(selector: "twitch")
        }
        #expect(error?.identifier == .destinationNotFound)
    }

    // MARK: - Keys

    @Test("a filed key reads back for its destination")
    func keyRoundTrips() async throws {
        let fixture = try Fixture()
        let destination = makeDestination()
        try await fixture.store.add(destination)

        try await fixture.store.setKey("live_abc123", for: destination)

        #expect(try await fixture.store.key(for: destination) == "live_abc123")
        #expect(await fixture.store.hasKey(for: destination))
    }

    @Test("a destination with no filed key reports no key")
    func keylessDestination() async throws {
        let fixture = try Fixture()
        let destination = makeDestination()
        try await fixture.store.add(destination)

        #expect(try await fixture.store.key(for: destination) == nil)
        #expect(await fixture.store.hasKey(for: destination) == false)
    }

    @Test("setting an empty key clears the filed one")
    func emptyKeyClears() async throws {
        let fixture = try Fixture()
        let destination = makeDestination()
        try await fixture.store.add(destination)
        try await fixture.store.setKey("live_abc123", for: destination)

        try await fixture.store.setKey("", for: destination)

        #expect(await fixture.store.hasKey(for: destination) == false)
    }

    @Test("setting a nil key clears the filed one")
    func nilKeyClears() async throws {
        let fixture = try Fixture()
        let destination = makeDestination()
        try await fixture.store.add(destination)
        try await fixture.store.setKey("live_abc123", for: destination)

        try await fixture.store.setKey(nil, for: destination)

        #expect(await fixture.store.hasKey(for: destination) == false)
    }

    // MARK: - The unsigned development build

    @Test("names and urls still resolve when no key can be read")
    func namesResolveWithoutKeyAccess() async throws {
        let fixture = try Fixture(readFailure: .keychain(-34018))
        let destination = makeDestination()
        try await fixture.store.add(destination)

        #expect(try await fixture.store.resolve(selector: "twitch") == destination)
        #expect(try await fixture.store.destinations() == [destination])
    }

    @Test("an unreadable key reports no key rather than throwing from a listing")
    func unreadableKeyReportsFalse() async throws {
        let fixture = try Fixture(readFailure: .keychain(-34018))
        let destination = makeDestination()
        try await fixture.store.add(destination)

        #expect(await fixture.store.hasKey(for: destination) == false)
    }

    @Test("reading an unreadable key throws an error naming the signed-binary fix")
    func unreadableKeyThrowsWithFix() async throws {
        let fixture = try Fixture(readFailure: .keychain(-34018))
        let destination = makeDestination()
        try await fixture.store.add(destination)

        let error = await #expect(throws: DestinationStoreError.self) {
            _ = try await fixture.store.key(for: destination)
        }
        #expect(error == .keyUnreadable(name: "Twitch", underlying: .keychain(-34018)))
        #expect(error?.identifier == .pipelineError)
        let message = String(describing: try #require(error))
        #expect(message.contains("unsigned development build"))
        #expect(message.contains("package-cli.sh"))
    }

    @Test("an unreadable key is reported on the event bus")
    func unreadableKeyEmitsError() async throws {
        let fixture = try Fixture(readFailure: .keychain(-34018))
        let events = fixture.events
        let destination = makeDestination()
        try await fixture.store.add(destination)

        _ = await fixture.store.hasKey(for: destination)

        #expect(await eventually { !events.named("destination.keyUnreadable").isEmpty })
        let event = try #require(events.named("destination.keyUnreadable").first)
        #expect(event.group == .error)
        #expect(event.domain == .platform)
        #expect(event.params?["identifier"] == .string(ErrorIdentifier.pipelineError.rawValue))
    }

    // MARK: - Change events

    @Test("adding a destination emits destination.added")
    func addEmits() async throws {
        let fixture = try Fixture()
        let events = fixture.events
        let destination = makeDestination()

        try await fixture.store.add(destination)

        #expect(await eventually { !events.named("destination.added").isEmpty })
        let event = try #require(events.named("destination.added").first)
        #expect(event.domain == .platform)
        #expect(event.params?["id"] == .string("dest-1"))
        #expect(event.params?["name"] == .string("Twitch"))
        #expect(event.params?["url"] == .string("rtmp://live.twitch.tv/app"))
    }

    @Test("updating a destination emits destination.changed with the new values")
    func updateEmits() async throws {
        let fixture = try Fixture()
        let events = fixture.events
        try await fixture.store.add(makeDestination())

        try await fixture.store.update(makeDestination(name: "Twitch backup"))

        #expect(await eventually { !events.named("destination.changed").isEmpty })
        let event = try #require(events.named("destination.changed").first)
        #expect(event.params?["name"] == .string("Twitch backup"))
    }

    @Test("removing a destination emits destination.removed")
    func removeEmits() async throws {
        let fixture = try Fixture()
        let events = fixture.events
        let destination = makeDestination()
        try await fixture.store.add(destination)

        try await fixture.store.remove(id: destination.id)

        #expect(await eventually { !events.named("destination.removed").isEmpty })
        #expect(events.named("destination.removed").first?.params?["id"] == .string("dest-1"))
    }

    @Test("removing a destination that is not saved emits nothing")
    func removeUnknownEmitsNothing() async throws {
        let fixture = try Fixture()
        let events = fixture.events

        try await fixture.store.remove(id: DestinationID(rawValue: "dest-absent"))

        _ = await eventually(within: 0.1) { !events.named("destination.removed").isEmpty }
        #expect(events.named("destination.removed").isEmpty)
    }

    @Test("a change event carries the record and never a key")
    func eventsCarryNoSecret() async throws {
        let fixture = try Fixture()
        let events = fixture.events
        let destination = makeDestination()
        try await fixture.store.add(destination)
        try await fixture.store.setKey("live_abc123", for: destination)
        try await fixture.store.update(makeDestination(name: "Twitch main"))
        try await fixture.store.remove(id: destination.id)

        #expect(await eventually { events.named("destination.removed").count == 1 })
        for event in events.all where event.name.hasPrefix("destination.") {
            let params = event.params ?? [:]
            #expect(params.values.allSatisfy { $0 != .string("live_abc123") })
            #expect(Set(params.keys).isSubset(of: ["id", "name", "url", "identifier", "message"]))
        }
    }
}
