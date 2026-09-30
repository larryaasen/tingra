//
//  PlugInOptions.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-09-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import TingraHost

/// The options every command that loads plug-ins shares: today, safe mode
/// (PLUGINS.md, Decisions 31 and 32).
///
/// One option group rather than a flag per command, so `stream`, `probe`,
/// `devices`, `serve`, and `plug-ins` spell it and document it the same way.
struct PlugInOptions: ParsableArguments {
    @Flag(help: "Safe mode: load no plug-in bundles for this run. Plug-ins built into Tingra still load.")
    var safeMode = false

    /// The bundle loader for a command, in safe mode when asked.
    ///
    /// - Parameter command: The command's name, which a crash report names
    ///   as the front end that died (`tingra-cli serve`).
    func bundleLoader(for command: String) -> PlugInBundleLoader {
        PlugInBundleLoader(frontEnd: "tingra-cli \(command)", safeMode: safeMode ? .flag : nil)
    }
}
