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
    /// The replacement value the bus substitutes for sensitive params.
    public static let redactedValue = "<redacted>"

    /// The suffixes that mark a param key as sensitive: a key that equals or
    /// ends with one of these (case insensitively) has its value redacted by
    /// ``redacting(_:)``. Suffix matching is deliberate so `streamKey`,
    /// `apiToken`, and the like are caught without enumerating every spelling.
    private static let sensitiveKeySuffixes = ["key", "token", "password", "secret", "credential"]

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
    ///   - params: Structured payload; sensitive keys are redacted here,
    ///     before any sink sees the event.
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
            params: Self.redacting(params),
            from: "\(fileID):\(function)"
        )
        let continuations = subscriptions.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield(event)
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

    // MARK: - Redaction

    /// Returns a copy of `params` with every sensitive value replaced by
    /// ``redactedValue``, so no sink ever sees a secret.
    ///
    /// This is redaction layer 2 of EVENTS.md — bus level defense in depth,
    /// protection against a careless plug-in. Layer 1 is policy (secrets
    /// never become event params at all); layer 3 is the OSLog sink's
    /// `.private` interpolation. A param is sensitive when its key matches
    /// ``sensitiveKeySuffixes``.
    private static func redacting(_ params: [String: EventValue]?) -> [String: EventValue]? {
        guard let params else { return nil }
        return params.reduce(into: [:]) { result, pair in
            let key = pair.key.lowercased()
            let isSensitive = sensitiveKeySuffixes.contains { key == $0 || key.hasSuffix($0) }
            result[pair.key] = isSensitive ? .string(redactedValue) : pair.value
        }
    }
}
