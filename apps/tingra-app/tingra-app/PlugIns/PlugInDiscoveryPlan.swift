//
//  PlugInDiscoveryPlan.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// What a batch from the system's discovery stream means for the app-tier
/// plug-ins already registered: which left, which arrived, and which are the
/// same extension delivered again under an identity that no longer compares
/// equal to the one held.
///
/// **An extension is matched by its bundle identifier, never by identity
/// equality** (2026-10-08). The system re-delivers the whole list while the
/// app runs, and the identity it hands back for an extension already
/// registered does not always equal the first one. Matching by equality
/// took that for a new extension, registered it a second time, and reported
/// "a plug-in with id … is already registered" as an error — 38 times in
/// the app's log, for a Notes plug-in that was working throughout. Such an
/// extension is ``refreshed``: the host keeps its registration and adopts
/// the newer identity for the next process or scene it starts.
///
/// Generic over the identity so the rule is tested without ExtensionKit,
/// whose `AppExtensionIdentity` a test cannot construct.
nonisolated struct PlugInDiscoveryPlan<Identity: Equatable>: Equatable {
    /// An extension as the plan sees it.
    struct Entry: Equatable {
        /// The extension's bundle identifier, which is what names it.
        let bundleIdentifier: String

        /// The identity the system reported for it.
        let identity: Identity
    }

    /// The bundle identifiers of the registered plug-ins the batch no longer
    /// lists, in registration order.
    let retired: [String]

    /// The registered plug-ins the batch lists under an identity unequal to
    /// the one held, in batch order, each carrying the newer identity.
    let refreshed: [Entry]

    /// The extensions the batch lists that are not registered, in batch
    /// order.
    let arrived: [Entry]

    /// Whether the batch changes nothing.
    var isEmpty: Bool { retired.isEmpty && refreshed.isEmpty && arrived.isEmpty }

    /// Compares a batch with what is registered.
    ///
    /// A bundle identifier listed twice in one batch counts once, by its
    /// first entry: the host locates an extension's bundle by that
    /// identifier, so a second copy names the same plug-in.
    ///
    /// - Parameters:
    ///   - registered: The plug-ins registered, in registration order.
    ///   - batch: The extensions the system now lists.
    init(registered: [Entry], batch: [Entry]) {
        var held: [String: Identity] = [:]
        for entry in registered { held[entry.bundleIdentifier] = entry.identity }
        var seen: Set<String> = []
        var refreshed: [Entry] = []
        var arrived: [Entry] = []
        for entry in batch where seen.insert(entry.bundleIdentifier).inserted {
            guard let identity = held[entry.bundleIdentifier] else {
                arrived.append(entry)
                continue
            }
            if identity != entry.identity { refreshed.append(entry) }
        }
        self.retired = registered.map(\.bundleIdentifier).filter { !seen.contains($0) }
        self.refreshed = refreshed
        self.arrived = arrived
    }
}
