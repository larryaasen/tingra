//
//  TingraCamerasMain.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import SwiftUI
import TingraHost

/// The process entry point: answers `--version` and exits, or starts the app.
///
/// It sits in front of ``TingraCamerasApp`` rather than inside it because
/// creating the `App` value creates its state — the hardware model and the
/// capture engine behind it — and a version request must reach none of that:
/// it has to answer on a build machine with no window server session, no
/// cameras, and no operator (RELEASE.md, C11). Tingra.app's `TingraMain` does
/// the same, by the same rule in ``LaunchArguments``.
@main
enum TingraCamerasMain {
    /// Prints the version and exits when the command line asks for it;
    /// otherwise hands the process to ``TingraCamerasApp``.
    ///
    /// A bundle that names no version exits 1 with the reason on standard
    /// error, so the release stops on a build-configuration defect instead
    /// of comparing an empty line.
    static func main() {
        guard LaunchArguments.asksForVersion(CommandLine.arguments) else {
            TingraCamerasApp.main()
            return
        }
        guard let line = LaunchArguments.versionLine(for: AppVersion()) else {
            FileHandle.standardError.write(
                Data("Tingra Cameras: the app bundle names no CFBundleShortVersionString.\n".utf8))
            exit(1)
        }
        print(line)
        exit(0)
    }
}
