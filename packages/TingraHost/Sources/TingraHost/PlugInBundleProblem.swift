//
//  PlugInBundleProblem.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus

/// Something wrong with a host-tier plug-in bundle the loader found: why it
/// was refused, or — for ``Reason-swift.enum/embeddedKit`` alone — a defect
/// in a bundle that loaded anyway.
///
/// Each is reported once as an `error` event named `plugin.bundle`, domain
/// `plugIn`, carrying the stable ``reason``, the bundle's `path`, its `id`
/// when known, and the ``message`` naming the cause and the fix (PLUGINS.md,
/// Decision 26).
public struct PlugInBundleProblem: Sendable, Equatable {
    /// Why a bundle was refused or reported. The raw values are the
    /// `reason` param — a scripting contract, stable across releases.
    public enum Reason: String, Sendable, CaseIterable {
        /// No valid code signature.
        case unsigned
        /// Quarantined, so downloaded, and not notarized.
        case notNotarized
        /// No usable kit version declared, or one this host cannot load.
        case kitVersion
        /// The id is already taken by a compiled-in plug-in or an earlier
        /// bundle.
        case duplicateID
        /// No id declared, or the principal class reports a different one.
        case idMismatch
        /// No principal class conforming to `BundledPlugIn`.
        case noPrincipalClass
        /// Not a readable bundle, or its code would not load.
        case loadFailed
        /// The bundle embeds its own copy of a kit. It still loads, bound to
        /// the host's copy; the problem is reported, not refused.
        case embeddedKit

        /// Whether a problem of this kind keeps the bundle from loading.
        public var refuses: Bool { self != .embeddedKit }
    }

    /// Why.
    public let reason: Reason

    /// The bundle's directory.
    public let url: URL

    /// The plug-in id the bundle declares, when it declares one.
    public let id: String?

    /// The developer-facing explanation: the cause and the fix.
    public let message: String

    /// Creates a problem report.
    ///
    /// - Parameters:
    ///   - reason: Why.
    ///   - url: The bundle's directory.
    ///   - id: The declared plug-in id, when known.
    ///   - message: The cause and the fix.
    public init(reason: Reason, url: URL, id: String?, message: String) {
        self.reason = reason
        self.url = url
        self.id = id
        self.message = message
    }

    /// The bundle's path for display and for event params, with the home
    /// folder abbreviated to `~` so a shared log does not carry the
    /// operator's account name.
    public var displayPath: String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    /// The `plugin.bundle` event's params.
    var eventParams: [String: EventValue] {
        var params: [String: EventValue] = [
            "reason": .string(reason.rawValue),
            "path": .string(displayPath),
            "message": .string(message),
            "tier": .string(PlugInLoader.tier),
        ]
        if let id {
            params["id"] = .string(id)
        }
        return params
    }
}
