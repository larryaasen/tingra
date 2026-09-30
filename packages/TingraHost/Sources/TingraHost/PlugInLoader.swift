//
//  PlugInLoader.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraPlugInKit

/// The host's plug-in lifecycle: activates plug-ins against a
/// `PlugInContext` and reports each outcome on the event bus.
///
/// First-party plug-ins are compiled in; third-party ones arrive as bundles
/// through ``PlugInBundleLoader``, and both activate through this same path,
/// so a bundle has no second lifecycle (see ARCHITECTURE.md, "Engine model:
/// host and plug-ins", and PLUGINS.md, Decision 23).
public struct PlugInLoader: Sendable {
    /// Creates a loader. Stateless — the context carries everything
    /// activation needs.
    public init() {}

    /// The `tier` param on every event this loader emits. The host tier is
    /// the in-process engine; the app tier's loader reports `"app"`.
    static let tier = "host"

    /// Activates each plug-in in order.
    ///
    /// A plug-in that throws is reported as an `error` event and skipped;
    /// the remaining plug-ins load normally — a plug-in must never take
    /// down the host or another plug-in (CLAUDE.md, never-crash rule).
    ///
    /// Both events carry `tier: "host"`: the app emits the same event names
    /// with `tier: "app"` for its out-of-process app-tier plug-ins (see
    /// PLUGINS.md, "Launch on demand"), so a log reader can tell them apart.
    ///
    /// - Returns: The plug-ins that activated successfully.
    @discardableResult
    public func activate(_ plugIns: [any PlugIn], in context: PlugInContext) async -> [any PlugIn] {
        await activateReporting(plugIns, in: context).filter { $0.error == nil }.map(\.plugIn)
    }

    /// Activates each plug-in in order, as ``activate(_:in:)`` does, keeping
    /// every outcome for a ``PlugInLoadReport``.
    ///
    /// - Returns: Each plug-in with what its `activate` threw, if anything.
    func activateReporting(_ plugIns: [any PlugIn], in context: PlugInContext) async -> [PlugInActivationOutcome] {
        var outcomes: [PlugInActivationOutcome] = []
        for plugIn in plugIns {
            let error = await activate(plugIn, params: [:], in: context)
            outcomes.append(PlugInActivationOutcome(plugIn: plugIn, url: nil, error: error))
        }
        return outcomes
    }

    /// Activates each loaded bundle's plug-in in order, exactly as
    /// ``activate(_:in:)`` does a compiled-in one.
    ///
    /// Both events also carry `source: "bundle"` and the bundle's `path`
    /// (home folder as `~`), so a log reader can tell a third-party plug-in
    /// from a first-party one (PLUGINS.md, Decision 26).
    ///
    /// - Returns: The plug-ins that activated successfully.
    @discardableResult
    public func activate(bundles: [PlugInBundle], in context: PlugInContext) async -> [any PlugIn] {
        var activated: [any PlugIn] = []
        for bundle in bundles where await activate(bundle, in: context).error == nil {
            activated.append(bundle.plugIn)
        }
        return activated
    }

    /// Activates one loaded bundle's plug-in, reporting it with its source
    /// and path.
    ///
    /// - Returns: The outcome, carrying the bundle's path.
    private func activate(_ bundle: PlugInBundle, in context: PlugInContext) async -> PlugInActivationOutcome {
        let params: [String: EventValue] = ["source": .string("bundle"), "path": .string(bundle.displayPath)]
        let error = await activate(bundle.plugIn, params: params, in: context)
        return PlugInActivationOutcome(plugIn: bundle.plugIn, url: bundle.url, error: error)
    }

    /// Activates the compiled-in plug-ins, then loads the plug-in bundles
    /// and activates those — the order every front end uses (PLUGINS.md,
    /// Decision 27).
    ///
    /// The compiled-in plug-ins' ids are taken before the scan, so a bundle
    /// declaring one of them is refused as a duplicate: first party wins.
    /// Each bundle is activated as soon as it loads, before the next one
    /// loads, so a bundle that takes the process down in its `activate` is
    /// the one the load-crash guard names (PLUGINS.md, Decision 33).
    ///
    /// - Parameters:
    ///   - plugIns: The compiled-in plug-ins.
    ///   - bundleLoader: What finds and admits the bundles.
    ///   - context: What every plug-in activates against.
    /// - Returns: Every plug-in that activated, compiled-in ones first, what
    ///   the bundle scan found, and the two joined as a report.
    @discardableResult
    public func activate(
        _ plugIns: [any PlugIn],
        thenBundlesFrom bundleLoader: PlugInBundleLoader,
        in context: PlugInContext
    ) async -> PlugInActivation {
        let compiledIn = await activateReporting(plugIns, in: context)
        var bundles: [PlugInActivationOutcome] = []
        let scan = await bundleLoader.load(skipping: Set(plugIns.map(\.id)), reportingTo: context.eventBus) {
            bundle in
            bundles.append(await activate(bundle, in: context))
        }
        let activated = (compiledIn + bundles).filter { $0.error == nil }.map(\.plugIn)
        let report = PlugInLoadReport(compiledIn: compiledIn, bundles: bundles, scan: scan, loader: bundleLoader)
        return PlugInActivation(activated: activated, scan: scan, report: report)
    }

    /// Activates one plug-in and reports the outcome, adding `params` to
    /// both events.
    ///
    /// - Returns: What `activate` threw, described, or `nil` when the
    ///   plug-in activated.
    private func activate(_ plugIn: any PlugIn, params: [String: EventValue], in context: PlugInContext) async
        -> String?
    {
        var eventParams = params
        eventParams["id"] = .string(plugIn.id.rawValue)
        eventParams["name"] = .string(plugIn.name)
        eventParams["tier"] = .string(Self.tier)
        do {
            try await plugIn.activate(in: context)
            context.eventBus.event("plugin.activated", domain: .plugIn, params: eventParams)
            return nil
        } catch {
            let description = String(describing: error)
            eventParams["error"] = .string(description)
            context.eventBus.error("plugin.activation", domain: .plugIn, params: eventParams)
            return description
        }
    }
}

/// What a front end's plug-in activation produced: the plug-ins that
/// activated, what the bundle scan found, and the two joined as a report.
public struct PlugInActivation: Sendable {
    /// Every plug-in that activated, compiled-in ones first, then bundles in
    /// scan order.
    public let activated: [any PlugIn]

    /// What the bundle scan found: the bundles loaded, the problems, and the
    /// bundles skipped.
    public let scan: PlugInBundleScan

    /// Every plug-in met, each in one state — what `tingra-cli plug-ins`
    /// lists (PLUGINS.md, Decision 35).
    public let report: PlugInLoadReport
}
