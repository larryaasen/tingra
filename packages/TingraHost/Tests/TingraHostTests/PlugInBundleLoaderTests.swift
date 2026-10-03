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

/// A bundled plug-in whose id is `com.example.gamma` and whose `activate`
/// throws.
private final class ThrowingPlugIn: BundledPlugIn {
    /// The error its activation throws.
    struct ActivationError: Error, CustomStringConvertible {
        var description: String { "the gamma device is missing" }
    }

    let id = PlugInID(rawValue: "com.example.gamma")
    let name = "Gamma"
    init() {}
    func activate(in context: PlugInContext) async throws { throw ActivationError() }
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
    case alpha, beta, throwing, notAPlugIn, none, throwsSymbolNotFound

    /// The class the fake load returns.
    func load() throws -> AnyClass? {
        switch self {
        case .alpha: AlphaPlugIn.self
        case .beta: BetaPlugIn.self
        case .throwing: ThrowingPlugIn.self
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
        _ id: String?, kitVersion: String? = "0.1.0", principal: FakePrincipal = .alpha, embedded: [String] = [],
        name: String? = nil, version: String? = nil
    ) -> FakeBundle {
        FakeBundle(
            info: PlugInBundleInfo(
                id: id, kitVersion: kitVersion, principalClassName: "Fake.Principal", name: name, version: version),
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
/// name, and for any other a valid signature whose CDHash is
/// `cdhash-<name>`.
private struct FakeSignatures: CodeSignatureChecking {
    /// The verdicts by directory name.
    var verdicts: [String: CodeSignatureVerdict] = [:]

    func verdict(forBundleAt url: URL) -> CodeSignatureVerdict {
        verdicts[url.lastPathComponent] ?? .valid(cdHash: "cdhash-\(url.lastPathComponent)")
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

    /// Where the loader keeps the enablement file and its load markers for
    /// this test, inside the folder so it goes when the folder does. It is
    /// not named like a bundle, so the scan never meets it.
    var stateDirectory: URL {
        url.appending(path: "state", directoryHint: .isDirectory)
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
    /// ids. The host's kit is a framework unless a test says otherwise, so
    /// no result depends on how `swift test` itself linked the kit.
    private func scan(
        _ bundles: [String: FakeBundle],
        signatures: FakeSignatures = FakeSignatures(),
        taken: Set<PlugInID> = [],
        kitVersion: PlugInKitVersion = PlugInKitVersion(major: 0, minor: 1, patch: 0),
        kitIsFramework: Bool = true
    ) async throws -> (scan: PlugInBundleScan, opener: FakeOpener) {
        let folder = try PlugInFolder(Array(bundles.keys))
        defer { folder.remove() }
        let opener = FakeOpener(bundles)
        let loader = PlugInBundleLoader(
            folders: [folder.url], kitVersion: kitVersion, kitIsFramework: kitIsFramework,
            stateDirectory: folder.stateDirectory, opener: opener, signatures: signatures)
        return (await loader.load(skipping: taken, reportingTo: EventBus()), opener)
    }

    @Test("a well-formed, signed bundle loads as one instance of its principal class")
    func loadsAWellFormedBundle() async throws {
        let (scan, _) = try await scan(["Alpha.tingraplugin": .declaring("com.example.alpha")])

        #expect(scan.loaded.map(\.plugIn.id) == [PlugInID(rawValue: "com.example.alpha")])
        #expect(scan.loaded.first?.url.lastPathComponent == "Alpha.tingraplugin")
        #expect(scan.problems.isEmpty)
    }

    @Test("a folder that does not exist holds no bundles and reports nothing")
    func missingFolderHoldsNothing() async {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString)")
        let loader = PlugInBundleLoader(
            folders: [missing], stateDirectory: missing.appending(path: "state"), opener: FakeOpener([:]),
            signatures: FakeSignatures())

        let scan = await loader.load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.isEmpty)
    }

    @Test("only *.tingraplugin entries are bundles, and they are met in name order")
    func onlyPlugInBundlesInNameOrder() throws {
        let folder = try PlugInFolder(["b.tingraplugin", "a.tingraplugin", "c.bundle", "notes.txt"])
        defer { folder.remove() }
        let loader = PlugInBundleLoader(
            folders: [folder.url], stateDirectory: folder.stateDirectory, opener: FakeOpener([:]),
            signatures: FakeSignatures())

        #expect(loader.bundleURLs(in: folder.url).map(\.lastPathComponent) == ["a.tingraplugin", "b.tingraplugin"])
    }

    @Test("a symbolic link named *.tingraplugin is followed to the bundle it points at")
    func followsSymbolicLinks() async throws {
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
            folders: [folder.url], stateDirectory: folder.stateDirectory,
            opener: FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]), signatures: FakeSignatures())

        let scan = await loader.load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.count == 1)
        #expect(scan.loaded.first?.url.path().hasPrefix(elsewhere.url.resolvingSymlinksInPath().path()) == true)
    }

    @Test("a directory with no Info.plist is refused as loadFailed")
    func unreadableBundleIsRefused() async throws {
        let (scan, opener) = try await scan(["Broken.tingraplugin": FakeBundle(info: nil)])

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.map(\.reason) == [.loadFailed])
        #expect(scan.problems.first?.message.contains("no Contents/Info.plist") == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("a bundle declaring no plug-in id is refused as idMismatch, naming the key to add")
    func missingIDIsRefused() async throws {
        let (scan, opener) = try await scan(["Alpha.tingraplugin": .declaring(nil)])

        #expect(scan.problems.map(\.reason) == [.idMismatch])
        #expect(scan.problems.first?.message.contains(PlugInBundleLoader.idKey) == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("a bundle declaring a compiled-in plug-in's id is refused as a duplicate, before its code loads")
    func compiledInIDWins() async throws {
        let (scan, opener) = try await scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha")], taken: [PlugInID(rawValue: "com.example.alpha")])

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.map(\.reason) == [.duplicateID])
        #expect(scan.problems.first?.message.contains("compiled into Tingra") == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("the user folder wins a collision over the machine folder, and the refusal names the winner")
    func userFolderWinsOverMachineFolder() async throws {
        let user = try PlugInFolder(["Alpha.tingraplugin"])
        let machine = try PlugInFolder(["Alpha.tingraplugin"])
        defer {
            user.remove()
            machine.remove()
        }
        let loader = PlugInBundleLoader(
            folders: [user.url, machine.url], stateDirectory: user.stateDirectory,
            opener: FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]),
            signatures: FakeSignatures())

        let scan = await loader.load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.count == 1)
        #expect(scan.loaded.first?.url.path().hasPrefix(user.url.resolvingSymlinksInPath().path()) == true)
        #expect(scan.problems.map(\.reason) == [.duplicateID])
        #expect(scan.problems.first?.url.path().hasPrefix(machine.url.resolvingSymlinksInPath().path()) == true)
        #expect(scan.problems.first?.message.contains(user.url.lastPathComponent) == true)
    }

    @Test("an id refused for another reason stays free for a later bundle")
    func refusedBundleDoesNotTakeItsID() async throws {
        let (scan, _) = try await scan(
            ["A.tingraplugin": .declaring("com.example.alpha"), "B.tingraplugin": .declaring("com.example.alpha")],
            signatures: FakeSignatures(verdicts: ["A.tingraplugin": .unsigned(detail: "no signature")]))

        #expect(scan.loaded.map(\.url.lastPathComponent) == ["B.tingraplugin"])
        #expect(scan.problems.map(\.reason) == [.unsigned])
    }

    @Test(
        "a bundle declaring no kit version, or one that is not a version, is refused as kitVersion",
        arguments: [nil, "", "latest", "1"] as [String?])
    func unusableKitVersionIsRefused(_ declared: String?) async throws {
        let (scan, opener) = try await scan([
            "Alpha.tingraplugin": .declaring("com.example.alpha", kitVersion: declared)
        ])

        #expect(scan.problems.map(\.reason) == [.kitVersion])
        #expect(scan.problems.first?.message.contains(PlugInBundleLoader.kitVersionKey) == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("a bundle built against a kit this host cannot load is refused, naming both versions")
    func incompatibleKitVersionIsRefused() async throws {
        let (scan, opener) = try await scan(
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
    func unsignedBundleIsRefused() async throws {
        let (scan, opener) = try await scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha")],
            signatures: FakeSignatures(verdicts: ["Alpha.tingraplugin": .unsigned(detail: "code object is not signed")])
        )

        #expect(scan.problems.map(\.reason) == [.unsigned])
        #expect(scan.problems.first?.message.contains("code object is not signed") == true)
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("a quarantined bundle that is not notarized is refused, and its code never loads")
    func unnotarizedDownloadIsRefused() async throws {
        let (scan, opener) = try await scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha")],
            signatures: FakeSignatures(verdicts: ["Alpha.tingraplugin": .notNotarized]))

        #expect(scan.problems.map(\.reason) == [.notNotarized])
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("code that will not load is refused as loadFailed, carrying dyld's explanation")
    func loadErrorIsRefused() async throws {
        let (scan, _) = try await scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .throwsSymbolNotFound)])

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.map(\.reason) == [.loadFailed])
        #expect(scan.problems.first?.message.contains("Symbol not found") == true)
    }

    @Test("a principal class that is not a BundledPlugIn is refused, naming the class the plist declares")
    func nonPlugInPrincipalClassIsRefused() async throws {
        let (scan, _) = try await scan(["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .notAPlugIn)])

        #expect(scan.problems.map(\.reason) == [.noPrincipalClass])
        #expect(scan.problems.first?.message.contains("Fake.Principal") == true)
    }

    @Test("a principal class that exists but is not a BundledPlugIn names a second kit copy as a cause")
    func nonConformingClassNamesASecondKitCopy() async throws {
        let (scan, _) = try await scan(["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .notAPlugIn)])
        let message = try #require(scan.problems.first?.message)

        #expect(message.contains("has a principal class, 'Fake.Principal'"))
        #expect(message.contains("second copy of the plug-in kit"))
        #expect(message.contains("without embedding"))
        #expect(!message.contains("swift build"))
    }

    @Test("in a host whose kit is a dylib, a non-conforming principal class blames the host's own build")
    func nonConformingClassInASwiftBuildHostNamesTheHost() async throws {
        let (scan, _) = try await scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .notAPlugIn)], kitIsFramework: false)

        #expect(scan.problems.map(\.reason) == [.noPrincipalClass])
        #expect(scan.problems.first?.message.contains("was built by `swift build`") == true)
    }

    @Test("a missing principal class is explained without the second-copy cause")
    func missingPrincipalClassMessageNamesTheKey() {
        let message = PlugInBundleLoader.noPrincipalClassMessage(
            name: "Alpha.tingraplugin", declared: nil, found: nil, kitIsFramework: true)

        #expect(message.contains("it sets no NSPrincipalClass"))
        #expect(!message.contains("second copy"))
    }

    @Test("in a host whose kit is a dylib, code that will not load is explained by the host's own build")
    func loadErrorInASwiftBuildHostNamesTheHost() async throws {
        let (scan, _) = try await scan(
            ["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .throwsSymbolNotFound)],
            kitIsFramework: false)
        let message = try #require(scan.problems.first?.message)

        #expect(scan.problems.map(\.reason) == [.loadFailed])
        #expect(message.contains("Symbol not found"))
        #expect(message.contains("was built by `swift build`"))
        #expect(message.contains("scripts/release-cli-package.sh"))
        #expect(!message.contains("newer than this Tingra's"))
    }

    @Test("dyld's paths under the home folder are abbreviated, wherever they appear in its text")
    func loadErrorAbbreviatesHome() {
        let detail =
            "Library not loaded: @rpath/TingraPlugInKit.framework/Versions/A/TingraPlugInKit\n"
            + "  Referenced from: <UUID> /Users/someone/Library/Application Support/Tingra/Plug-ins/A.tingraplugin\n"
            + "  Reason: tried: '/System/Volumes/Preboot/Cryptexes/OS/Users/someone/Projects/x' (no such file), "
            + "'/Users/someoneelse/y' (no such file)"
        let error = NSError(domain: NSCocoaErrorDomain, code: 3588, userInfo: [NSDebugDescriptionErrorKey: detail])

        let message = PlugInBundleLoader.loadFailedMessage(
            name: "A.tingraplugin", error: error, kitIsFramework: true, home: "/Users/someone/")

        #expect(!message.contains("/Users/someone/"))
        #expect(message.contains("Referenced from: <UUID> ~/Library/Application Support/Tingra/Plug-ins"))
        #expect(message.contains("/Cryptexes/OS~/Projects/x"))
        #expect(message.contains("'/Users/someoneelse/y'"))
    }

    @Test("an image path inside a framework is a framework; a dylib is not; an unknown one counts as a framework")
    func frameworkImagePaths() {
        #expect(
            PlugInBundleLoader.isFramework(
                imagePath:
                    "/Applications/Tingra.app/Contents/Frameworks/TingraEventBus.framework/Versions/A/TingraEventBus"))
        #expect(!PlugInBundleLoader.isFramework(imagePath: "/usr/local/libexec/tingra-cli/libTingraEventBus.dylib"))
        #expect(PlugInBundleLoader.isFramework(imagePath: nil))
    }

    @Test("the running kit's image is the event bus's own")
    func runningKitImageIsTheEventBus() {
        #expect(PlugInBundleLoader.runningKitImagePath?.contains("TingraEventBus") == true)
    }

    @Test("a bundle whose principal class the runtime cannot find is refused as noPrincipalClass")
    func missingPrincipalClassIsRefused() async throws {
        let (scan, _) = try await scan(["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .none)])

        #expect(scan.problems.map(\.reason) == [.noPrincipalClass])
    }

    @Test("a principal class reporting a different id from the plist's is refused as idMismatch")
    func instanceIDMismatchIsRefused() async throws {
        let (scan, _) = try await scan(["Alpha.tingraplugin": .declaring("com.example.alpha", principal: .beta)])

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.map(\.reason) == [.idMismatch])
        #expect(scan.problems.first?.message.contains("com.example.beta") == true)
    }

    @Test("a bundle carrying the kit copies Xcode embeds from the SDK loads with nothing reported")
    func sdkEmbeddedKitIsNotReported() async throws {
        let (scan, _) = try await scan([
            "Alpha.tingraplugin": .declaring(
                "com.example.alpha", embedded: ["TingraPlugInKit", "TingraEventBus", "SomethingElse"])
        ])

        #expect(scan.loaded.count == 1)
        #expect(scan.problems.isEmpty)
    }

    @Test("a bundle embedding the kit as a dylib in a framework host loads anyway, and the copy is reported")
    func mismatchedEmbeddedKitLoadsAndIsReported() async throws {
        let (scan, _) = try await scan([
            "Alpha.tingraplugin": .declaring(
                "com.example.alpha",
                embedded: ["libTingraPlugInKit", "libTingraEventBus", "TingraPlugInKit", "SomethingElse"])
        ])

        #expect(scan.loaded.count == 1)
        #expect(scan.problems.map(\.reason) == [.embeddedKit])
        #expect(scan.problems.first?.message.contains("libTingraEventBus and libTingraPlugInKit as a dylib") == true)
        #expect(scan.problems.first?.message.contains("TingraPlugInSDK") == true)
        #expect(!PlugInBundleProblem.Reason.embeddedKit.refuses)
    }

    @Test("a mismatched kit copy is the other form than the host's own kit")
    func mismatchedKitCopiesFollowTheHostsForm() {
        let embedded = ["TingraPlugInKit", "libTingraEventBus", "SomethingElse", "libSomethingElse"]

        #expect(PlugInBundleLoader.mismatchedKitCopies(among: embedded, kitIsFramework: true) == ["libTingraEventBus"])
        #expect(PlugInBundleLoader.mismatchedKitCopies(among: embedded, kitIsFramework: false) == ["TingraPlugInKit"])
        #expect(PlugInBundleLoader.mismatchedKitCopies(among: [], kitIsFramework: true).isEmpty)
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
            folders: [folder.url], stateDirectory: folder.stateDirectory,
            opener: FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]),
            signatures: FakeSignatures(verdicts: ["Alpha.tingraplugin": .notNotarized]))

        _ = await loader.load(skipping: [], reportingTo: eventBus)
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
            folders: [folder.url], stateDirectory: folder.stateDirectory,
            opener: FakeOpener([
                "Alpha.tingraplugin": .declaring("com.example.alpha"),
                "Beta.tingraplugin": .declaring("com.example.beta", principal: .beta),
            ]),
            signatures: FakeSignatures())

        let activated = await PlugInLoader().activate([BetaPlugIn()], thenBundlesFrom: loader, in: context).activated
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

    // MARK: - Turned off, crashed, and safe mode (Decisions 31–34)

    /// A loader over one folder of fake bundles, keeping its state in the
    /// folder. The host's kit is a framework, as in `scan`, so no result
    /// depends on how `swift test` itself linked the kit.
    private func loader(
        _ folder: PlugInFolder, _ opener: FakeOpener, signatures: FakeSignatures = FakeSignatures(),
        safeMode: PlugInSafeModeTrigger? = nil
    ) -> PlugInBundleLoader {
        PlugInBundleLoader(
            folders: [folder.url], kitIsFramework: true, stateDirectory: folder.stateDirectory,
            frontEnd: "tingra-cli serve", safeMode: safeMode, opener: opener, signatures: signatures)
    }

    /// A marker for a process that is gone: this process's id with a start
    /// time it never had.
    private func deadProcessMarker(id: String, name: String, cdHash: String) -> PlugInLoadMarker {
        PlugInLoadMarker(
            id: PlugInID(rawValue: id), path: "~/Library/Application Support/Tingra/Plug-ins/\(name)",
            cdHash: cdHash, frontEnd: "tingra-cli serve",
            process: ProcessIdentity(processID: getpid(), startTime: 1))
    }

    /// Writes a marker file as a process would have.
    private func write(_ marker: PlugInLoadMarker, in folder: PlugInFolder) throws {
        let guardian = PlugInLoadGuard(directory: folder.stateDirectory.appending(path: PlugInLoadGuard.folderName))
        try FileManager.default.createDirectory(at: guardian.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(marker).write(to: guardian.markerURL(for: marker.process))
    }

    @Test("a bundle the operator turned off is skipped and reported, and its code never loads")
    func disabledBundleIsSkipped() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        try PlugInEnablementStore(directory: folder.stateDirectory).update {
            $0.disable(PlugInID(rawValue: "com.example.alpha"))
        }
        let opener = FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")])
        let eventBus = EventBus()
        let events = eventBus.events()

        let scan = await loader(folder, opener).load(skipping: [], reportingTo: eventBus)
        let received = await drain(eventBus, events)

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.isEmpty)
        #expect(scan.skipped.map(\.reason) == [.disabled])
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
        let skips = received.filter { $0.name == "plugin.skipped" }
        #expect(skips.count == 1)
        #expect(skips.first?.group == .event)
        #expect(skips.first?.domain == .plugIn)
        #expect(skips.first?.params?["reason"] == .string("disabled"))
        #expect(skips.first?.params?["id"] == .string("com.example.alpha"))
        #expect(skips.first?.params?["tier"] == .string("host"))
        guard case .string(let path) = skips.first?.params?["path"] else {
            Issue.record("the skip carries no path")
            return
        }
        #expect(path.hasSuffix("Alpha.tingraplugin"))
    }

    @Test("a turned-off bundle still holds its id, so a second copy is refused as a duplicate")
    func skippedBundleHoldsItsID() async throws {
        let folder = try PlugInFolder(["A.tingraplugin", "B.tingraplugin"])
        defer { folder.remove() }
        try PlugInEnablementStore(directory: folder.stateDirectory).update {
            $0.disable(PlugInID(rawValue: "com.example.alpha"))
        }
        let opener = FakeOpener([
            "A.tingraplugin": .declaring("com.example.alpha"), "B.tingraplugin": .declaring("com.example.alpha"),
        ])

        let scan = await loader(folder, opener).load(skipping: [], reportingTo: EventBus())

        #expect(scan.skipped.map(\.url.lastPathComponent) == ["A.tingraplugin"])
        #expect(scan.problems.map(\.reason) == [.duplicateID])
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("safe mode loads no bundle's code, still reports refusals, and reports itself once")
    func safeModeSkipsEveryBundle() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin", "Beta.tingraplugin"])
        defer { folder.remove() }
        let opener = FakeOpener([
            "Alpha.tingraplugin": .declaring("com.example.alpha"),
            "Beta.tingraplugin": .declaring("com.example.beta", principal: .beta),
        ])
        let signatures = FakeSignatures(verdicts: ["Beta.tingraplugin": .unsigned(detail: "no signature")])
        let eventBus = EventBus()
        let events = eventBus.events()

        let scan = await loader(folder, opener, signatures: signatures, safeMode: .shiftKey)
            .load(skipping: [], reportingTo: eventBus)
        let received = await drain(eventBus, events)

        #expect(scan.loaded.isEmpty)
        #expect(scan.skipped.map(\.reason) == [.safeMode])
        #expect(scan.problems.map(\.reason) == [.unsigned])
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
        let reports = received.filter { $0.name == "plugin.safeMode" }
        #expect(reports.count == 1)
        #expect(reports.first?.group == .app)
        #expect(reports.first?.domain == .plugIn)
        #expect(reports.first?.params?["trigger"] == .string("shiftKey"))
        #expect(reports.first?.params?["skipped"] == .int(1))
    }

    @Test("a normal launch does not report safe mode")
    func normalLaunchReportsNoSafeMode() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let eventBus = EventBus()
        let events = eventBus.events()

        _ = await loader(folder, FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]))
            .load(skipping: [], reportingTo: eventBus)
        let received = await drain(eventBus, events)

        #expect(!received.contains { $0.name == "plugin.safeMode" })
    }

    @Test("a bundle activates inside its marker, and the marker is gone once activation returns")
    func activationRunsInsideTheMarker() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let loader = loader(folder, FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]))
        let markerURL = loader.loadGuard.markerURL(for: .current)
        var markerDuringActivation: PlugInLoadMarker?

        let scan = await loader.load(skipping: [], reportingTo: EventBus()) { _ in
            markerDuringActivation = (try? Data(contentsOf: markerURL)).flatMap {
                try? JSONDecoder().decode(PlugInLoadMarker.self, from: $0)
            }
        }

        #expect(scan.loaded.count == 1)
        #expect(markerDuringActivation?.id == PlugInID(rawValue: "com.example.alpha"))
        #expect(markerDuringActivation?.cdHash == "cdhash-Alpha.tingraplugin")
        #expect(markerDuringActivation?.frontEnd == "tingra-cli serve")
        #expect(markerDuringActivation?.process == .current)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false)))
    }

    @Test("a marker left by a dead process turns that build off, reports it once as crashed, then skips it")
    func deadProcessMarkerTurnsTheBundleOff() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let marker = deadProcessMarker(
            id: "com.example.alpha", name: "Alpha.tingraplugin", cdHash: "cdhash-Alpha.tingraplugin")
        try write(marker, in: folder)
        let opener = FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")])
        let eventBus = EventBus()
        let events = eventBus.events()

        let first = await loader(folder, opener).load(skipping: [], reportingTo: eventBus)
        let second = await loader(folder, opener).load(skipping: [], reportingTo: eventBus)
        let received = await drain(eventBus, events)

        #expect(first.problems.map(\.reason) == [.crashed])
        #expect(first.problems.first?.id == "com.example.alpha")
        #expect(first.problems.first?.message.contains("'Alpha.tingraplugin' was loading in tingra-cli serve") == true)
        #expect(first.problems.first?.message.contains("tingra-cli plug-ins enable com.example.alpha") == true)
        #expect(first.skipped.map(\.reason) == [.crashed])
        #expect(second.problems.isEmpty)
        #expect(second.skipped.map(\.reason) == [.crashed])
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
        let crash = try PlugInEnablementStore(directory: folder.stateDirectory).read()
            .crash(of: PlugInID(rawValue: "com.example.alpha"))
        #expect(crash?.cdHash == "cdhash-Alpha.tingraplugin")
        #expect(crash?.frontEnd == "tingra-cli serve")
        #expect(crash?.path == marker.path)
        let reports = received.filter { $0.name == "plugin.bundle" }
        #expect(reports.map { $0.params?["reason"] } == [.string("crashed")])
        #expect(received.filter { $0.name == "plugin.skipped" }.count == 2)
        let guardian = PlugInLoadGuard(directory: folder.stateDirectory.appending(path: PlugInLoadGuard.folderName))
        #expect(guardian.abandonedMarkers().isEmpty)
    }

    @Test("a bundle turned off by a crash loads again once its code changes, and the crash is forgotten")
    func changedCodeLoadsAgain() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let store = PlugInEnablementStore(directory: folder.stateDirectory)
        try store.update {
            $0.recordCrash(
                CrashedPlugInBundle(
                    id: PlugInID(rawValue: "com.example.alpha"), cdHash: "an-older-build", path: "~/A",
                    frontEnd: "Tingra", date: .now))
        }

        let scan = await loader(folder, FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]))
            .load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.count == 1)
        #expect(scan.skipped.isEmpty)
        #expect(try store.read().crashed.isEmpty)
    }

    @Test("a bundle turned back on after a crash loads")
    func enabledAfterACrashLoads() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let store = PlugInEnablementStore(directory: folder.stateDirectory)
        let id = PlugInID(rawValue: "com.example.alpha")
        try store.update {
            $0.recordCrash(
                CrashedPlugInBundle(
                    id: id, cdHash: "cdhash-Alpha.tingraplugin", path: "~/A", frontEnd: "Tingra", date: .now))
        }
        try store.update { $0.enable(id) }

        let scan = await loader(folder, FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]))
            .load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.count == 1)
    }

    @Test("a marker left by a process that is still running is left alone")
    func runningProcessMarkerIsLeftAlone() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let launchd = try #require(ProcessIdentity.startTime(of: 1))
        let marker = PlugInLoadMarker(
            id: PlugInID(rawValue: "com.example.alpha"), path: "~/A.tingraplugin", cdHash: "cdhash-Alpha.tingraplugin",
            frontEnd: "Tingra", process: ProcessIdentity(processID: 1, startTime: launchd))
        try write(marker, in: folder)

        let scan = await loader(folder, FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]))
            .load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.count == 1)
        #expect(scan.problems.isEmpty)
        let guardian = PlugInLoadGuard(directory: folder.stateDirectory.appending(path: PlugInLoadGuard.folderName))
        #expect(FileManager.default.fileExists(atPath: guardian.markerURL(for: marker.process).path()))
    }

    @Test("an unreadable enablement file loads no bundles, is reported, and is left untouched")
    func unreadableEnablementFileLoadsNothing() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let store = PlugInEnablementStore(directory: folder.stateDirectory)
        try FileManager.default.createDirectory(at: folder.stateDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        let opener = FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")])
        let eventBus = EventBus()
        let events = eventBus.events()

        let scan = await loader(folder, opener).load(skipping: [], reportingTo: eventBus)
        let received = await drain(eventBus, events)

        #expect(scan.loaded.isEmpty)
        #expect(scan.skipped.map(\.reason) == [.enablementUnreadable])
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
        let reports = received.filter { $0.name == "plugin.enablement" }
        #expect(reports.count == 1)
        #expect(reports.first?.group == .error)
        #expect(try Data(contentsOf: store.fileURL) == Data("not json".utf8))
    }

    @Test("a crash that cannot be recorded says so, and how to keep the bundle from loading")
    func unrecordedCrashMessage() {
        let marker = deadProcessMarker(id: "com.example.alpha", name: "Alpha.tingraplugin", cdHash: "x")

        let message = PlugInBundleLoader.crashedMessage(
            for: marker, recordError: .unreadable(path: "~/plug-ins.json", reason: "not json"))

        #expect(message.contains("'Alpha.tingraplugin' was loading in tingra-cli serve"))
        #expect(message.contains("could not turn it off"))
        #expect(message.contains("Remove the bundle from the plug-in folder"))
        #expect(!message.contains("plug-ins enable"))
    }

    @Test("a real signature's verdict carries its CDHash, as 40 lowercase hex digits")
    func realSignatureCarriesItsCDHash() {
        let verdict = StaticCodeSignatureChecker().verdict(forBundleAt: URL(filePath: "/bin/ls"))

        guard case .valid(let cdHash) = verdict else {
            Issue.record("/bin/ls did not validate: \(verdict)")
            return
        }
        #expect(cdHash.count == 40)
        #expect(cdHash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: - The load report (Decision 35)

    /// A context over fresh registries on `eventBus`.
    private func context(_ eventBus: EventBus) -> PlugInContext {
        PlugInContext(
            eventBus: eventBus, clock: HostClock(), inputs: InputRegistry(), outputs: OutputRegistry(),
            effects: EffectRegistry(), tools: ToolRegistry())
    }

    @Test("the report lists compiled-in plug-ins, then each bundle in scan order, each in one state")
    func reportListsEveryPlugInInOneState() async throws {
        let folder = try PlugInFolder([
            "A-Active.tingraplugin", "B-Failed.tingraplugin", "C-Refused.tingraplugin", "D-Off.tingraplugin",
        ])
        defer { folder.remove() }
        try PlugInEnablementStore(directory: folder.stateDirectory).update {
            $0.disable(PlugInID(rawValue: "com.example.delta"))
        }
        let opener = FakeOpener([
            "A-Active.tingraplugin": .declaring(
                "com.example.alpha", embedded: ["libTingraPlugInKit"], name: "Alpha Bundle", version: "1.2.0"),
            "B-Failed.tingraplugin": .declaring("com.example.gamma", principal: .throwing, version: "0.3"),
            "C-Refused.tingraplugin": .declaring("com.example.charlie", name: "Charlie"),
            "D-Off.tingraplugin": .declaring("com.example.delta", name: "Delta"),
        ])
        let signatures = FakeSignatures(verdicts: ["C-Refused.tingraplugin": .unsigned(detail: "no signature")])

        let report = await PlugInLoader().activate(
            [BetaPlugIn()], thenBundlesFrom: loader(folder, opener, signatures: signatures), in: context(EventBus())
        ).report

        #expect(
            report.plugIns.map(\.id) == [
                "com.example.beta", "com.example.alpha", "com.example.gamma", "com.example.charlie",
                "com.example.delta",
            ])
        #expect(report.plugIns.map(\.state) == [.active, .active, .failed, .refused, .skipped])
        #expect(report.plugIns.map(\.source) == [.compiledIn, .bundle, .bundle, .bundle, .bundle])
        #expect(report.plugIns.map(\.reason) == [nil, nil, nil, "unsigned", "disabled"])

        let compiledIn = try #require(report.plugIns.first)
        #expect(compiledIn.name == "Beta")
        #expect(compiledIn.path == nil)
        #expect(compiledIn.version == nil)
        #expect(compiledIn.message == nil)

        let active = report.plugIns[1]
        #expect(active.name == "Alpha", "a loaded plug-in's own name wins over the bundle's")
        #expect(active.version == "1.2.0")
        #expect(active.path?.hasSuffix("A-Active.tingraplugin") == true)
        #expect(active.warnings.count == 1)
        #expect(active.warnings.first?.contains("embeds its own copy") == true)

        #expect(report.plugIns[2].message == "the gamma device is missing")
        #expect(report.plugIns[2].version == "0.3")
        #expect(report.plugIns[3].name == "Charlie")
        #expect(report.plugIns[3].message?.contains("no valid code signature") == true)
        #expect(report.plugIns[4].message?.contains("tingra-cli plug-ins enable com.example.delta") == true)
    }

    @Test("the report carries the kit version, the folders with a tilde, and whether safe mode was on")
    func reportCarriesTheLaunch() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let loader = PlugInBundleLoader(
            folders: [folder.url, URL.homeDirectory.appending(path: "Plug-ins")],
            kitVersion: PlugInKitVersion(major: 0, minor: 1, patch: 0), stateDirectory: folder.stateDirectory,
            safeMode: .flag, opener: FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")]),
            signatures: FakeSignatures())

        let report = await PlugInLoader().activate([], thenBundlesFrom: loader, in: context(EventBus())).report

        #expect(report.kitVersion == "0.1.0")
        #expect(report.safeMode)
        #expect(report.folders.last == "~/Plug-ins")
        #expect(report.plugIns.map(\.state) == [.skipped])
        #expect(report.plugIns.first?.reason == "safeMode")
    }

    @Test("a refused bundle with no plist is named by its directory, and a duplicate is not read as loaded")
    func reportNamesUnreadableAndDuplicateBundles() async throws {
        let folder = try PlugInFolder(["A.tingraplugin", "B.tingraplugin", "Broken.tingraplugin"])
        defer { folder.remove() }
        let opener = FakeOpener([
            "A.tingraplugin": .declaring("com.example.alpha"), "B.tingraplugin": .declaring("com.example.alpha"),
            "Broken.tingraplugin": FakeBundle(info: nil),
        ])

        let report = await PlugInLoader().activate([], thenBundlesFrom: loader(folder, opener), in: context(EventBus()))
            .report

        #expect(report.plugIns.map(\.state) == [.active, .refused, .refused])
        #expect(report.plugIns.map(\.reason) == [nil, "duplicateID", "loadFailed"])
        #expect(report.plugIns[1].id == "com.example.alpha")
        #expect(report.plugIns[2].id == nil)
        #expect(report.plugIns[2].name == "Broken")
        #expect(report.safeMode == false)
    }

    @Test("a bundle turned off by a crash found this launch carries the crash's message")
    func reportCarriesTheCrashMessage() async throws {
        let folder = try PlugInFolder(["Alpha.tingraplugin"])
        defer { folder.remove() }
        let bundleURL = folder.url.appending(path: "Alpha.tingraplugin").resolvingSymlinksInPath()
        try write(
            PlugInLoadMarker(
                id: PlugInID(rawValue: "com.example.alpha"), path: PlugInBundleLoader.displayPath(of: bundleURL),
                cdHash: "cdhash-Alpha.tingraplugin", frontEnd: "tingra-cli serve",
                process: ProcessIdentity(processID: getpid(), startTime: 1)),
            in: folder)
        let opener = FakeOpener(["Alpha.tingraplugin": .declaring("com.example.alpha")])

        let report = await PlugInLoader().activate([], thenBundlesFrom: loader(folder, opener), in: context(EventBus()))
            .report

        #expect(report.plugIns.map(\.state) == [.skipped])
        #expect(report.plugIns.first?.reason == "crashed")
        #expect(report.plugIns.first?.message?.contains("was loading in tingra-cli serve") == true)
    }

    @Test("every skip reason explains itself, naming the bundle")
    func everySkipReasonHasAMessage() {
        for reason in PlugInBundleSkip.Reason.allCases {
            let skip = PlugInBundleSkip(
                reason: reason, url: URL(filePath: "/tmp/Alpha.tingraplugin"), id: PlugInID(rawValue: "com.example.a"))
            #expect(skip.message.contains("'Alpha.tingraplugin'"), "\(reason)")
        }
    }

    @Test("the declared ids are read from the plists without loading any code")
    func declaredIDsLoadNoCode() throws {
        let folder = try PlugInFolder(["A.tingraplugin", "B.tingraplugin", "C.tingraplugin", "D.tingraplugin"])
        defer { folder.remove() }
        let opener = FakeOpener([
            "A.tingraplugin": .declaring("com.example.alpha"), "B.tingraplugin": .declaring("com.example.beta"),
            "C.tingraplugin": .declaring(nil), "D.tingraplugin": FakeBundle(info: nil),
        ])

        let ids = loader(folder, opener).declaredIDs()

        #expect(ids == [PlugInID(rawValue: "com.example.alpha"), PlugInID(rawValue: "com.example.beta")])
        #expect(opener.loadedNames.withLock { $0 }.isEmpty)
    }

    @Test("paths match whatever their trailing slash")
    func samePathIgnoresTrailingSlash() {
        #expect(
            PlugInLoadReport.samePath(
                URL(filePath: "/a/B.tingraplugin", directoryHint: .isDirectory), URL(filePath: "/a/B.tingraplugin")))
        #expect(!PlugInLoadReport.samePath(URL(filePath: "/a/B.tingraplugin"), URL(filePath: "/a/C.tingraplugin")))
    }
}
