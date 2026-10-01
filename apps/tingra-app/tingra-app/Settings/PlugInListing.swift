//
//  PlugInListing.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-30.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost
import TingraPlugInKit

/// The Plug-ins settings pane's rows: one per plug-in across both tiers,
/// merged by `PlugInID`, so a plug-in with a host-tier bundle and an
/// app-tier extension is one row (PLUGINS.md, Decisions 3 and 36).
///
/// A value built from what the launch recorded — the host's
/// `PlugInLoadReport` and the app-tier plug-ins the system reported — so
/// the merge is testable without a bundle or an extension on disk.
struct PlugInListing: Equatable {
    /// An app-tier plug-in as the listing needs it.
    struct AppTierPlugIn: Equatable {
        /// The plug-in's id, from its manifest.
        let id: PlugInID

        /// The plug-in's name, from its manifest.
        let name: String

        /// The extension's version, when it declares one.
        let version: String?

        /// Whether the extension is embedded in Tingra.app.
        let isBuiltIn: Bool
    }

    /// Which of the pane's two lists a row belongs to.
    enum Section: Equatable {
        /// Bundles from either plug-in folder, and app-tier plug-ins shipped
        /// in other apps.
        case installed
        /// The plug-ins compiled into Tingra, and the extensions embedded in
        /// it, such as Notes.
        case builtIn
    }

    /// What a host-tier bundle's row offers beside its name.
    enum BundleStanding: Equatable {
        /// Tingra's toggle applies. `wasOn` is whether this launch found the
        /// bundle on — loaded, or kept out only by safe mode — which is what
        /// a changed toggle is compared against to say the change waits for
        /// the next launch.
        case switchable(wasOn: Bool)

        /// The loader refused the bundle: its message, and the bundle's
        /// location for Show in Finder. No toggle: turning a refused bundle
        /// on would change nothing.
        case refused(message: String, url: URL)

        /// The launch could not tell whether the bundle was on, because
        /// `plug-ins.json` could not be read; the skip's message says how to
        /// repair it.
        case undetermined(message: String)
    }

    /// One row.
    struct Row: Identifiable, Equatable {
        /// The row's identity: the plug-in id, or the bundle's path for a
        /// second bundle declaring an id already listed and for a bundle
        /// declaring none.
        let id: String

        /// The plug-in id, when the plug-in declares one.
        let plugInID: PlugInID?

        /// The plug-in's name.
        let name: String

        /// The plug-in's version, when a bundle or extension declares one.
        let version: String?

        /// The list the row belongs to.
        let section: Section

        /// The host-tier bundle's standing, or `nil` for a compiled-in
        /// plug-in or one with only an app-tier half.
        let bundle: BundleStanding?

        /// The error the plug-in's `activate` threw, when it threw.
        let activationError: String?

        /// Defects that did not keep the bundle out, such as an embedded kit.
        let warnings: [String]

        /// Whether the plug-in has an app-tier half, which the system's
        /// switch in Manage… turns on and off.
        let hasAppTierHalf: Bool

        /// Whether the row carries a warning symbol: its bundle was refused,
        /// its standing is unknown, its activation threw, or it has a defect.
        var hasWarning: Bool {
            switch bundle {
            case .refused, .undetermined: return true
            case .switchable, nil: return activationError != nil || !warnings.isEmpty
            }
        }
    }

    /// Every row, installed ones and built-in ones in the pane's order: the
    /// compiled-in plug-ins in activation order, the bundles in scan order,
    /// then the app-tier plug-ins without a bundle, in discovery order.
    let rows: [Row]

    /// The rows under Installed.
    var installed: [Row] { rows.filter { $0.section == .installed } }

    /// The rows under Built In.
    var builtIn: [Row] { rows.filter { $0.section == .builtIn } }

    /// Builds the listing.
    ///
    /// - Parameters:
    ///   - report: The host tier's launch report, or `nil` before the engine
    ///     has booted (the listing then holds only the app tier).
    ///   - appTier: The app-tier plug-ins the system reported.
    init(report: PlugInLoadReport?, appTier: [AppTierPlugIn]) {
        var rows: [Row] = []
        var unclaimed = appTier
        for entry in report?.plugIns ?? [] {
            let plugInID = entry.id.map(PlugInID.init(rawValue:))
            let isFirstForID = plugInID.map { id in !rows.contains { $0.plugInID == id } } ?? false
            var appTierHalf: AppTierPlugIn?
            if isFirstForID, let index = unclaimed.firstIndex(where: { $0.id == plugInID }) {
                appTierHalf = unclaimed.remove(at: index)
            }
            let isBundle = entry.source == .bundle
            rows.append(
                Row(
                    id: isFirstForID ? entry.id ?? "" : "path:\(entry.path ?? entry.name)",
                    plugInID: plugInID,
                    name: entry.name,
                    version: entry.version ?? appTierHalf?.version,
                    section: isBundle ? .installed : .builtIn,
                    bundle: isBundle ? Self.standing(of: entry) : nil,
                    activationError: entry.state == .failed ? entry.message : nil,
                    warnings: entry.warnings,
                    hasAppTierHalf: appTierHalf != nil))
        }
        for plugIn in unclaimed {
            rows.append(
                Row(
                    id: plugIn.id.rawValue, plugInID: plugIn.id, name: plugIn.name, version: plugIn.version,
                    section: plugIn.isBuiltIn ? .builtIn : .installed, bundle: nil, activationError: nil,
                    warnings: [], hasAppTierHalf: true))
        }
        self.rows = rows
    }

    /// A bundle entry's standing: refused bundles and bundles declaring no
    /// id get no toggle, since there is nothing the toggle could key.
    ///
    /// - Parameter entry: A bundle's report entry.
    static func standing(of entry: PlugInLoadReport.Entry) -> BundleStanding {
        let message = entry.message ?? ""
        switch entry.state {
        case .active, .failed:
            return .switchable(wasOn: true)
        case .skipped:
            switch entry.reason.flatMap(PlugInBundleSkip.Reason.init(rawValue:)) {
            case .disabled, .crashed: return .switchable(wasOn: false)
            case .safeMode: return .switchable(wasOn: true)
            case .enablementUnreadable, nil: return .undetermined(message: message)
            }
        case .refused:
            return .refused(message: message, url: fileURL(fromDisplayPath: entry.path ?? ""))
        }
    }

    /// A report's `~` path as a file URL.
    ///
    /// - Parameter displayPath: The path, home folder as `~`.
    static func fileURL(fromDisplayPath displayPath: String) -> URL {
        URL(filePath: (displayPath as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }
}
