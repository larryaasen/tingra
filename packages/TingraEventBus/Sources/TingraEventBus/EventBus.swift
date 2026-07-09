//
//  EventBus.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization

/// The host's structured event spine.
///
/// A single `EventBus` publishes structured events, and independent
/// subscribers — the sinks — fan them out. No engine or plug-in code ever
/// formats a log message, opens a log file, or imports a logging framework;
/// it calls the bus (see EVENTS.md).
public final class EventBus: Sendable {
    /// The live sink subscriptions, keyed by a per subscription identifier so
    /// a terminated sink can remove exactly its own continuation. Mutex
    /// protected — `send` may be called from any isolation domain.
    private let subscriptions = Mutex<[UUID: AsyncStream<EventBusEvent>.Continuation]>([:])

    /// Creates a bus with no subscribers. The host owns one bus per engine.
    public init() {}

    /// Emits an event to every subscribed sink.
    ///
    /// - Parameters:
    ///   - group: The routing axis — what kind of event this is.
    ///   - domain: The attribution axis — which part of the system emitted it.
    ///   - name: Dotted lowercase identifier, e.g. `stream.started`.
    ///   - params: Structured payload. Secrets must never become params in
    ///     the first place (EVENTS.md, Redaction) — the bus does not
    ///     inspect or alter them.
    ///   - fileID: Captured automatically; do not pass.
    ///   - function: Captured automatically; do not pass.
    public func send(
        _ group: EventGroup,
        domain: EventDomain,
        name: String,
        params: [String: EventValue]? = nil,
        fileID: String = #fileID,
        function: String = #function
    ) {
        let event = EventBusEvent(
            date: Date(),
            group: group,
            domain: domain,
            name: name,
            params: params,
            from: "\(fileID):\(function)"
        )
        let continuations = subscriptions.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    /// Finishes every subscription: each sink's stream delivers what it has
    /// already buffered, then ends, letting its consuming task complete.
    ///
    /// The host calls this once at orderly teardown (the CLI awaits its sink
    /// tasks afterwards so buffered events reach their destination before
    /// the process exits). Emitting after shutdown is harmless — the events
    /// go nowhere.
    public func shutdown() {
        let continuations = subscriptions.withLock { store in
            let values = Array(store.values)
            store.removeAll()
            return values
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Subscribes a sink to the bus.
    ///
    /// Each sink gets its own stream and applies its own filtering; attaching
    /// or detaching a sink never affects emitters or other sinks. Buffering
    /// is unbounded for now — the per sink policy for slow subscribers is an
    /// open question in EVENTS.md (a slow sink must never back pressure the
    /// engine).
    public func events() -> AsyncStream<EventBusEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            subscriptions.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.subscriptions.withLock { $0[id] = nil }
            }
        }
    }

    // MARK: - Per group conveniences

    // One shorthand per group, as in EventBusBasics — adapted to Tingra's
    // domain axis and to `#fileID`/`#function` call site capture in place of
    // `TraceFrame.caller`.

    /// Sends an `EventGroup.app` event.
    public func app(
        _ name: String,
        domain: EventDomain,
        params: [String: EventValue]? = nil,
        fileID: String = #fileID,
        function: String = #function
    ) {
        send(.app, domain: domain, name: name, params: params, fileID: fileID, function: function)
    }

    /// Sends an `EventGroup.error` event.
    public func error(
        _ name: String,
        domain: EventDomain,
        params: [String: EventValue]? = nil,
        fileID: String = #fileID,
        function: String = #function
    ) {
        send(.error, domain: domain, name: name, params: params, fileID: fileID, function: function)
    }

    /// Sends an `EventGroup.event` event.
    public func event(
        _ name: String,
        domain: EventDomain,
        params: [String: EventValue]? = nil,
        fileID: String = #fileID,
        function: String = #function
    ) {
        send(.event, domain: domain, name: name, params: params, fileID: fileID, function: function)
    }

    /// Sends an `EventGroup.network` event.
    public func network(
        _ name: String,
        domain: EventDomain,
        params: [String: EventValue]? = nil,
        fileID: String = #fileID,
        function: String = #function
    ) {
        send(.network, domain: domain, name: name, params: params, fileID: fileID, function: function)
    }

    /// Sends an `EventGroup.tap` event.
    public func tap(
        _ name: String,
        domain: EventDomain,
        params: [String: EventValue]? = nil,
        fileID: String = #fileID,
        function: String = #function
    ) {
        send(.tap, domain: domain, name: name, params: params, fileID: fileID, function: function)
    }

    /// Sends an `EventGroup.trace` event.
    public func trace(
        _ name: String,
        domain: EventDomain,
        params: [String: EventValue]? = nil,
        fileID: String = #fileID,
        function: String = #function
    ) {
        send(.trace, domain: domain, name: name, params: params, fileID: fileID, function: function)
    }
}
