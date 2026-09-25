//
//  PlugInBundleLoaderTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraHost

/// A bundled plug-in whose id is `com.example.alpha`.
private final class AlphaPlugIn: BundledPlugIn {
    let id = PlugInID(rawValue: "com.example.alpha")
    let name = "Alpha"
    init() {}
    func activate(in context: PlugInContext) async throws {}
}

/// A bundled plug-in whose id is `com.example.beta`.
private final class BetaPlugIn: BundledPlugIn {
    let id = PlugInID(rawValue: "com.example.beta")
    let name = "Beta"
    init() {}
    func activate(in context: PlugInContext) async throws {}
}

/// A class that is not a plug-in, named as a bundle's principal class.
private final class NotAPlugIn {}

/// The error a fake bundle's load throws, carrying dyld-style detail where
/// Foundation puts it.
private let symbolNotFound = NSError(
    domain: NSCocoaErrorDomain, code: 3588,
    userInfo: [NSDebugDescriptionErrorKey: "dlopen(x): Symbol not found: _$s15TingraPlugInKit3NewV"])

/// What a fake bundle's principal class resolves to.
private enum FakePrincipal: Sendable {
    case alpha, beta, notAPlugIn, none, throwsSymbolNotFound

    /// The class the fake load returns.
    func load() throws -> AnyClass? {
        switch self {
        case .alpha: AlphaPlugIn.self
        case .beta: BetaPlugIn.self
        case .notAPlugIn: NotAPlugIn.self
        case .none: nil
        case .throwsSymbolNotFound: throw symbolNotFound
        }
    }
}

/// One fake bundle's contents.
private struct FakeBundle: Sendable {
    /// The declarations, or `nil` for a directory that is not a bundle.
    var info: PlugInBundleInfo?
    /// The names in the bundle's `Contents/Frameworks`.
    var embedded: [String] = []
    /// What loading the bundle's code produces.
    var principal: FakePrincipal = .alpha

    /// A well-formed bundle declaring `id` against the given kit version.
    static func declaring(
        _ id: String?, kitVersion: String? = "0.1.0", principal: FakePrincipal = .alpha, embedded: [String] = []
    ) -> FakeBundle {
        FakeBundle(
            info: PlugInBundleInfo(id: id, kitVersion: kitVersion, principalClassName: "Fake.Principal"),
            embedded: embedded, principal: principal)
    }
}

/// A ``PlugInBundleOpening`` answering from fake bundles keyed by directory
/// name, recording which bundles had their code loaded.
private final class FakeOpener: PlugInBundleOpening {
    /// The fake bundles by directory name.
    let bundles: [String: FakeBundle]
    /// The bundles whose code was loaded, in order — empty when every check
    /// before the load refused them.
    let loadedNames = Mutex<[String]>([])

    init(_ bundles: [String: FakeBundle]) {
        self.bundles = bundles
    }

    func info(ofBundleAt url: URL) -> PlugInBundleInfo? {
        bundles[url.lastPathComponent]?.info
    }

    func embeddedLibraryNames(inBundleAt url: URL) -> [String] {
        bundles[url.lastPathComponent]?.embedded ?? []
    }

    func loadPrincipalClass(ofBundleAt url: URL) throws -> AnyClass? {
        loadedNames.withLock { $0.append(url.lastPathComponent) }
        return try bundles[url.lastPathComponent]?.principal.load()
    }
}

/// A ``CodeSignatureChecking`` answering scripted verdicts by directory
/// name, `.valid` for any other.
private struct FakeSignatures: CodeSignatureChecking {
    /// The verdicts by directory name.
    var verdicts: [String: CodeSignatureVerdict] = [:]

    func verdict(forBundleAt url: URL) -> CodeSignatureVerdict {
        verdicts[url.lastPathComponent] ?? .valid
    }
}

/// A temporary folder holding empty directories named like bundles, removed
/// when the test ends.
private struct PlugInFolder {
    /// The folder.
    let url: URL

    init(_ names: [String]) throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "PlugInBundleLoaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        for name in names {
            try FileManager.default.createDirectory(
                at: url.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Deletes the folder and everything in it.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Drains the bus after shutting it down.
private func drain(_ eventBus: EventBus, _ events: AsyncStream<EventBusEvent>) async -> [EventBusEvent] {
    eventBus.shutdown()
    var received: [EventBusEvent] = []
    for await event in events {
        received.append(event)
    }
    return received
}

@Suite("PlugInBundleLoader")
struct PlugInBundleLoaderTests {
    /// Scans one folder of fake bundles with the given signatures and taken
    /// ids.
    private func scan(
        _ bundles: [String: FakeBundle],
        signatures: FakeSignatures = FakeSignatures(),
        taken: Set<PlugInID> = [],
        kitVersion: PlugInKitVersion = PlugInKitVersion(major: 0, minor: 1, patch: 0)
    ) throws -> (scan: PlugInBundleScan, opener: FakeOpener) {
        let folder = try PlugInFolder(Array(bundles.keys))
        defer { folder.remove() }
        let opener = FakeOpener(bundles)
        let loader = PlugInBundleLoader(
            folders: [folder.url], kitVersion: kitVersion, opener: opener, signatures: signatures)
        return (loader.load(skipping: taken, reportingTo: EventBus()), opener)
    }

    @Test("a well-formed, signed bundle loads as one instance of its principal class")
    func loadsAWellFormedBundle() throws {
        let (scan, _) = try scan(["Alpha.tingraplugin": .declaring("com.example.alpha")])

        #expect(scan.loaded.map(\.plugIn.id) == [PlugInID(rawValue: "com.example.alpha")])
        #expect(scan.loaded.first?.url.lastPathComponent == "Alpha.tingraplugin")
        #expect(scan.problems.isEmpty)
    }

    @Test("a folder that does not exist holds no bundles and reports nothing")
    func missingFolderHoldsNothing() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString)")
        let loader = PlugInBundleLoader(folders: [missing], opener: FakeOpener([:]), signatures: FakeSignatures())

        let scan = loader.load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.isEmpty)
    }

    @Test("only *.tingraplugin entries are bundles, and they are met in name order")
    func onlyPlugInBundlesInNameOrder() throws {
        let folder = try PlugInFolder(["b.tingraplugin", "a.tingraplugin", "c.bundle", "notes.txt"])
        defer { folder.remove() }
        let loader = PlugInBundleLoader(folders: [folder.url], opener: FakeOpener([:]), signatures: FakeSignatures())

        #expect(loader.bundleURLs(in: folder.url).map(\.lastPathComponent) == ["a.tingraplugin", "b.tingraplugin"])
    }

    @Test("a symbolic link named *.tingraplugin is followed to the bundle it points at")
    func followsSymbolicLinks() throws {
        let folder = try PlugInFolder([])
        let elsewhere = try PlugInFolder(["Alpha.tingraplugin"])
        defer {
            folder.remove()
            elsewhere.remove()
        }
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "Alpha.tingraplugin"),
            withDestinationURL: elsewhere.url.appending(path: "Alpha.tingraplugin"))
        let loader = PlugInBundleLoader(
            folders: [folder.url], opener: FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]),
            signatures: FakeSignatures())

        let scan = loader.load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.count == 1)
        #expect(scan.loaded.first?.url.path().hasPrefix(elsewhere.url.resolvingSymlinksInPath().path()) == true)
    }

    @Test("a directory with no Info.plist is refused as loadFailed")
    func unreadableBundleIsRefused() throws {
        let (scan, opener) = try scan(["Broken.tingraplugin": FakeBundle(info: nil)])

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.map(\.reason) == [.loadFailed])
        #expect(scan.problems.first?.message.contains("no Contents/Info.plist") == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("a bundle declaring no plug-in id is refused as idMismatch, naming the key to add")
    func missingIDIsRefused() throws {
        let (scan, opener) = try scan(["Alpha.tingraplugin": .declaring(nil)])

        #expect(scan.problems.map(\.reason) == [.idMismatch])
        #expect(scan.problems.first?.message.contains(PlugInBundleLoader.idKey) == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("a bundle declaring a compiled-in plug-in's id is refused as a duplicate, before its code loads")
    func compiledInIDWins() throws {
        let (scan, opener) = try scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha")], taken: [PlugInID(rawValue: "com.example.alpha")])

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.map(\.reason) == [.duplicateID])
        #expect(scan.problems.first?.message.contains("compiled into Tingra") == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("the user folder wins a collision over the machine folder, and the refusal names the winner")
    func userFolderWinsOverMachineFolder() throws {
        let user = try PlugInFolder(["Alpha.tingraplugin"])
        let machine = try PlugInFolder(["Alpha.tingraplugin"])
        defer {
            user.remove()
            machine.remove()
        }
        let loader = PlugInBundleLoader(
            folders: [user.url, machine.url],
            opener: FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]),
            signatures: FakeSignatures())

        let scan = loader.load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.count == 1)
        #expect(scan.loaded.first?.url.path().hasPrefix(user.url.resolvingSymlinksInPath().path()) == true)
        #expect(scan.problems.map(\.reason) == [.duplicateID])
        #expect(scan.problems.first?.url.path().hasPrefix(machine.url.resolvingSymlinksInPath().path()) == true)
        #expect(scan.problems.first?.message.contains(user.url.lastPathComponent) == true)
    }

    @Test("an id refused for another reason stays free for a later bundle")
    func refusedBundleDoesNotTakeItsID() throws {
        let (scan, _) = try scan(
            ["A.tingraplugin": .declaring("com.example.alpha"), "B.tingraplugin": .declaring("com.example.alpha")],
            signatures: FakeSignatures(verdicts: ["A.tingraplugin": .unsigned(detail: "no signature")]))

        #expect(scan.loaded.map(\.url.lastPathComponent) == ["B.tingraplugin"])
        #expect(scan.problems.map(\.reason) == [.unsigned])
    }

    @Test(
        "a bundle declaring no kit version, or one that is not a version, is refused as kitVersion",
        arguments: [nil, "", "latest", "1"] as [String?])
    func unusableKitVersionIsRefused(_ declared: String?) throws {
        let (scan, opener) = try scan(["Alpha.tingraplugin": .declaring("com.example.alpha", kitVersion: declared)])

        #expect(scan.problems.map(\.reason) == [.kitVersion])
        #expect(scan.problems.first?.message.contains(PlugInBundleLoader.kitVersionKey) == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("a bundle built against a kit this host cannot load is refused, naming both versions")
    func incompatibleKitVersionIsRefused() throws {
        let (scan, opener) = try scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha", kitVersion: "1.3.0")],
            kitVersion: PlugInKitVersion(major: 1, minor: 2, patch: 0))

        #expect(scan.problems.map(\.reason) == [.kitVersion])
        #expect(scan.problems.first?.message.contains("1.3.0") == true)
        #expect(scan.problems.first?.message.contains("1.2.0") == true)
        #expect(scan.problems.first?.message.contains("Update Tingra") == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("from 1.0.0, a bundle loads when its major matches and its minor is not newer than the host's")
    func compatibilityFromOneZero() {
        let host = PlugInKitVersion(major: 1, minor: 2, patch: 0)
        #expect(PlugInBundleLoader.canLoad(builtAgainst: PlugInKitVersion(major: 1, minor: 0, patch: 5), in: host))
        #expect(PlugInBundleLoader.canLoad(builtAgainst: PlugInKitVersion(major: 1, minor: 2, patch: 9), in: host))
        #expect(!PlugInBundleLoader.canLoad(builtAgainst: PlugInKitVersion(major: 1, minor: 3, patch: 0), in: host))
        #expect(!PlugInBundleLoader.canLoad(builtAgainst: PlugInKitVersion(major: 2, minor: 0, patch: 0), in: host))
        #expect(!PlugInBundleLoader.canLoad(builtAgainst: PlugInKitVersion(major: 0, minor: 2, patch: 0), in: host))
    }

    @Test("before 1.0.0, a bundle loads only when its minor matches the host's exactly")
    func compatibilityBeforeOneZero() {
        let host = PlugInKitVersion(major: 0, minor: 2, patch: 0)
        #expect(PlugInBundleLoader.canLoad(builtAgainst: PlugInKitVersion(major: 0, minor: 2, patch: 3), in: host))
        #expect(!PlugInBundleLoader.canLoad(builtAgainst: PlugInKitVersion(major: 0, minor: 1, patch: 0), in: host))
        #expect(!PlugInBundleLoader.canLoad(builtAgainst: PlugInKitVersion(major: 0, minor: 3, patch: 0), in: host))
    }

    @Test("an older bundle's refusal asks for a rebuilt plug-in, not a newer Tingra")
    func olderBundleMessageAsksForARebuild() {
        let message = PlugInBundleLoader.kitVersionMessage(
            name: "Alpha.tingraplugin", bundle: PlugInKitVersion(major: 1, minor: 0, patch: 0),
            host: PlugInKitVersion(major: 2, minor: 1, patch: 0))

        #expect(message.contains("1.0.0"))
        #expect(message.contains("2.1.0"))
        #expect(message.contains("TingraPlugInSDK 2.1"))
        #expect(!message.contains("Update Tingra"))
    }

    @Test("an unsigned bundle is refused with the signature detail, and its code never loads")
    func unsignedBundleIsRefused() throws {
        let (scan, opener) = try scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha")],
            signatures: FakeSignatures(verdicts: ["Alpha.tingraplugin": .unsigned(detail: "code object is not signed")])
        )

        #expect(scan.problems.map(\.reason) == [.unsigned])
        #expect(scan.problems.first?.message.contains("code object is not signed") == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("a quarantined bundle that is not notarized is refused, and its code never loads")
    func unnotarizedDownloadIsRefused() throws {
        let (scan, opener) = try scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha")],
            signatures: FakeSignatures(verdicts: ["Alpha.tingraplugin": .notNotarized]))

        #expect(scan.problems.map(\.reason) == [.notNotarized])
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("code that will not load is refused as loadFailed, carrying dyld's explanation")
    func loadErrorIsRefused() throws {
        let (scan, _) = try scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .throwsSymbolNotFound)])

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.map(\.reason) == [.loadFailed])
        #expect(scan.problems.first?.message.contains("Symbol not found") == true)
    }

    @Test("a principal class that is not a BundledPlugIn is refused, naming the class the plist declares")
    func nonPlugInPrincipalClassIsRefused() throws {
        let (scan, _) = try scan(["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .notAPlugIn)])

        #expect(scan.problems.map(\.reason) == [.noPrincipalClass])
        #expect(scan.problems.first?.message.contains("Fake.Principal") == true)
    }

    @Test("a bundle whose principal class the runtime cannot find is refused as noPrincipalClass")
    func missingPrincipalClassIsRefused() throws {
        let (scan, _) = try scan(["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .none)])

        #expect(scan.problems.map(\.reason) == [.noPrincipalClass])
    }

    @Test("a principal class reporting a different id from the plist's is refused as idMismatch")
    func instanceIDMismatchIsRefused() throws {
        let (scan, _) = try scan(["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .beta)])

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.map(\.reason) == [.idMismatch])
        #expect(scan.problems.first?.message.contains("com.example.beta") == true)
    }

    @Test("a bundle embedding its own kit loads anyway, and the embedded copy is reported")
    func embeddedKitLoadsAndIsReported() throws {
        let (scan, _) = try scan([
            "Alpha.tingraplugin": .declaring(
                "com.example.alpha", embedded: ["TingraPlugInKit", "TingraEventBus", "SomethingElse"])
        ])

        #expect(scan.loaded.count == 1)
        #expect(scan.problems.map(\.reason) == [.embeddedKit])
        #expect(scan.problems.first?.message.contains("TingraEventBus and TingraPlugInKit") == true)
        #expect(!PlugInBundleProblem.Reason.embeddedKit.refuses)
    }

    @Test("every reason but embeddedKit refuses the bundle")
    func whichReasonsRefuse() {
        let refusing = PlugInBundleProblem.Reason.allCases.filter(\.refuses)
        #expect(refusing.count == PlugInBundleProblem.Reason.allCases.count - 1)
    }

    @Test("each problem is reported once as a plugin.bundle error event with its reason, path, and message")
    func problemsAreReportedOnTheBus() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let eventBus = EventBus()
        let events = eventBus.events()
        let loader = PlugInBundleLoader(
            folders: [folder.url], opener: FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]),
            signatures: FakeSignatures(verdicts: ["Alpha.tingraplugin": .notNotarized]))

        _ = loader.load(skipping: [], reportingTo: eventBus)
        let received = await drain(eventBus, events)

        let reports = received.filter { $0.name == "plugin.bundle" }
        #expect(reports.count == 1)
        #expect(reports.first?.group == .error)
        #expect(reports.first?.domain == .plugIn)
        #expect(reports.first?.params?["reason"] == .string("notNotarized"))
        #expect(reports.first?.params?["id"] == .string("com.example.alpha"))
        #expect(reports.first?.params?["tier"] == .string("host"))
        guard case .string(let path) = reports.first?.params?["path"] else {
            Issue.record("the report carries no path")
            return
        }
        #expect(path.hasSuffix("Alpha.tingraplugin"))
        #expect(reports.first?.params?["message"] != nil)
    }

    @Test("compiled-in plug-ins activate first, then bundles, each bundle reported with source and path")
    func activatesCompiledInThenBundles() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin", "Beta.tingraplugin"])
        defer { folder.remove() }
        let eventBus = EventBus()
        let events = eventBus.events()
        let context = PlugInContext(
            eventBus: eventBus, clock: HostClock(), inputs: InputRegistry(), outputs: OutputRegistry(),
            effects: EffectRegistry(), tools: ToolRegistry())
        let loader = PlugInBundleLoader(
            folders: [folder.url],
            opener: FakeOpener([
                "Alpha.tingraplugin": .declaring("com.example.alpha"),
                "Beta.tingraplugin": .declaring("com.example.beta", principal: .beta),
            ]),
            signatures: FakeSignatures())

        let activated = await PlugInLoader().activate([BetaPlugIn()], thenBundlesFrom: loader, in: context)
        let received = await drain(eventBus, events)

        #expect(activated.map(\.id.rawValue) == ["com.example.beta", "com.example.alpha"])
        let activations = received.filter { $0.name == "plugin.activated" }
        #expect(activations.map { $0.params?["id"] } == [.string("com.example.beta"), .string("com.example.alpha")])
        #expect(activations.first?.params?["source"] == nil)
        #expect(activations.last?.params?["source"] == .string("bundle"))
        #expect(activations.last?.params?["tier"] == .string("host"))
        let duplicates = received.filter { $0.name == "plugin.bundle" }
        #expect(duplicates.map { $0.params?["reason"] } == [.string("duplicateID")])
    }

    @Test("a path under the home folder is shown with a tilde")
    func displayPathAbbreviatesHome() {
        let url = URL.homeDirectory.appending(path: "Library/Application Support/Tingra/Plug-ins/A.tingraplugin")
        let problem = PlugInBundleProblem(reason: .unsigned, url: url, id: nil, message: "")

        #expect(problem.displayPath == "~/Library/Application Support/Tingra/Plug-ins/A.tingraplugin")
    }

    @Test("the standard folders are the user's, then the machine's")
    func standardFolders() {
        let folders = PlugInBundleLoader.standardFolders.map { $0.path(percentEncoded: false) }

        #expect(folders.count == 2)
        #expect(folders.first?.hasSuffix("Library/Application Support/Tingra/Plug-ins/") == true)
        #expect(folders.first?.hasPrefix(URL.homeDirectory.path(percentEncoded: false)) == true)
        #expect(folders.last == "/Library/Application Support/Tingra/Plug-ins/")
    }
}
