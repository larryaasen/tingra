//
//  ApplicationActivity.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation
import Synchronization

/// An application launching or coming to the front — the moment a window
/// input whose window was missing looks for it again.
///
/// macOS posts no notification when a window opens, and reading the window
/// list on a timer is the polling this engine does not do (CLAUDE.md). What
/// it does post is an application launching and an application becoming
/// active, and an operator who opens the window they want captured does one
/// or the other on the way. So those two are the events a waiting window
/// input retries on (ARCHITECTURE.md, "Window capture").
struct ApplicationArrival: Sendable, Equatable {
    /// The bundle identifier of the application that launched or came to
    /// the front.
    let bundleIdentifier: String
}

/// The live application arrivals, from `NSWorkspace`'s
/// `didLaunchApplicationNotification` and
/// `didActivateApplicationNotification`.
///
/// The second AppKit import in this package, for the reason ``DisplayPower``
/// records for the first: the workspace's notification center is the only
/// public place these are posted, the import is confined to this file, and
/// it serves a notification, not UI. **Only an app receives them**, as with
/// display sleep and wake — under `tingra-cli` a window input that finds no
/// window stays waiting.
enum ApplicationActivity {
    /// A fresh stream of application arrivals, in the order they were
    /// posted. Each call is its own subscription; finishing the stream ends
    /// it.
    ///
    /// - Returns: The arrivals.
    static func liveArrivals() -> AsyncStream<ApplicationArrival> {
        AsyncStream { continuation in
            let token = observe { continuation.yield($0) }
            continuation.onTermination = { _ in
                cancel(token)
            }
        }
    }

    /// The subscribers, keyed so one can leave without disturbing the
    /// others.
    private static let observers = Mutex<[UUID: @Sendable (ApplicationArrival) -> Void]>([:])

    /// Whether the workspace observers have been installed.
    private static let isInstalled = Mutex(false)

    /// Adds a subscriber, installing the workspace observers on the first
    /// one — one observer per notification for the whole process, the
    /// ``DisplayPower`` pattern.
    ///
    /// - Parameter body: Called with each arrival.
    /// - Returns: A token identifying the subscriber, for ``cancel(_:)``.
    private static func observe(_ body: @escaping @Sendable (ApplicationArrival) -> Void) -> UUID {
        let token = UUID()
        observers.withLock { $0[token] = body }
        let needsInstall = isInstalled.withLock { installed -> Bool in
            guard !installed else { return false }
            installed = true
            return true
        }
        if needsInstall {
            let center = NSWorkspace.shared.notificationCenter
            // The observers live as long as the process: removing them would
            // race a concurrent subscription, and with no subscribers they
            // do nothing.
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
                _ = center.addObserver(forName: name, object: nil, queue: nil) { notification in
                    let application =
                        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard let bundleIdentifier = application?.bundleIdentifier else { return }
                    fanOut(ApplicationArrival(bundleIdentifier: bundleIdentifier))
                }
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

    /// Hands an arrival to every subscriber.
    ///
    /// - Parameter arrival: The arrival.
    private static func fanOut(_ arrival: ApplicationArrival) {
        for body in observers.withLock({ Array($0.values) }) {
            body(arrival)
        }
    }
}
