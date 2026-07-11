//
//  Version.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser

/// The product version and the monorepo's versioning scheme (see CLI.md,
/// "Distribution" and docs/TODO.md, "Release mechanics").
///
/// - **Product releases** are tagged `v<MAJOR>.<MINOR>.<PATCH>` (e.g.
///   `v0.1.0`); ``current`` holds that number without the `v`, and
///   `tingra-cli version` prints it. `scripts/package-cli.sh` asserts the tag
///   matches ``current`` so the artifact, the embedded Info.plist, and the tag
///   never drift.
/// - **The plug-in protocol package (`TingraPlugInKit`) and `TingraEventBus`
///   SemVer independently** under prefixed tags (`plugin-kit-<x.y.z>`,
///   `event-bus-<x.y.z>`), so the API-stability diff pins the right baseline in
///   a monorepo that ships several products from one tag (CLAUDE.md, "Plug-in
///   API stability and versioning").
/// - **Between releases** `main` carries the next version with a `-dev`
///   suffix; tagging a release drops the suffix, and the next commit bumps to
///   the following `-dev`.
enum TingraCLIVersion {
    /// The product version this build reports. Kept in sync with the release
    /// tag and the embedded Info.plist's `CFBundleShortVersionString`.
    static let current = "0.1.0"
}

/// `tingra-cli version` — print version and build info (see CLI.md).
struct Version: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print version and build info."
    )

    func run() async throws {
        print("tingra-cli \(TingraCLIVersion.current)")
    }
}
