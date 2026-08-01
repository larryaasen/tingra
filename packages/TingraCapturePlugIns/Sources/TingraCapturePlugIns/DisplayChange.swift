//
//  DisplayChange.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Foundation
import Synchronization
import TingraEventBus
import TingraPlugInKit

/// One display connection or disconnection, as observed by the capture
/// plug-in — a normal event, never an error (CLAUDE.md, Data Flow Rules).
///
/// The display counterpart to ``DeviceChange``, deliberately the same shape:
/// both feed the same `device.connected` / `device.disconnected` event names,
/// so nothing downstream needs to know which framework noticed.
struct DisplayChange: Sendable, Equatable {
    /// Which way the display went.
    enum Kind: Sendable {
        /// The display appeared.
        case connected

        /// The display went away.
        case disconnected
    }

    /// Whether the display connected or disconnected.
    let kind: Kind

    /// The display that changed.
    let display: DisplayDevice
}

/// Keeps the input registry current as displays come and go, and reports each
/// change as a `device.connected` / `device.disconnected` event on the bus.
///
/// The display twin of ``DeviceEventReporter``, and deliberately its mirror
/// image: same registry-before-event ordering, same event names with
/// `kind=display`, same injected-stream test seam. Event driven end to end —
/// the production stream is CoreGraphics' display reconfiguration callback,
/// never polling (CLAUDE.md, General Guidelines).
struct DisplayEventReporter: Sendable {
    /// The changes to report; injected so tests script the timeline.
    private let changes: AsyncStream<DisplayChange>

    /// Builds the input for a newly connected display (the plug-in's display
    /// factory).
    private let makeInput: @Sendable (DisplayDevice) -> any Input

    /// Creates a reporter over a change stream and an input factory.
    init(changes: AsyncStream<DisplayChange>, makeInput: @escaping @Sendable (DisplayDevice) -> any Input) {
        self.changes = changes
        self.makeInput = makeInput
    }

    /// For each change until the stream finishes: updates the registry first
    /// (register on connect, unregister on disconnect), then emits the event
    /// — so a listener reacting to the event always sees the registry already
    /// reflecting it, which is what lets a consumer rebuild from the registry
    /// rather than from the event's params.
    ///
    /// - Parameters:
    ///   - eventBus: The bus the changes are reported on.
    ///   - inputs: The registry to keep current.
    func run(on eventBus: EventBus, inputs: any InputRegistering) async {
        for await change in changes {
            switch change.kind {
            case .connected:
                do {
                    try await inputs.register(makeInput(change.display))
                } catch {
                    // Already registered (a display both discovered at
                    // activation and announced by a reconfiguration): the
                    // connection is still a normal event, but leave a trace
                    // for debugging.
                    eventBus.trace(
                        "input.register.skipped",
                        domain: .capture,
                        params: [
                            "id": .string(change.display.uniqueID),
                            "reason": .string(String(describing: error)),
                        ]
                    )
                }
            case .disconnected:
                await inputs.unregister(InputID(rawValue: change.display.uniqueID))
            }
            eventBus.event(
                change.kind == .connected ? "device.connected" : "device.disconnected",
                domain: .capture,
                params: [
                    "id": .string(change.display.uniqueID),
                    "name": .string(change.display.name),
                    "kind": .string(InputKind.display.rawValue),
                ]
            )
        }
    }

    /// The changes between two display snapshots, connections before
    /// disconnections.
    ///
    /// Displays are diffed rather than read from the callback's arguments,
    /// because CoreGraphics hands a reconfiguration callback a
    /// `CGDirectDisplayID` — and a *removed* display's id no longer resolves
    /// to a UUID, which is the only identifier Tingra will use (a
    /// `CGDirectDisplayID` is not stable, see ``DisplayDevice``). Diffing the
    /// snapshot the reporter already holds gives the departing display's full
    /// identity from before it left.
    ///
    /// Identity is the `uniqueID` alone, so a resolution or arrangement
    /// change — which fires the same callback — produces **no** change here,
    /// rather than a spurious disconnect/reconnect pair on a display that
    /// never left.
    ///
    /// - Parameters:
    ///   - previous: The displays last known to be connected.
    ///   - current: The displays connected now.
    /// - Returns: The changes between them, empty when nothing came or went.
    static func changes(from previous: [DisplayDevice], to current: [DisplayDevice]) -> [DisplayChange] {
        let previousIDs = Set(previous.map(\.uniqueID))
        let currentIDs = Set(current.map(\.uniqueID))
        let connected = current.filter { !previousIDs.contains($0.uniqueID) }
            .map { DisplayChange(kind: .connected, display: $0) }
        let disconnected = previous.filter { !currentIDs.contains($0.uniqueID) }
            .map { DisplayChange(kind: .disconnected, display: $0) }
        return connected + disconnected
    }

    /// The production change stream: CoreGraphics' display reconfiguration
    /// callback, diffed against the last known display set. The stream stays
    /// open for the life of the process (or until the consumer cancels).
    ///
    /// - Parameter enumerateDisplays: How to read the connected displays
    ///   (the real CoreGraphics discovery by default; injected in tests).
    /// - Returns: A stream of display connections and disconnections.
    static func liveChanges(
        enumerateDisplays: @escaping @Sendable () -> [DisplayDevice] = DisplayDiscovery.connectedDisplays
    ) -> AsyncStream<DisplayChange> {
        AsyncStream { continuation in
            // Seeded with what is connected now, so the first reconfiguration
            // reports only what actually changed rather than re-announcing
            // every display the plug-in already registered at activation.
            let known = Mutex(enumerateDisplays())
            let token = DisplayReconfiguration.observe {
                let current = enumerateDisplays()
                let changes = known.withLock { previous -> [DisplayChange] in
                    let changes = Self.changes(from: previous, to: current)
                    previous = current
                    return changes
                }
                for change in changes {
                    continuation.yield(change)
                }
            }
            continuation.onTermination = { _ in
                DisplayReconfiguration.cancel(token)
            }
        }
    }
}

/// The one CoreGraphics display-reconfiguration registration, fanned out to
/// its observers.
///
/// CoreGraphics takes a bare C function pointer, which cannot capture
/// context, so the callback has to reach its observers through storage it can
/// find without one. Registering once and fanning out (rather than once per
/// observer) also means the process holds a single system callback however
/// many streams exist.
private enum DisplayReconfiguration {
    /// The registered observers, keyed so one can be removed without
    /// disturbing the others.
    private static let observers = Mutex<[UUID: @Sendable () -> Void]>([:])

    /// Whether the CoreGraphics callback has been installed. CoreGraphics
    /// offers no way to enumerate registrations, so this is tracked here.
    private static let isInstalled = Mutex(false)

    /// Adds an observer, installing the CoreGraphics callback on the first
    /// one.
    ///
    /// - Parameter body: Called after each reconfiguration completes.
    /// - Returns: A token identifying the observer, for ``cancel(_:)``.
    static func observe(_ body: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        observers.withLock { $0[token] = body }
        let needsInstall = isInstalled.withLock { installed -> Bool in
            guard !installed else { return false }
            installed = true
            return true
        }
        if needsInstall {
            // A failure to register is reported by the caller's absence of
            // events rather than by a trap: never crash the host over an
            // optional capability (CLAUDE.md).
            CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        }
        return token
    }

    /// Removes an observer. The CoreGraphics callback stays installed — it is
    /// process-wide and harmless with no observers, and unregistering it
    /// would race a concurrent ``observe(_:)``.
    ///
    /// - Parameter token: The token ``observe(_:)`` returned.
    static func cancel(_ token: UUID) {
        observers.withLock { $0[token] = nil }
    }

    /// Hands a completed reconfiguration to every observer.
    static func fanOut() {
        for body in observers.withLock({ Array($0.values) }) {
            body()
        }
    }
}

/// CoreGraphics' display reconfiguration callback.
///
/// Fires twice per change: once with `beginConfigurationFlag` **before** the
/// change, when the new display set is not yet visible, and again afterwards.
/// Only the second is useful — reading the display list during the first
/// would diff against the state that is about to change and report nothing.
private func displayReconfigured(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DisplayReconfiguration.fanOut()
}
