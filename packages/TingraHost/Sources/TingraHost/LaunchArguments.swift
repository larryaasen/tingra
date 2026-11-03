//
//  LaunchArguments.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// What an app's process was launched to do, as its command line says.
///
/// One thing, today: `Tingra --version` and `Tingra Cameras --version` print
/// the app's version and exit before the app exists. A release runs it on
/// the signed bundle before notarizing, because it is the only check that
/// executes the binary — a signature the kernel refuses is killed at `exec`,
/// and every inspection of the artifact (`codesign --verify`, the
/// entitlements dump, notarization itself) passes on a bundle that cannot
/// run (RELEASE.md, Decision 8 and C11).
///
/// A pure rule over the arguments rather than a test inside `main`, because
/// what counts as asking is a decision, and a decision is testable where an
/// entry point is not. It lives in the host so both apps share one rule.
public enum LaunchArguments {
    /// The argument that asks for the version.
    public static let versionFlag = "--version"

    /// Whether a command line asks for the version.
    ///
    /// The first element is the executable's own path and is never read as a
    /// flag. Anything else may accompany the flag — Xcode and LaunchServices
    /// both add arguments of their own to a launch.
    ///
    /// - Parameter arguments: The process's arguments, executable first.
    /// - Returns: True when any argument after the first is exactly
    ///   ``versionFlag``.
    public static func asksForVersion(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(versionFlag)
    }

    /// The line `--version` prints for a version, or nil when there is none
    /// to print.
    ///
    /// The marketing version alone, with no build and no product name, so a
    /// script compares it to the number it expects without parsing — the form
    /// `tingra-cli version` prints.
    ///
    /// - Parameter version: The version read from the bundle.
    /// - Returns: The marketing version, or nil when the bundle names none;
    ///   nothing is invented for a bundle missing its version key.
    public static func versionLine(for version: AppVersion) -> String? {
        version.shortVersion
    }
}
