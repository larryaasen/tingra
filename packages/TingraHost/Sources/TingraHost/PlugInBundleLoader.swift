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

/// What one scan of the plug-in folders produced: the bundles that loaded,
/// and every problem found, in the order found.
public struct PlugInBundleScan: Sendable {
    /// The bundles admitted and instantiated, not yet activated.
    public let loaded: [PlugInBundle]

    /// Every refusal, and every defect in a bundle that loaded anyway.
    public let problems: [PlugInBundleProblem]
}

/// The host tier's external bundle loader: finds `*.tingraplugin` bundles
/// in the plug-in folders, admits the ones that pass every check, and hands
/// back one instance of each bundle's principal class (PLUGINS.md, "The
/// bundle loader: the design", Decisions 23–27).
///
/// Everything that can refuse a bundle is checked **before** its code is
/// loaded, in this order: it is a readable bundle; it declares a plug-in id
/// no one has taken; it declares a kit version this host can load; its code
/// signature is valid, and notarized when quarantined. Only then is the code
/// loaded, the principal class cast to `BundledPlugIn`, one instance made,
/// and its id compared with the declared one. A refusal is reported and
/// skipped; the scan goes on. Nothing here traps: a bundle that dyld refuses
/// arrives as a thrown error (CLAUDE.md, never-crash rule).
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

    /// The folders scanned, in precedence order.
    public let folders: [URL]

    /// The kit version bundles are checked against — the running kit's.
    let kitVersion: PlugInKitVersion

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
    ///   - opener: What touches a bundle on disk (a fake in tests).
    ///   - signatures: What checks a bundle's signature (a fake in tests).
    public init(
        folders: [URL] = PlugInBundleLoader.standardFolders,
        kitVersion: PlugInKitVersion = .current,
        opener: any PlugInBundleOpening = FoundationPlugInBundleOpener(),
        signatures: any CodeSignatureChecking = StaticCodeSignatureChecker()
    ) {
        self.folders = folders
        self.kitVersion = kitVersion
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

    /// Scans the folders, reports every problem as a `plugin.bundle` error
    /// event, and returns the bundles that loaded.
    ///
    /// - Parameters:
    ///   - takenIDs: The ids already in use — the compiled-in plug-ins',
    ///     which win any collision.
    ///   - eventBus: Where problems are reported.
    /// - Returns: The loaded bundles and the problems, each in scan order.
    public func load(skipping takenIDs: Set<PlugInID>, reportingTo eventBus: EventBus) -> PlugInBundleScan {
        var owners: [PlugInID: String] = [:]
        for id in takenIDs {
            owners[id] = "a plug-in compiled into Tingra"
        }
        var loaded: [PlugInBundle] = []
        var problems: [PlugInBundleProblem] = []
        for url in folders.flatMap(bundleURLs(in:)) {
            let outcome = load(url, owners: owners)
            problems += outcome.problems
            if let bundle = outcome.bundle {
                owners[bundle.plugIn.id] = "the bundle at \(bundle.displayPath)"
                loaded.append(bundle)
            }
        }
        for problem in problems {
            eventBus.error("plugin.bundle", domain: .plugIn, params: problem.eventParams)
        }
        return PlugInBundleScan(loaded: loaded, problems: problems)
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

    /// Admits, loads, and instantiates one bundle, or says why not.
    ///
    /// - Parameters:
    ///   - url: The bundle's directory.
    ///   - owners: Who holds each id taken so far, for the duplicate rule's
    ///     message.
    /// - Returns: The loaded bundle, if any, and every problem found.
    func load(_ url: URL, owners: [PlugInID: String]) -> (bundle: PlugInBundle?, problems: [PlugInBundleProblem]) {
        let name = url.lastPathComponent
        /// A result refusing the bundle for one reason.
        func refusal(_ reason: PlugInBundleProblem.Reason, id: String?, _ message: String) -> (
            bundle: PlugInBundle?, problems: [PlugInBundleProblem]
        ) {
            (nil, [PlugInBundleProblem(reason: reason, url: url, id: id, message: message)])
        }

        guard let info = opener.info(ofBundleAt: url) else {
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
        switch signatures.verdict(forBundleAt: url) {
        case .valid:
            break
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

        let principalClass: AnyClass?
        do {
            principalClass = try opener.loadPrincipalClass(ofBundleAt: url)
        } catch {
            return (
                nil,
                problems + [
                    PlugInBundleProblem(
                        reason: .loadFailed, url: url, id: declaredID,
                        message: Self.loadFailedMessage(name: name, error: error))
                ]
            )
        }
        guard let plugInType = principalClass as? any BundledPlugIn.Type else {
            let named = info.principalClassName.map { "NSPrincipalClass is '\($0)'" } ?? "it sets no NSPrincipalClass"
            return (
                nil,
                problems + [
                    PlugInBundleProblem(
                        reason: .noPrincipalClass, url: url, id: declaredID,
                        message:
                            "'\(name)' has no principal class conforming to BundledPlugIn (\(named)). Set "
                            + "NSPrincipalClass to the module-qualified name of a class conforming to BundledPlugIn, "
                            + "such as 'MyPlugIn.MyPlugIn'.")
                ]
            )
        }
        let plugIn = plugInType.init()
        guard plugIn.id == id else {
            return (
                nil,
                problems + [
                    PlugInBundleProblem(
                        reason: .idMismatch, url: url, id: declaredID,
                        message:
                            "'\(name)' declares the plug-in id '\(declaredID)' in its Info.plist, but its principal "
                            + "class reports '\(plugIn.id.rawValue)'. Make the two agree.")
                ]
            )
        }
        return (PlugInBundle(plugIn: plugIn, url: url), problems)
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

    /// The refusal message for code that would not load, carrying dyld's own
    /// explanation (Foundation puts it in the error's debug description).
    static func loadFailedMessage(name: String, error: any Error) -> String {
        let nsError = error as NSError
        let detail = (nsError.userInfo[NSDebugDescriptionErrorKey] as? String) ?? nsError.localizedDescription
        return "'\(name)' could not be loaded: \(detail). 'Symbol not found' means the bundle uses plug-in kit "
            + "API newer than this Tingra's; a code signature error means the system refused the bundle's signature."
    }
}
