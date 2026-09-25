//
//  PlugInKitVersion.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A version of this plug-in kit, `MAJOR.MINOR.PATCH` (ARCHITECTURE.md,
/// "Plug-in API stability and versioning").
///
/// A host-tier plug-in bundle declares the kit version it was built against
/// in its Info.plist, under `com.moonwink.tingra.plug-in.kit-version`, and
/// the host compares that with ``current`` before loading any of the
/// bundle's code (PLUGINS.md, Decision 24). A bundle built against a newer
/// kit than the host's would otherwise reach dyld and die there with
/// `Symbol not found`; comparing first turns that into an error naming both
/// versions and the fix.
public struct PlugInKitVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The kit version this build carries. Raised with every kit tag
    /// (`plugin-kit-<x.y.z>`); a bundle's Info.plist names the value its
    /// SDK carried.
    public static let current = PlugInKitVersion(major: 0, minor: 1, patch: 0)

    /// Incremented for a change that breaks existing plug-ins.
    public let major: Int

    /// Incremented for additions that existing plug-ins keep working
    /// through.
    public let minor: Int

    /// Incremented for fixes that change no API.
    public let patch: Int

    /// Creates a version from its three numbers.
    ///
    /// - Parameters:
    ///   - major: The major version.
    ///   - minor: The minor version.
    ///   - patch: The patch version.
    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses a version string of two or three non-negative integers
    /// separated by dots (`"1.2.3"`, or `"1.2"` meaning `1.2.0`).
    ///
    /// - Parameter string: The version as a bundle's Info.plist declares it.
    /// - Returns: `nil` when the string is not such a version.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // Digits only: `Int` alone would also take a sign (`"+1"`).
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count == 3 ? numbers[2] : 0)
    }

    /// The version as `MAJOR.MINOR.PATCH`.
    public var description: String { "\(major).\(minor).\(patch)" }

    /// Orders versions by major, then minor, then patch.
    public static func < (lhs: PlugInKitVersion, rhs: PlugInKitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
