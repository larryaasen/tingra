//
//  DisplayPower.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation
import Synchronization

/// The displays going to sleep or waking — what a display capture needs to
/// know, because ScreenCaptureKit **stops** a capture stream when the
/// displays sleep and never starts it again (ARCHITECTURE.md, "Display
/// capture across display sleep").
enum DisplayPowerEvent: Sendable, Equatable {
    /// The displays went to sleep.
    case slept

    /// The displays woke.
    case woke
}

/// The live display power events, from `NSWorkspace`'s
/// `screensDidSleepNotification` and `screensDidWakeNotification`.
///
/// **Why AppKit, in an engine package.** WindowServer broadcasts display
/// sleep and wake, and those notifications are the only public way to
/// receive the broadcast: the CoreGraphics display reconfiguration callback
/// this package already observes stays silent through a display sleep
/// (measured 2026-09-26 with a probe over a real `pmset displaysleepnow`).
/// The import is confined to this file and serves a notification, not UI.
///
/// **Only an app receives them.** The same probe run as a plain
/// command-line process received neither notification, so under
/// `tingra-cli` a display capture stopped by display sleep stays stopped;
/// the stop is still reported as `input.interrupted`.
enum DisplayPower {
    /// A fresh stream of display power events, in the order they were
    /// posted. Each call is its own subscription; finishing the stream ends
    /// it.
    ///
    /// - Returns: The events.
    static func liveEvents() -> AsyncStream<DisplayPowerEvent> {
        AsyncStream { continuation in
            let token = observe { continuation.yield($0) }
            continuation.onTermination = { _ in
                cancel(token)
            }
        }
    }

    /// The subscribers, keyed so one can leave without disturbing the
    /// others.
    private static let observers = Mutex<[UUID: @Sendable (DisplayPowerEvent) -> Void]>([:])

    /// Whether the workspace observers have been installed.
    private static let isInstalled = Mutex(false)

    /// Adds a subscriber, installing the workspace observers on the first
    /// one.
    ///
    /// **One observer per notification, for the whole process,** the
    /// ``DisplayReconfiguration`` pattern: a sleep and a wake can be posted
    /// within the same millisecond, and separate per-subscriber sequences
    /// could hand them over in either order — a sleep delivered after its
    /// wake would stop the capture the wake had just restarted. The
    /// observers run on the posting thread (`queue: nil`), so the fan-out
    /// sees the notifications in the order WindowServer posted them.
    ///
    /// - Parameter body: Called with each event.
    /// - Returns: A token identifying the subscriber, for ``cancel(_:)``.
    private static func observe(_ body: @escaping @Sendable (DisplayPowerEvent) -> Void) -> UUID {
        let token = UUID()
        observers.withLock { $0[token] = body }
        let needsInstall = isInstalled.withLock { installed -> Bool in
            guard !installed else { return false }
            installed = true
            return true
        }
        if needsInstall {
            let center = NSWorkspace.shared.notificationCenter
            // The observers live as long as the process, like the
            // CoreGraphics callback: removing them would race a concurrent
            // subscription, and with no subscribers they do nothing.
            _ = center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { _ in
                fanOut(.slept)
            }
            _ = center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { _ in
                fanOut(.woke)
            }
        }
        return token
    }

    /// Removes a subscriber.
    ///
    /// - Parameter token: The token ``observe(_:)`` returned.
    private static func cancel(_ token: UUID) {
        observers.withLock { $0[token] = nil }
    }

    /// Hands an event to every subscriber.
    ///
    /// - Parameter event: The event.
    private static func fanOut(_ event: DisplayPowerEvent) {
        for body in observers.withLock({ Array($0.values) }) {
            body(event)
        }
    }
}
