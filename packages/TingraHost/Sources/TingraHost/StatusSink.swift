//
//  StatusSink.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus

/// The status sink (see EVENTS.md, "Sinks"): retains the most recent
/// status-bearing events so a reader can report current state without
/// polling the pipeline, and re-broadcasts each one so subscribers are
/// pushed changes as they happen.
///
/// It backs the MCP/Control service's two needs (MCP.md, "Sessions and
/// concurrency"): `stream_status` reads the retained snapshot (a point read
/// of live data, never a poll for state changes), and status changes reach
/// connected MCP sessions as notifications driven off ``updates()``. Only
/// control-plane status events are retained — the `event` and `error` groups
/// (stream lifecycle, device connect/disconnect, errors) — never per-frame
/// traffic, which never reaches the bus at all.
public actor StatusSink: EventSink {
    /// The most recent event of each name, e.g. the latest `stream.stats`.
    /// Keyed by event name so a later event of the same name supersedes the
    /// earlier one — exactly what a status read wants.
    private var latestByName: [String: EventBusEvent] = [:]

    /// The most recent event of each name **per destination**, for the events
    /// a fanned-out stream emits once per leg (`stream.stats` and the
    /// reconnect events carry a `destination` param — see ARCHITECTURE.md,
    /// "Multiple destinations"). Keyed name → destination id → event.
    ///
    /// Kept beside ``latestByName`` rather than replacing it: a reader that
    /// wants "the latest stats" still gets one, and a reader that wants each
    /// destination's own can have that too, instead of one leg's numbers
    /// silently standing in for another's.
    private var latestByDestination: [String: [String: EventBusEvent]] = [:]

    /// Live subscribers to the broadcast stream, keyed so a terminated
    /// subscription removes exactly its own continuation.
    private var subscribers: [UUID: AsyncStream<EventBusEvent>.Continuation] = [:]

    /// Creates an empty status sink. The host owns one per engine that
    /// exposes MCP status.
    public init() {}

    /// Retains and re-broadcasts a status-bearing event; ignores everything
    /// else.
    public func receive(_ event: EventBusEvent) async {
        guard Self.isStatus(event) else { return }
        latestByName[event.name] = event
        if let destination = Self.destination(of: event) {
            latestByDestination[event.name, default: [:]][destination] = event
        }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    /// The most recent retained event of the given name, or nil if none has
    /// been seen — how `stream_status` reads the latest `stream.stats`.
    ///
    /// With a fanned-out stream several destinations emit this name, and the
    /// most recent one wins whichever leg it came from; read
    /// ``latestEvent(named:forDestination:)`` when the leg matters.
    public func latestEvent(named name: String) -> EventBusEvent? {
        latestByName[name]
    }

    /// The most recent retained event of the given name for one destination
    /// leg, or nil if that leg has emitted none.
    ///
    /// - Parameters:
    ///   - name: The event name, e.g. `stream.stats`.
    ///   - destination: The leg id carried in the event's `destination` param.
    /// - Returns: That leg's latest event of the name, or nil.
    public func latestEvent(named name: String, forDestination destination: String) -> EventBusEvent? {
        latestByDestination[name]?[destination]
    }

    /// Every destination's most recent event of the given name, keyed by leg
    /// id — the whole fan-out's current state in one read.
    ///
    /// - Parameter name: The event name, e.g. `stream.stats`.
    /// - Returns: Leg id → that leg's latest event; empty when none has been
    ///   seen.
    public func latestEventsByDestination(named name: String) -> [String: EventBusEvent] {
        latestByDestination[name] ?? [:]
    }

    /// A snapshot of the most recent event of every retained name — the
    /// full current status, for a reader that wants more than one field.
    public func snapshot() -> [String: EventBusEvent] {
        latestByName
    }

    /// A stream of every status event as it is retained, for a subscriber
    /// that turns status changes into notifications. Each subscriber gets
    /// its own stream; attaching or detaching one never affects others.
    public func updates() -> AsyncStream<EventBusEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    /// Finishes every broadcast subscription, so subscribing tasks can end
    /// at orderly teardown.
    public func shutdown() {
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    /// Removes a terminated subscription's continuation.
    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Whether an event bears control-plane status worth retaining and
    /// broadcasting: the `event` group (stream/device state changes) and
    /// the `error` group (failures agents must react to).
    private static func isStatus(_ event: EventBusEvent) -> Bool {
        event.group == .event || event.group == .error
    }

    /// The destination leg an event names, when it is one of the per-leg
    /// events a fanned-out stream emits.
    private static func destination(of event: EventBusEvent) -> String? {
        guard case .string(let id) = event.params?["destination"] else { return nil }
        return id
    }
}
