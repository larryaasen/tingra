//
//  TingraMain.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import SwiftUI

/// The process entry point: answers `--version` and exits, or starts the app.
///
/// It sits in front of ``TingraApp`` rather than inside it because creating
/// the `App` value creates its state — the engine model, the plug-in host —
/// and a version request must reach none of that: it has to answer on a
/// build machine with no window server session, no devices, and no operator
/// (RELEASE.md, Decision 8).
@main
enum TingraMain {
    /// Prints the version and exits when the command line asks for it;
    /// otherwise hands the process to ``TingraApp``.
    ///
    /// A bundle that names no version exits 1 with the reason on standard
    /// error, so the release stops on a build-configuration defect instead
    /// of comparing an empty line.
    static func main() {
        guard LaunchArguments.asksForVersion(CommandLine.arguments) else {
            TingraApp.main()
            return
        }
        guard let line = LaunchArguments.versionLine(for: AppVersion()) else {
            FileHandle.standardError.write(
                Data("Tingra: the app bundle names no CFBundleShortVersionString.\n".utf8))
            exit(1)
        }
        print(line)
        exit(0)
    }
}
