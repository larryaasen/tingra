//
//  PlugInBundleOpening.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// What a host-tier plug-in bundle declares about itself in its Info.plist,
/// read before any of its code runs (PLUGINS.md, Decision 24).
public struct PlugInBundleInfo: Sendable, Equatable {
    /// The `com.moonwink.tingra.plug-in.id` value, when present.
    public var id: String?

    /// The `com.moonwink.tingra.plug-in.kit-version` value, when present.
    public var kitVersion: String?

    /// The `NSPrincipalClass` value, when present, named in a refusal so the
    /// developer sees what the loader looked for.
    public var principalClassName: String?

    /// Creates a bundle's declarations.
    ///
    /// - Parameters:
    ///   - id: The declared plug-in id.
    ///   - kitVersion: The declared kit version.
    ///   - principalClassName: The declared principal class name.
    public init(id: String?, kitVersion: String?, principalClassName: String?) {
        self.id = id
        self.kitVersion = kitVersion
        self.principalClassName = principalClassName
    }
}

/// The seam under ``PlugInBundleLoader`` that touches a bundle on disk:
/// reading its declarations, looking inside it, and loading its code.
///
/// The production conformance is ``FoundationPlugInBundleOpener``. Tests
/// substitute a fake, so the loader's rules — the scan, the plist, the
/// version, the duplicate, and every refusal — are covered without a real
/// bundle (PLUGINS.md, Decision 27).
public protocol PlugInBundleOpening: Sendable {
    /// Reads the bundle's declarations without loading any of its code.
    ///
    /// - Parameter url: The bundle's directory.
    /// - Returns: `nil` when the directory is not a readable bundle (it has
    ///   no Info.plist).
    func info(ofBundleAt url: URL) -> PlugInBundleInfo?

    /// The names (without extension) of the frameworks and libraries the
    /// bundle carries in its own `Contents/Frameworks`.
    ///
    /// - Parameter url: The bundle's directory.
    func embeddedLibraryNames(inBundleAt url: URL) -> [String]

    /// Loads the bundle's code and returns its principal class.
    ///
    /// Code loaded into the process stays there for the process's life:
    /// Swift images cannot be safely unloaded (PLUGINS.md, Decision 27).
    ///
    /// - Parameter url: The bundle's directory.
    /// - Returns: The principal class, or `nil` when the bundle names none
    ///   the runtime can find.
    /// - Throws: The loader's error when the code cannot be loaded — a
    ///   signature the system refuses, or a symbol the running kit lacks.
    func loadPrincipalClass(ofBundleAt url: URL) throws -> AnyClass?
}

/// The production ``PlugInBundleOpening``: `Bundle` for the Info.plist and
/// the load, `FileManager` for the look inside.
public struct FoundationPlugInBundleOpener: PlugInBundleOpening {
    /// Creates the opener. Stateless.
    public init() {}

    /// Reads the three declarations from `Bundle.infoDictionary`, which
    /// parses the Info.plist without loading the bundle's executable.
    public func info(ofBundleAt url: URL) -> PlugInBundleInfo? {
        guard let info = Bundle(url: url)?.infoDictionary else { return nil }
        return PlugInBundleInfo(
            id: info[PlugInBundleLoader.idKey] as? String,
            kitVersion: info[PlugInBundleLoader.kitVersionKey] as? String,
            principalClassName: info["NSPrincipalClass"] as? String
        )
    }

    /// Lists `Contents/Frameworks`, dropping each entry's extension
    /// (`TingraPlugInKit.framework` → `TingraPlugInKit`,
    /// `libTingraPlugInKit.dylib` → `libTingraPlugInKit`). A bundle with no
    /// such folder carries nothing.
    public func embeddedLibraryNames(inBundleAt url: URL) -> [String] {
        let frameworks = url.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path(percentEncoded: false))) ?? []
        return entries.map { ($0 as NSString).deletingPathExtension }
    }

    /// Loads the executable with `Bundle.loadAndReturnError()` — a thrown
    /// error, never a trap, when dyld refuses it — and returns
    /// `Bundle.principalClass`.
    public func loadPrincipalClass(ofBundleAt url: URL) throws -> AnyClass? {
        guard let bundle = Bundle(url: url) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        try bundle.loadAndReturnError()
        return bundle.principalClass
    }
}
