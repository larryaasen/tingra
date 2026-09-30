//
//  PlugInBundleSkip.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus
import TingraPlugInKit

/// A host-tier plug-in bundle the loader admitted but did not load, and why.
///
/// Each is reported as an `event` named `plugin.skipped`, domain `plugIn`,
/// carrying the stable ``reason``, the plug-in's `id`, and the bundle's
/// `path` (PLUGINS.md, Decisions 31 and 34). A skipped bundle passed every
/// check a refusal would have caught; nothing but the reason keeps it out.
public struct PlugInBundleSkip: Sendable, Equatable {
    /// Why a bundle was skipped. The raw values are the `reason` param — a
    /// scripting contract, stable across releases.
    public enum Reason: String, Sendable, CaseIterable {
        /// The operator turned the plug-in off.
        case disabled
        /// A process died while loading or activating this build of the
        /// bundle.
        case crashed
        /// This launch is in safe mode, which loads no plug-in bundles.
        case safeMode
        /// The enablement file, `plug-ins.json`, could not be read, so the
        /// loader cannot tell which bundles are turned off and loads none.
        case enablementUnreadable
    }

    /// Why.
    public let reason: Reason

    /// The bundle's directory.
    public let url: URL

    /// The plug-in the bundle declares.
    public let id: PlugInID

    /// Creates a skip report.
    ///
    /// - Parameters:
    ///   - reason: Why.
    ///   - url: The bundle's directory.
    ///   - id: The plug-in the bundle declares.
    public init(reason: Reason, url: URL, id: PlugInID) {
        self.reason = reason
        self.url = url
        self.id = id
    }

    /// The bundle's path with the home folder abbreviated to `~`.
    public var displayPath: String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    /// The `plugin.skipped` event's params.
    var eventParams: [String: EventValue] {
        [
            "reason": .string(reason.rawValue),
            "id": .string(id.rawValue),
            "path": .string(displayPath),
            "tier": .string(PlugInLoader.tier),
        ]
    }
}

/// Why a launch is in safe mode, which loads no plug-in bundles for that one
/// launch (PLUGINS.md, Decisions 31 and 32). The raw values are the
/// `plugin.safeMode` event's `trigger` param, a stable contract.
public enum PlugInSafeModeTrigger: String, Sendable, CaseIterable {
    /// The operator held Shift while the app opened.
    case shiftKey
    /// The operator chose Open in Safe Mode, offered after the app's last run
    /// ended while plug-in bundles were loaded.
    case afterUncleanExit
    /// The operator passed `--safe-mode` to a CLI command.
    case flag
}
