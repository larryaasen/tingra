//
//  PlugInBundleLoader.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus
import TingraPlugInKit

/// A host-tier plug-in the bundle loader admitted and instantiated, ready to
/// activate through ``PlugInLoader``.
public struct PlugInBundle: Sendable {
    /// The instance of the bundle's principal class.
    public let plugIn: any BundledPlugIn

    /// The bundle's directory.
    public let url: URL

    /// Creates a loaded bundle.
    ///
    /// - Parameters:
    ///   - plugIn: The instance of the bundle's principal class.
    ///   - url: The bundle's directory.
    public init(plugIn: any BundledPlugIn, url: URL) {
        self.plugIn = plugIn
        self.url = url
    }

    /// The bundle's path with the home folder abbreviated to `~`, as event
    /// params carry it.
    public var displayPath: String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}

/// One `*.tingraplugin` entry a scan met, whatever became of it, with what
/// its Info.plist declares.
public struct FoundPlugInBundle: Sendable, Equatable {
    /// The bundle's directory.
    public let url: URL

    /// What the bundle declares, or `nil` when it is not a readable bundle.
    public let info: PlugInBundleInfo?

    /// Creates a found bundle.
    ///
    /// - Parameters:
    ///   - url: The bundle's directory.
    ///   - info: What the bundle declares.
    public init(url: URL, info: PlugInBundleInfo?) {
        self.url = url
        self.info = info
    }
}

/// What one scan of the plug-in folders produced: every bundle met, the ones
/// that loaded, the ones admitted but skipped, and every problem found, each
/// in the order found.
public struct PlugInBundleScan: Sendable {
    /// Every bundle the scan met, in scan order — what a listing walks
    /// (PLUGINS.md, Decision 35).
    public let found: [FoundPlugInBundle]

    /// The bundles whose code loaded and whose principal class was
    /// instantiated, each handed to activation as it loaded.
    public let loaded: [PlugInBundle]

    /// Every refusal, every crash found, and every defect in a bundle that
    /// loaded anyway.
    public let problems: [PlugInBundleProblem]

    /// The bundles admitted but not loaded: turned off, turned off by a
    /// crash, or held back by safe mode.
    public let skipped: [PlugInBundleSkip]
}

/// A bundle that passed every check made before its code loads: what the
/// loader carries from admission to loading.
struct PlugInBundleCandidate: Sendable {
    /// The bundle's directory.
    let url: URL

    /// The plug-in id the bundle declares.
    let id: PlugInID

    /// What the bundle declares in its Info.plist.
    let info: PlugInBundleInfo

    /// The code directory hash of the bundle's signature.
    let cdHash: String
}

/// The host tier's external bundle loader: finds `*.tingraplugin` bundles
/// in the plug-in folders, admits the ones that pass every check, and hands
/// back one instance of each bundle's principal class (PLUGINS.md, "The
/// bundle loader: the design", Decisions 23–27).
///
/// Everything that can refuse a bundle is checked **before** its code is
/// loaded, in this order: it is a readable bundle; it declares a plug-in id
/// no one has taken; it declares a kit version this host can load; its code
/// signature is valid, and notarized when quarantined. A bundle that passes
/// takes its id, and is then skipped if the operator turned it off, if a
/// crash turned this build of it off, or if the launch is in safe mode
/// (PLUGINS.md, Decisions 31–34). Only then is the code loaded, the
/// principal class cast to `BundledPlugIn`, one instance made, its id
/// compared with the declared one, and the instance handed to activation. A
/// refusal is reported and skipped; the scan goes on. Nothing here traps: a
/// bundle that dyld refuses arrives as a thrown error (CLAUDE.md,
/// never-crash rule).
///
/// **One bundle at a time, under a marker.** Before a bundle's code loads,
/// the loader writes a marker naming it for this process, and removes the
/// marker once the bundle's activation returns (``PlugInLoadGuard``). A
/// scan that finds a marker whose process is gone knows which bundle took
/// that process down, turns that build of it off in the enablement file,
/// and reports it once as `crashed` — which is what stops a `serve` crash
/// loop without anyone's help.
///
/// The folders are scanned once, at launch. A loaded bundle cannot be
/// unloaded, so there is nothing to watch for: a bundle added or removed
/// takes effect at the next launch.
public struct PlugInBundleLoader: Sendable {
    /// The extension a plug-in bundle's directory carries.
    public static let fileExtension = "tingraplugin"

    /// The Info.plist key declaring the bundle's `PlugInID`.
    public static let idKey = "com.moonwink.tingra.plug-in.id"

    /// The Info.plist key declaring the kit version the bundle was built
    /// against, as `MAJOR.MINOR.PATCH`.
    public static let kitVersionKey = "com.moonwink.tingra.plug-in.kit-version"

    /// The kit libraries a bundle must link without embedding: the host
    /// supplies the one copy every bundle binds to.
    static let kitLibraryNames: Set<String> = [
        "TingraPlugInKit", "TingraEventBus", "libTingraPlugInKit", "libTingraEventBus",
    ]

    /// The two plug-in folders, in precedence order: the user's
    /// (`~/Library/Application Support/Tingra/Plug-ins`), then the one a
    /// `.pkg` installs into for every account on the Mac
    /// (`/Library/Application Support/Tingra/Plug-ins`).
    public static var standardFolders: [URL] {
        let user = URL.applicationSupportDirectory.appending(path: "Tingra/Plug-ins", directoryHint: .isDirectory)
        let machine = URL(filePath: "/Library/Application Support/Tingra/Plug-ins", directoryHint: .isDirectory)
        return [user, machine]
    }

    /// Tingra's own Application Support folder, beside `destinations.json`:
    /// where the enablement file and the load guard's markers live.
    public static var standardStateDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Tingra", directoryHint: .isDirectory)
    }

    /// The path of the image the running kit was loaded from, read from the
    /// Objective-C runtime's record of the image defining `EventBus` — the
    /// kits' one class — or `nil` if the runtime has none.
    public static var runningKitImagePath: String? {
        class_getImageName(EventBus.self).map { String(cString: $0) }
    }

    /// Whether the running kit is a framework, the form Xcode builds and
    /// every plug-in bundle links (PLUGINS.md, Decision 30). A `swift build`
    /// front end carries the kits as dylibs instead, which no Xcode-built
    /// bundle can bind to.
    public static var runningKitIsFramework: Bool {
        isFramework(imagePath: runningKitImagePath)
    }

    /// Whether an image path lies inside a framework bundle.
    ///
    /// - Parameter imagePath: The image's path, or `nil` when unknown —
    ///   counted as a framework, so an unknown host never blames itself.
    static func isFramework(imagePath: String?) -> Bool {
        guard let imagePath else { return true }
        return imagePath.contains(".framework/")
    }

    /// The folders scanned, in precedence order.
    public let folders: [URL]

    /// The kit version bundles are checked against — the running kit's.
    let kitVersion: PlugInKitVersion

    /// Whether this host's kit is a framework, which decides how a load
    /// refusal explains itself (see ``runningKitIsFramework``).
    let kitIsFramework: Bool

    /// The operator's choices, and the crashes found: which bundles are off.
    public let enablement: PlugInEnablementStore

    /// What names the bundle this process is loading, and finds the ones a
    /// dead process was loading.
    public let loadGuard: PlugInLoadGuard

    /// The front end loading bundles, such as `Tingra` or `tingra-cli serve`,
    /// named in a crash report when this process dies inside a bundle.
    public let frontEnd: String

    /// Why this launch is in safe mode, which loads no bundle's code; `nil`
    /// for a normal launch.
    public let safeMode: PlugInSafeModeTrigger?

    /// Reads, inspects, and loads bundles.
    let opener: any PlugInBundleOpening

    /// Decides whether a bundle's signature admits it.
    let signatures: any CodeSignatureChecking

    /// Creates a loader.
    ///
    /// - Parameters:
    ///   - folders: The folders to scan, in precedence order
    ///     (``standardFolders`` by default).
    ///   - kitVersion: The host's kit version (the running kit's by
    ///     default; a test names one).
    ///   - kitIsFramework: Whether the host's kit is a framework (the
    ///     running kit's form by default; a test names one).
    ///   - stateDirectory: The folder holding the enablement file and the
    ///     load guard's markers (``standardStateDirectory`` by default; a
    ///     test names a temporary one, so it never touches the operator's).
    ///   - frontEnd: The front end's name for a crash report (this
    ///     process's name by default; the CLI names its command).
    ///   - safeMode: Why this launch is in safe mode, or `nil`.
    ///   - opener: What touches a bundle on disk (a fake in tests).
    ///   - signatures: What checks a bundle's signature (a fake in tests).
    public init(
        folders: [URL] = PlugInBundleLoader.standardFolders,
        kitVersion: PlugInKitVersion = .current,
        kitIsFramework: Bool = PlugInBundleLoader.runningKitIsFramework,
        stateDirectory: URL = PlugInBundleLoader.standardStateDirectory,
        frontEnd: String = ProcessInfo.processInfo.processName,
        safeMode: PlugInSafeModeTrigger? = nil,
        opener: any PlugInBundleOpening = FoundationPlugInBundleOpener(),
        signatures: any CodeSignatureChecking = StaticCodeSignatureChecker()
    ) {
        self.folders = folders
        self.kitVersion = kitVersion
        self.kitIsFramework = kitIsFramework
        self.enablement = PlugInEnablementStore(directory: stateDirectory)
        self.loadGuard = PlugInLoadGuard(
            directory: stateDirectory.appending(path: PlugInLoadGuard.folderName, directoryHint: .isDirectory))
        self.frontEnd = frontEnd
        self.safeMode = safeMode
        self.opener = opener
        self.signatures = signatures
    }

    /// Whether a host carrying `host` can load a bundle built against
    /// `bundle`.
    ///
    /// From 1.0.0 the majors must match and the bundle's minor must not be
    /// newer than the host's: Library Evolution keeps an older bundle
    /// working in a newer host, and nothing can make a newer one work in an
    /// older host. Before 1.0.0 a minor may break (SemVer's 0.x rule, and
    /// ARCHITECTURE.md's "0.x during the CLI era"), so the minors must match
    /// exactly.
    ///
    /// - Parameters:
    ///   - bundle: The version the bundle declares.
    ///   - host: The host's kit version.
    public static func canLoad(builtAgainst bundle: PlugInKitVersion, in host: PlugInKitVersion) -> Bool {
        guard bundle.major == host.major else { return false }
        if host.major == 0 {
            return bundle.minor == host.minor
        }
        return bundle.minor <= host.minor
    }

    /// Scans the folders and loads every bundle that is admitted and not
    /// skipped, one at a time, handing each to `activate` as it loads.
    ///
    /// Every problem is reported as a `plugin.bundle` error event and every
    /// skip as a `plugin.skipped` event, each as it is found; a crash found
    /// from an earlier process comes first. In safe mode the launch is also
    /// reported once as `plugin.safeMode`, an `app` event carrying the
    /// `trigger` and how many bundles it `skipped`.
    ///
    /// - Parameters:
    ///   - takenIDs: The ids already in use — the compiled-in plug-ins',
    ///     which win any collision.
    ///   - eventBus: Where problems, skips, and safe mode are reported.
    ///   - activate: Activates one loaded bundle. It runs before the next
    ///     bundle loads and inside the bundle's marker, so a crash in
    ///     activation is attributed to its bundle.
    /// - Returns: The loaded bundles, the problems, and the skips, each in
    ///   scan order.
    public func load(
        skipping takenIDs: Set<PlugInID>,
        reportingTo eventBus: EventBus,
        activating activate: (PlugInBundle) async -> Void = { _ in }
    ) async -> PlugInBundleScan {
        var problems = recoverCrashes(reportingTo: eventBus)
        let operatorChoices: Result<PlugInEnablement, PlugInEnablementStoreError>
        do {
            operatorChoices = .success(try enablement.read())
        } catch let error as PlugInEnablementStoreError {
            operatorChoices = .failure(error)
            eventBus.error(
                "plugin.enablement", domain: .plugIn,
                params: ["message": .string(error.description), "tier": .string(PlugInLoader.tier)])
        } catch {
            operatorChoices = .failure(.unreadable(path: Self.displayPath(of: enablement.fileURL), reason: "\(error)"))
        }

        var owners: [PlugInID: String] = [:]
        for id in takenIDs {
            owners[id] = "a plug-in compiled into Tingra"
        }
        var found: [FoundPlugInBundle] = []
        var loaded: [PlugInBundle] = []
        var skipped: [PlugInBundleSkip] = []
        /// Records and reports problems as they are found.
        func report(_ found: [PlugInBundleProblem]) {
            for problem in found {
                eventBus.error("plugin.bundle", domain: .plugIn, params: problem.eventParams)
            }
            problems += found
        }

        for url in folders.flatMap(bundleURLs(in:)) {
            let info = opener.info(ofBundleAt: url)
            found.append(FoundPlugInBundle(url: url, info: info))
            let admission = admit(url, info: info, owners: owners)
            report(admission.problems)
            guard let candidate = admission.candidate else { continue }
            owners[candidate.id] = "the bundle at \(Self.displayPath(of: url))"

            if let reason = skipReason(for: candidate, choices: operatorChoices) {
                let skip = PlugInBundleSkip(reason: reason, url: url, id: candidate.id)
                eventBus.event("plugin.skipped", domain: .plugIn, params: skip.eventParams)
                skipped.append(skip)
                continue
            }

            loadGuard.begin(
                PlugInLoadMarker(
                    id: candidate.id, path: Self.displayPath(of: url), cdHash: candidate.cdHash, frontEnd: frontEnd,
                    process: loadGuard.process))
            let outcome = instantiate(candidate)
            report(outcome.problems)
            if let bundle = outcome.bundle {
                await activate(bundle)
                loaded.append(bundle)
            }
            loadGuard.end()
        }

        if let safeMode {
            eventBus.app(
                "plugin.safeMode", domain: .plugIn,
                params: [
                    "trigger": .string(safeMode.rawValue),
                    "skipped": .int(skipped.count { $0.reason == .safeMode }),
                ])
        }
        return PlugInBundleScan(found: found, loaded: loaded, problems: problems, skipped: skipped)
    }

    /// Finds the markers left by processes that died while loading a
    /// bundle, turns each of those builds off in the enablement file, and
    /// reports each once as `crashed`.
    ///
    /// - Parameter eventBus: Where each crash is reported.
    /// - Returns: The crashes, as problems.
    func recoverCrashes(reportingTo eventBus: EventBus) -> [PlugInBundleProblem] {
        var problems: [PlugInBundleProblem] = []
        for marker in loadGuard.abandonedMarkers() where loadGuard.claim(marker) {
            let crash = CrashedPlugInBundle(
                id: marker.id, cdHash: marker.cdHash, path: marker.path, frontEnd: marker.frontEnd, date: .now)
            var recordError: PlugInEnablementStoreError?
            do {
                try enablement.update { $0.recordCrash(crash) }
            } catch {
                recordError =
                    (error as? PlugInEnablementStoreError)
                    ?? .unwritable(path: Self.displayPath(of: enablement.fileURL), reason: "\(error)")
            }
            let problem = PlugInBundleProblem(
                reason: .crashed, url: URL(filePath: (marker.path as NSString).expandingTildeInPath),
                id: marker.id.rawValue, message: Self.crashedMessage(for: marker, recordError: recordError))
            eventBus.error("plugin.bundle", domain: .plugIn, params: problem.eventParams)
            problems.append(problem)
        }
        return problems
    }

    /// Why an admitted bundle is skipped, or `nil` when it loads.
    ///
    /// The operator's choice comes first, then a crash of this same build,
    /// then safe mode. A crash recorded for an earlier build is forgotten
    /// here, since new code is a new chance.
    ///
    /// - Parameters:
    ///   - candidate: The admitted bundle.
    ///   - choices: The enablement file's record, or why it could not be
    ///     read.
    func skipReason(
        for candidate: PlugInBundleCandidate, choices: Result<PlugInEnablement, PlugInEnablementStoreError>
    ) -> PlugInBundleSkip.Reason? {
        guard case .success(let record) = choices else { return .enablementUnreadable }
        if record.isDisabled(candidate.id) {
            return .disabled
        }
        if let crash = record.crash(of: candidate.id) {
            if crash.cdHash == candidate.cdHash {
                return .crashed
            }
            // A file that cannot be written leaves the stale record behind,
            // which is harmless: it never matches this build.
            _ = try? enablement.update { $0.forgetCrash(of: candidate.id) }
        }
        return safeMode == nil ? nil : .safeMode
    }

    /// The plug-in ids the bundles in the folders declare, read from their
    /// Info.plists without loading any code — what `tingra-cli plug-ins
    /// enable|disable` checks an id against (PLUGINS.md, Decision 35).
    public func declaredIDs() -> Set<PlugInID> {
        let declared = folders.flatMap(bundleURLs(in:)).compactMap { opener.info(ofBundleAt: $0)?.id }
        return Set(declared.filter { !$0.isEmpty }.map(PlugInID.init(rawValue:)))
    }

    /// The plug-in bundles directly inside a folder, sorted by name so every
    /// launch meets them in the same order. A missing folder holds none —
    /// the normal case until the first plug-in is installed. A symbolic link
    /// named `*.tingraplugin` is followed, so a developer can link a build
    /// product in.
    func bundleURLs(in folder: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return
            entries
            .filter { $0.pathExtension == Self.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.resolvingSymlinksInPath() }
    }

    /// Checks one bundle before any of its code runs: its declarations, the
    /// duplicate rule, its kit version, and its signature.
    ///
    /// - Parameters:
    ///   - url: The bundle's directory.
    ///   - info: What the bundle declares, or `nil` when it has no
    ///     Info.plist.
    ///   - owners: Who holds each id taken so far, for the duplicate rule's
    ///     message.
    /// - Returns: The admitted bundle, if any, and every problem found —
    ///   including an embedded kit, which does not refuse it.
    func admit(_ url: URL, info: PlugInBundleInfo?, owners: [PlugInID: String]) -> (
        candidate: PlugInBundleCandidate?, problems: [PlugInBundleProblem]
    ) {
        let name = url.lastPathComponent
        /// A result refusing the bundle for one reason.
        func refusal(_ reason: PlugInBundleProblem.Reason, id: String?, _ message: String) -> (
            candidate: PlugInBundleCandidate?, problems: [PlugInBundleProblem]
        ) {
            (nil, [PlugInBundleProblem(reason: reason, url: url, id: id, message: message)])
        }

        guard let info else {
            return refusal(
                .loadFailed, id: nil,
                "'\(name)' is not a readable bundle: it has no Contents/Info.plist. Build it as a macOS bundle "
                    + "target (wrapper extension '\(Self.fileExtension)'), or remove it from the plug-in folder.")
        }
        guard let declaredID = info.id, !declaredID.isEmpty else {
            return refusal(
                .idMismatch, id: nil,
                "'\(name)' declares no plug-in id. Add '\(Self.idKey)' to its Info.plist, set to the id its "
                    + "principal class reports.")
        }
        let id = PlugInID(rawValue: declaredID)
        if let owner = owners[id] {
            return refusal(
                .duplicateID, id: declaredID,
                "'\(name)' declares the plug-in id '\(declaredID)', which \(owner) already uses. Remove one of "
                    + "them. A plug-in compiled into Tingra wins a collision, then the user's plug-in folder over "
                    + "/Library.")
        }
        guard let declaredVersion = info.kitVersion, let version = PlugInKitVersion(declaredVersion) else {
            return refusal(
                .kitVersion, id: declaredID,
                "'\(name)' declares no usable plug-in kit version. Add '\(Self.kitVersionKey)' to its Info.plist, "
                    + "set to the TingraPlugInSDK version it was built against (this Tingra carries \(kitVersion)).")
        }
        guard Self.canLoad(builtAgainst: version, in: kitVersion) else {
            return refusal(
                .kitVersion, id: declaredID, Self.kitVersionMessage(name: name, bundle: version, host: kitVersion))
        }
        let cdHash: String
        switch signatures.verdict(forBundleAt: url) {
        case .valid(let hash):
            cdHash = hash
        case .unsigned(let detail):
            return refusal(
                .unsigned, id: declaredID,
                "'\(name)' has no valid code signature (\(detail)). Sign the bundle: an ad-hoc signature "
                    + "(`codesign --sign - --force --deep`) is enough for a build of your own, and a Developer ID "
                    + "signature is needed to distribute it.")
        case .notNotarized:
            return refusal(
                .notNotarized, id: declaredID,
                "'\(name)' was downloaded (it carries the quarantine attribute) and is not notarized, so Tingra "
                    + "will not load it. Install a notarized build from the plug-in's developer.")
        }

        var problems: [PlugInBundleProblem] = []
        let embeddedKits = opener.embeddedLibraryNames(inBundleAt: url).filter(Self.kitLibraryNames.contains).sorted()
        if !embeddedKits.isEmpty {
            problems.append(
                PlugInBundleProblem(
                    reason: .embeddedKit, url: url, id: declaredID,
                    message:
                        "'\(name)' embeds its own copy of \(embeddedKits.joined(separator: " and ")). It loads, "
                        + "bound to Tingra's copy, so the embedded one is never used and only adds a signature to "
                        + "maintain. Link TingraPlugInSDK without embedding it (Do Not Embed)."))
        }
        return (PlugInBundleCandidate(url: url, id: id, info: info, cdHash: cdHash), problems)
    }

    /// Loads an admitted bundle's code, casts its principal class, makes the
    /// one instance, and checks its id, or says why not.
    ///
    /// - Parameter candidate: The admitted bundle.
    /// - Returns: The loaded bundle, or the problem that refused it.
    func instantiate(_ candidate: PlugInBundleCandidate) -> (bundle: PlugInBundle?, problems: [PlugInBundleProblem]) {
        let url = candidate.url
        let name = url.lastPathComponent
        let declaredID = candidate.id.rawValue
        /// A result refusing the bundle for one reason.
        func refusal(_ reason: PlugInBundleProblem.Reason, _ message: String) -> (
            bundle: PlugInBundle?, problems: [PlugInBundleProblem]
        ) {
            (nil, [PlugInBundleProblem(reason: reason, url: url, id: declaredID, message: message)])
        }

        let principalClass: AnyClass?
        do {
            principalClass = try opener.loadPrincipalClass(ofBundleAt: url)
        } catch {
            return refusal(
                .loadFailed, Self.loadFailedMessage(name: name, error: error, kitIsFramework: kitIsFramework))
        }
        guard let plugInType = principalClass as? any BundledPlugIn.Type else {
            return refusal(
                .noPrincipalClass,
                Self.noPrincipalClassMessage(
                    name: name, declared: candidate.info.principalClassName, found: principalClass,
                    kitIsFramework: kitIsFramework))
        }
        let plugIn = plugInType.init()
        guard plugIn.id == candidate.id else {
            return refusal(
                .idMismatch,
                "'\(name)' declares the plug-in id '\(declaredID)' in its Info.plist, but its principal class "
                    + "reports '\(plugIn.id.rawValue)'. Make the two agree.")
        }
        return (PlugInBundle(plugIn: plugIn, url: url), [])
    }

    /// The report for a bundle a dead process was loading: which bundle,
    /// which front end died, and how to turn it back on.
    ///
    /// - Parameters:
    ///   - marker: The marker the dead process left.
    ///   - recordError: Why the crash could not be recorded, when it could
    ///     not; the bundle is then not turned off, and the message says how
    ///     to keep it from loading.
    static func crashedMessage(for marker: PlugInLoadMarker, recordError: PlugInEnablementStoreError?) -> String {
        let name = URL(filePath: marker.path).lastPathComponent
        let happened =
            "'\(name)' was loading in \(marker.frontEnd) when that process ended, so the bundle is taken to have "
            + "ended it."
        guard let recordError else {
            return "\(happened) Tingra turned it off; it stays off until its code changes or it is turned back on "
                + "in Settings > Plug-ins or with `tingra-cli plug-ins enable \(marker.id.rawValue)`."
        }
        return "\(happened) Tingra could not turn it off: \(recordError.description) Remove the bundle from the "
            + "plug-in folder to keep it from loading."
    }

    /// A path with the home folder abbreviated to `~`, as event params and
    /// shared logs carry it.
    static func displayPath(of url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    /// The refusal message for a kit version this host cannot load, naming
    /// both versions and which side needs the update.
    static func kitVersionMessage(name: String, bundle: PlugInKitVersion, host: PlugInKitVersion) -> String {
        let fix =
            bundle > host
            ? "Update Tingra to a release carrying plug-in kit \(bundle.major).\(bundle.minor) or later."
            : "Install a build of the plug-in made with TingraPlugInSDK \(host.major).\(host.minor)."
        return "'\(name)' was built against plug-in kit \(bundle), and this Tingra carries \(host). \(fix)"
    }

    /// Why a host whose kit is not a framework cannot load a bundle built in
    /// Xcode, and where to load one instead (PLUGINS.md, Decision 30).
    static let swiftBuildHostExplanation =
        "This Tingra was built by `swift build`, which carries the plug-in kits as dylibs, and a bundle built in "
        + "Xcode or against TingraPlugInSDK links them as frameworks, so it cannot bind to this Tingra's kit. Load "
        + "plug-in bundles in the app or in a release build of tingra-cli; scripts/release-cli-package.sh stages "
        + "an unsigned one for local use."

    /// The refusal message for code that would not load, carrying dyld's own
    /// explanation (Foundation puts it in the error's debug description).
    ///
    /// dyld names every path it tried, so the home folder is abbreviated to
    /// `~` throughout, as the `path` param already is: a shared log must not
    /// carry the operator's account name.
    ///
    /// - Parameters:
    ///   - name: The bundle's directory name.
    ///   - error: What `Bundle.loadAndReturnError()` threw.
    ///   - kitIsFramework: Whether the host's kit is a framework; when it is
    ///     not, the host's own build is the likely cause, and the message
    ///     says so instead of guessing at the bundle.
    ///   - home: The home folder to abbreviate (the operator's by default).
    static func loadFailedMessage(
        name: String, error: any Error, kitIsFramework: Bool,
        home: String = URL.homeDirectory.path(percentEncoded: false)
    ) -> String {
        let nsError = error as NSError
        let detail = abbreviatingHome(
            in: (nsError.userInfo[NSDebugDescriptionErrorKey] as? String) ?? nsError.localizedDescription, home: home)
        guard kitIsFramework else {
            return "'\(name)' could not be loaded: \(detail). \(swiftBuildHostExplanation)"
        }
        return "'\(name)' could not be loaded: \(detail). 'Symbol not found' means the bundle uses plug-in kit "
            + "API newer than this Tingra's; a code signature error means the system refused the bundle's signature."
    }

    /// The refusal message for a bundle whose principal class is missing or
    /// is not a `BundledPlugIn`.
    ///
    /// A class that exists but fails the cast is usually one of two things:
    /// the wrong class named, or a bundle bound to a second copy of the kit,
    /// whose `BundledPlugIn` is a different protocol from the host's. The
    /// message names both, and names the host's own build when that is the
    /// cause.
    ///
    /// - Parameters:
    ///   - name: The bundle's directory name.
    ///   - declared: The `NSPrincipalClass` the Info.plist declares, if any.
    ///   - found: The class the runtime found, if any.
    ///   - kitIsFramework: Whether the host's kit is a framework.
    static func noPrincipalClassMessage(name: String, declared: String?, found: AnyClass?, kitIsFramework: Bool)
        -> String
    {
        guard let found else {
            let named = declared.map { "NSPrincipalClass is '\($0)'" } ?? "it sets no NSPrincipalClass"
            return "'\(name)' has no principal class conforming to BundledPlugIn (\(named)). Set NSPrincipalClass "
                + "to the module-qualified name of a class conforming to BundledPlugIn, such as 'MyPlugIn.MyPlugIn'."
        }
        let className = declared ?? NSStringFromClass(found)
        let message =
            "'\(name)' has a principal class, '\(className)', that does not conform to BundledPlugIn as this "
            + "Tingra's plug-in kit defines it. Either the class does not adopt BundledPlugIn, so NSPrincipalClass "
            + "should name the one that does, or the bundle bound to a second copy of the plug-in kit (the log then "
            + "shows 'Class … is implemented in both'), found through one of its own rpaths."
        guard kitIsFramework else {
            return "\(message) \(swiftBuildHostExplanation)"
        }
        return "\(message) Build the bundle against TingraPlugInSDK and link the kit without embedding it."
    }

    /// Replaces every path inside the home folder with its `~` form.
    ///
    /// - Parameters:
    ///   - text: The text to rewrite, such as dyld's list of paths tried.
    ///   - home: The home folder's path, with or without a trailing slash.
    static func abbreviatingHome(in text: String, home: String) -> String {
        let folder = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !folder.isEmpty else { return text }
        return text.replacing(folder + "/", with: "~/")
    }
}
