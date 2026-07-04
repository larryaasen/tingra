//
//  Version.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser

/// The product version. The versioning scheme (and how release builds stamp
/// it) is an open item in TODO.md; this constant is the single place it
/// lives meanwhile.
enum TingraCLIVersion {
    static let current = "0.0.1-dev"
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
