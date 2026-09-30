//
//  SafeModeLaunch.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import TingraEventBus
import TingraHost

/// How this launch treats plug-in bundles, normally or in safe mode and why,
/// decided before the engine boots (PLUGINS.md, Decisions 31 and 32).
///
/// Safe mode loads no plug-in bundles for this one launch and changes
/// nothing else: the plug-ins built into Tingra load as always, app-tier
/// plug-ins are untouched, and nothing is persisted.
struct SafeModeLaunch: Equatable, Sendable {
    /// The operator's answer to the offer made after an unclean exit.
    enum OfferAnswer: String, Equatable, Sendable {
        /// Open in Safe Mode, the default button.
        case safeMode
        /// Open Normally.
        case normally
    }

    /// Why this launch is in safe mode, or `nil` for a normal launch.
    var trigger: PlugInSafeModeTrigger?

    /// The answer to the offer, when it was made.
    var offerAnswer: OfferAnswer?

    /// A normal launch, with no offer made.
    static let normal = SafeModeLaunch()

    /// Decides the launch from what it found.
    ///
    /// Shift held while the app opened wins, and no question is asked: the
    /// operator already chose. Otherwise a record of bundles the last run
    /// loaded means it ended without terminating, and the operator is asked.
    /// There is never an automatic safe mode, since a bug in Tingra's own
    /// code must not silently drop every plug-in.
    ///
    /// - Parameters:
    ///   - shiftHeld: Whether Shift was held as the app opened.
    ///   - lastRunBundles: The bundles the last run loaded, when it left a
    ///     record (``PlugInLaunchRecord``).
    ///   - ask: Asks the operator, naming the bundles.
    static func decide(
        shiftHeld: Bool, lastRunBundles: [String]?, ask: ([String]) -> OfferAnswer
    ) -> SafeModeLaunch {
        if shiftHeld {
            return SafeModeLaunch(trigger: .shiftKey)
        }
        guard let lastRunBundles else { return .normal }
        let answer = ask(lastRunBundles)
        return SafeModeLaunch(trigger: answer == .safeMode ? .afterUncleanExit : nil, offerAnswer: answer)
    }

    /// Reports the offer's answer as the click it was.
    ///
    /// The alert runs before the engine boots, when the bus has no sinks, so
    /// the click is reported here, once they are attached and before the
    /// `plugin.safeMode` event it caused — the `tap` convention's order,
    /// input before effect (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameter eventBus: The bus, its sinks attached.
    func reportOfferTap(on eventBus: EventBus) {
        switch offerAnswer {
        case .safeMode:
            eventBus.tap("uncleanExitSafeMode.button", domain: .plugIn)
        case .normally:
            eventBus.tap("uncleanExitNormal.button", domain: .plugIn)
        case nil:
            break
        }
    }
}

/// The question the app asks at launch after its last run ended without
/// terminating while plug-in bundles were loaded (PLUGINS.md, Decision 32).
enum UncleanExitAlert {
    /// Asks, app-modally, before any window exists or the engine boots.
    ///
    /// - Parameter bundles: The bundles the last run loaded.
    /// - Returns: The operator's answer.
    @MainActor
    static func ask(bundles: [String]) -> SafeModeLaunch.OfferAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Tingra quit unexpectedly while plug-ins you installed were loaded.",
            comment: "Launch alert title after the app's last run ended while plug-in bundles were loaded")
        alert.informativeText = informativeText(bundles: bundles)
        alert.addButton(
            withTitle: String(
                localized: "Open in Safe Mode",
                comment: "Launch alert button: open the app without the plug-ins the operator installed"))
        alert.addButton(
            withTitle: String(
                localized: "Open Normally", comment: "Launch alert button: open the app with its plug-ins as usual"))
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .safeMode : .normally
    }

    /// The alert's text: which plug-ins were loaded, when the record named
    /// them, and what safe mode does.
    ///
    /// - Parameter bundles: The bundles' directory names.
    static func informativeText(bundles: [String]) -> String {
        let explanation = String(
            localized:
                "Safe mode opens Tingra without the plug-ins you installed, for this launch only. Nothing is removed.",
            comment: "Launch alert text explaining safe mode")
        let names = bundles.map { ($0 as NSString).deletingPathExtension }
        guard !names.isEmpty else { return explanation }
        let loaded = String(
            localized: "Loaded plug-ins: \(names.formatted(.list(type: .and))).",
            comment: "Launch alert text naming the plug-in bundles the last run loaded; the placeholder is their names")
        return loaded + "\n\n" + explanation
    }
}
