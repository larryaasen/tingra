//
//  TerminationReason.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import CoreServices

/// Why the app is quitting, as far as AppKit can say — the `reason` param of
/// the `app.terminating` event ``EngineModel/shutDown(reason:)`` records.
///
/// Every quit that reaches `applicationShouldTerminate` arrives one of two
/// ways: a call to `terminate(_:)` from inside the process (the Quit menu
/// item, ⌘Q), or a **quit Apple event** sent by the system — the Dock's Quit,
/// a script, or the login window on logout, restart, and shutdown, which tag
/// the event with a `kAEQuitReason` parameter. The raw values are the strings
/// the event carries; they are a scripting contract like every other param
/// name, so they do not change casually.
///
/// What this cannot see: a `SIGTERM`, a `SIGKILL` (Force Quit), or a crash
/// bypasses AppKit's quit path entirely, and nothing is recorded — there is
/// no hook to record it from.
enum TerminationReason: String, Sendable, CaseIterable {
    /// `terminate(_:)` was called from inside the app — the Quit menu item or
    /// ⌘Q. The Quit item's own `tap` (`quit.menuItem`) precedes this event
    /// when the menu was the cause.
    case application

    /// A quit Apple event carrying no reason: the Dock's Quit, or a script.
    case quit

    /// A quit Apple event sent to every running app at once (`kAEQuitAll`).
    case quitAll

    /// The user is logging out.
    case logout

    /// The Mac is restarting.
    case restart

    /// The Mac is shutting down.
    case shutdown

    /// The reason a quit Apple event carries, from its `kAEQuitReason`
    /// parameter's enumeration code.
    ///
    /// - Parameter code: The parameter's `enumCodeValue`, or `nil` when the
    ///   event carries no reason.
    /// - Returns: The matching reason; ``quit`` for no code or a code this
    ///   app does not know.
    static func forQuitEvent(reasonCode code: OSType?) -> TerminationReason {
        guard let code else { return .quit }
        switch code {
        case kAEQuitAll:
            return .quitAll
        case kAELogOut, kAEReallyLogOut:
            return .logout
        case kAERestart, kAEShowRestartDialog:
            return .restart
        case kAEShutDown, kAEShowShutdownDialog:
            return .shutdown
        default:
            return .quit
        }
    }

    /// The reason for the quit being handled right now, read from the Apple
    /// event AppKit is dispatching, if a quit event is what brought us here.
    ///
    /// Only meaningful from inside `applicationShouldTerminate`: the current
    /// Apple event is whatever the event manager is dispatching at the time
    /// of the call, which is the quit event when the system sent one and
    /// `nil` when the app called `terminate(_:)` itself.
    static var current: TerminationReason {
        guard
            let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventClass == AEEventClass(kCoreEventClass),
            event.eventID == AEEventID(kAEQuitApplication)
        else { return .application }
        let code = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        return forQuitEvent(reasonCode: code)
    }
}
