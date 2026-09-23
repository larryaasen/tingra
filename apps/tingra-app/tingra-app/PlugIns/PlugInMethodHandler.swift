//
//  PlugInMethodHandler.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import TingraAppPlugInKit
import TingraEventBus
import TingraJSONRPC
import TingraMCP
import TingraPlugInKit

/// Where an app-tier plug-in's stored values live, by scope — the project
/// document through the engine model, the app's own folder on this Mac —
/// behind a seam so the method handler is tested with an in-memory store.
protocol PlugInStoring: Sendable {
    /// The value a plug-in has stored in `scope`, or nil.
    func value(scope: StorageScope, plugIn: PlugInID) async -> JSONValue?

    /// Replaces the value a plug-in stores in `scope`; nil clears it.
    func setValue(_ value: JSONValue?, scope: StorageScope, plugIn: PlugInID) async

    /// One of the plug-in's own secrets from the app's secure storage, or
    /// nil when none is stored under `name` (PLUGINS.md, Decision 7: never
    /// a storage scope).
    ///
    /// - Throws: The secure store's error when it refuses the read.
    func secret(named name: String, plugIn: PlugInID) async throws -> String?

    /// Stores one of the plug-in's own secrets; nil removes it.
    ///
    /// - Throws: The secure store's error when it refuses the write, so the
    ///   plug-in learns its secret was not kept.
    func setSecret(_ secret: String?, named name: String, plugIn: PlugInID) async throws
}

/// Serves the app tier's `tingra/*` methods for one plug-in's connection
/// (PLUGINS.md, Decision 14; `AppTierMethod`): storage reads and writes
/// against the plug-in's own scopes and secret reads and writes against the
/// plug-in's own Keychain items, and status item texts against the items
/// the plug-in declared — the plug-in id is the connection's, never a param,
/// so a plug-in cannot reach another's data — and events, landed on the bus
/// under the plug-in's domain. A secret's value passes through
/// here and nowhere else: never into an event, an error message, or a log.
///
/// It also sends the two notifications the app tier adds, from the
/// session's open to its close: `tingra/meters` (Decision 18) to a
/// connection that subscribed — the levels inline, no more often than
/// ``metersInterval`` — and `tingra/frame`, one per `tingra/frame.next` the
/// connection sends, a bus's frame with its `IOSurface` attached (PLUGINS.md,
/// "Frames across the boundary").
final class PlugInMethodHandler: SessionMethodHandler {
    /// The plug-in this connection belongs to.
    private let plugIn: PlugInID

    /// The bus events land on.
    private let eventBus: EventBus

    /// Where the plug-in's values live.
    private let storage: any PlugInStoring

    /// Where the plug-in's status item texts go.
    private let statusItems: any PlugInStatusReporting

    /// Where the meters a connection subscribes to come from.
    private let meters: any PlugInMeterFeeding

    /// The least time between two `tingra/meters` notifications.
    private let metersInterval: Duration

    /// Where the frames a connection asks for come from.
    private let frames: any PlugInFrameFeeding

    /// What changes over the session's life, behind a lock: the session
    /// calls the handler from its own actor, not the main one.
    private struct SessionState {
        /// Sends this session's peer a notification, from the session's
        /// open to its close.
        var notifier: SessionNotifier?

        /// The task forwarding the meters, while this connection is
        /// subscribed.
        var metersTask: Task<Void, Never>?

        /// The task answering each bus's outstanding frame demand. One per
        /// bus at most: a demand made while one is outstanding changes
        /// nothing, so frames never queue.
        var frameTasks: [FrameBus: Task<Void, Never>] = [:]

        /// The last change of each bus this connection was sent.
        var frameSequences: [FrameBus: UInt64] = [:]

        /// The buses an unbacked frame was already reported of: once a
        /// session, never once a frame (EVENTS.md, control plane only).
        var unbackedReported: Set<FrameBus> = []
    }

    /// The session's notifier and the meters subscription.
    private let session = Mutex(SessionState())

    /// The least time between two `tingra/meters` notifications: a tenth of
    /// a second, Decision 18's ten a second.
    static let defaultMetersInterval: Duration = .milliseconds(100)

    /// Creates the handler for one plug-in's connection.
    ///
    /// - Parameters:
    ///   - plugIn: The plug-in this connection belongs to.
    ///   - eventBus: The bus events land on.
    ///   - storage: Where the plug-in's values live.
    ///   - statusItems: Where the plug-in's status item texts go.
    ///   - meters: Where the meters a connection subscribes to come from.
    ///   - frames: Where the frames a connection asks for come from.
    ///   - metersInterval: The least time between two meters
    ///     notifications; a test shortens it.
    init(
        plugIn: PlugInID, eventBus: EventBus, storage: any PlugInStoring, statusItems: any PlugInStatusReporting,
        meters: any PlugInMeterFeeding, frames: any PlugInFrameFeeding,
        metersInterval: Duration = PlugInMethodHandler.defaultMetersInterval
    ) {
        self.plugIn = plugIn
        self.eventBus = eventBus
        self.storage = storage
        self.statusItems = statusItems
        self.meters = meters
        self.frames = frames
        self.metersInterval = metersInterval
    }

    func sessionOpened(notifier: SessionNotifier) async {
        session.withLock { $0.notifier = notifier }
    }

    func sessionClosed() async {
        let frameTasks = session.withLock { state -> [Task<Void, Never>] in
            state.notifier = nil
            defer { state.frameTasks = [:] }
            return Array(state.frameTasks.values)
        }
        for task in frameTasks {
            task.cancel()
        }
        stopMeters(reason: "closed")
    }

    func respond(method: String, params: JSONValue?) async throws -> JSONValue? {
        switch method {
        case AppTierMethod.storageGet:
            let scope = try scope(in: params)
            let value = await storage.value(scope: scope, plugIn: plugIn)
            return .object([AppTierMethod.StorageParam.value: value ?? .null])
        case AppTierMethod.storageSet:
            let scope = try scope(in: params)
            let value = params?[AppTierMethod.StorageParam.value]
            await storage.setValue(value == .null ? nil : value, scope: scope, plugIn: plugIn)
            return .object([:])
        case AppTierMethod.secretsGet:
            let name = try secretName(in: params)
            do {
                let secret = try await storage.secret(named: name, plugIn: plugIn)
                return .object([AppTierMethod.SecretParam.value: secret.map(JSONValue.string) ?? .null])
            } catch {
                throw refusedSecret(error, operation: "read", name: name)
            }
        case AppTierMethod.secretsSet:
            let name = try secretName(in: params)
            let secret: String?
            switch params?[AppTierMethod.SecretParam.value] {
            case .none, .some(.null):
                secret = nil
            case .some(.string(let string)):
                secret = string
            default:
                throw JSONRPCError(
                    code: .invalidParams,
                    message: "A secrets.set 'value' must be a string, or null to remove the secret.")
            }
            do {
                try await storage.setSecret(secret, named: name, plugIn: plugIn)
            } catch {
                throw refusedSecret(error, operation: secret == nil ? "remove" : "write", name: name)
            }
            return .object([:])
        case AppTierMethod.statusItemSet:
            guard let item = params?[AppTierMethod.StatusItemParam.item]?.stringValue, !item.isEmpty else {
                throw JSONRPCError(code: .invalidParams, message: "A statusItem.set call needs a non-empty 'item'.")
            }
            let text: String?
            switch params?[AppTierMethod.StatusItemParam.text] {
            case .none, .some(.null):
                text = nil
            case .some(.string(let string)):
                text = string
            default:
                throw JSONRPCError(
                    code: .invalidParams,
                    message: "A statusItem.set 'text' must be a string, or null to remove the reading.")
            }
            do {
                try await statusItems.setText(text, for: StatusItemID(rawValue: item), plugIn: plugIn)
            } catch {
                throw JSONRPCError(code: .invalidParams, message: String(describing: error))
            }
            return .object([:])
        case AppTierMethod.frameNext:
            guard let name = params?[AppTierMethod.FrameParam.bus]?.stringValue, let bus = FrameBus(rawValue: name)
            else {
                throw JSONRPCError(
                    code: .invalidParams,
                    message:
                        "A frame.next call needs a 'bus' of \(FrameBus.allCases.map(\.rawValue).joined(separator: " or "))."
                )
            }
            try demandFrame(of: bus)
            return .object([:])
        case AppTierMethod.metersSubscribe:
            try startMeters()
            return .object([:])
        case AppTierMethod.metersUnsubscribe:
            stopMeters(reason: "unsubscribed")
            return .object([:])
        default:
            return nil
        }
    }

    /// Takes one demand for a bus's next frame: a task waits for the bus to
    /// change past what this connection was last sent — which may be now —
    /// and sends the frame, its surface attached. A demand made while one
    /// is outstanding changes nothing. The first demand of a bus is
    /// reported, so the log says which plug-in is drawing video.
    ///
    /// - Parameter bus: The bus.
    /// - Throws: A `JSONRPCError` when the session has not opened.
    private func demandFrame(of bus: FrameBus) throws {
        let frames = self.frames
        let isFirst = try session.withLock { state -> Bool in
            guard state.frameTasks[bus] == nil else { return false }
            guard let notifier = state.notifier else {
                throw JSONRPCError(
                    code: .internalError, message: "The session has not opened, so frames cannot be sent on it.")
            }
            let isFirst = state.frameSequences[bus] == nil
            var sequence = state.frameSequences[bus] ?? 0
            state.frameTasks[bus] = Task { [weak self] in
                while let update = await frames.next(of: bus, after: sequence) {
                    sequence = update.sequence
                    guard update.isEmpty || update.surface != nil else {
                        // Nothing to hand over: report it and wait for a
                        // frame that has a surface.
                        self?.reportUnbackedFrame(of: bus)
                        continue
                    }
                    // The demand is answered before the frame is sent: the
                    // frame's arrival is what prompts the next demand, and
                    // it must not find this one still outstanding.
                    self?.session.withLock { state in
                        state.frameSequences[bus] = update.sequence
                        state.frameTasks[bus] = nil
                    }
                    let frame = BusFrame(bus: bus, surface: update.surface, time: update.time)
                    if let surface = update.surface {
                        await notifier.notify(AppTierMethod.frame, params: frame.jsonValue, surface: surface)
                    } else {
                        await notifier.notify(AppTierMethod.frame, params: frame.jsonValue)
                    }
                    return
                }
            }
            return isFirst
        }
        guard isFirst else { return }
        eventBus.event(
            "plugin.frames.started", domain: .plugIn,
            params: ["tier": .string("app"), "id": .string(plugIn.rawValue), "bus": .string(bus.rawValue)])
    }

    /// Reports a frame that could not be handed over because its pixel
    /// buffer has no `IOSurface` behind it — a defect upstream, in whatever
    /// made the buffer. Once per bus per session: the defect would repeat
    /// every frame, and the bus carries no per-frame events.
    private func reportUnbackedFrame(of bus: FrameBus) {
        guard session.withLock({ $0.unbackedReported.insert(bus).inserted }) else { return }
        eventBus.error(
            "plugin.frames", domain: .plugIn,
            params: [
                "tier": .string("app"), "id": .string(plugIn.rawValue), "bus": .string(bus.rawValue),
                "reason": .string("the frame's pixel buffer is not IOSurface-backed"),
            ])
    }

    /// Starts forwarding the meters to this connection, unless it already
    /// is: one subscription however often it is asked for.
    ///
    /// - Throws: A `JSONRPCError` when the session has not opened, so there
    ///   is no one to notify — a request cannot arrive then, so this is a
    ///   defect in the caller, named as one.
    private func startMeters() throws {
        let meters = self.meters
        let interval = metersInterval
        let started = try session.withLock { state -> Bool in
            guard state.metersTask == nil else { return false }
            guard let notifier = state.notifier else {
                throw JSONRPCError(
                    code: .internalError, message: "The session has not opened, so meters cannot be sent on it.")
            }
            let levels = meters.levels(every: interval)
            state.metersTask = Task {
                for await window in levels {
                    await notifier.notify(AppTierMethod.meters, params: window.jsonValue)
                }
            }
            return true
        }
        guard started else { return }
        eventBus.event(
            "plugin.meters.subscribed", domain: .plugIn,
            params: ["tier": .string("app"), "id": .string(plugIn.rawValue)])
    }

    /// Stops forwarding the meters, if this connection subscribed.
    ///
    /// - Parameter reason: Why, for the event: `unsubscribed` or `closed`.
    private func stopMeters(reason: String) {
        let task = session.withLock { state -> Task<Void, Never>? in
            defer { state.metersTask = nil }
            return state.metersTask
        }
        guard let task else { return }
        task.cancel()
        eventBus.event(
            "plugin.meters.unsubscribed", domain: .plugIn,
            params: ["tier": .string("app"), "id": .string(plugIn.rawValue), "reason": .string(reason)])
    }

    func handleNotification(method: String, params: JSONValue?) async {
        guard method == AppTierMethod.event else { return }
        guard let name = params?[AppTierMethod.EventParam.name]?.stringValue else {
            eventBus.error(
                "plugin.event", domain: .plugIn,
                params: ["plugIn": .string(plugIn.rawValue), "reason": .string("an event without a name")])
            return
        }
        let eventParams = Self.eventValues(params?[AppTierMethod.EventParam.params])
        let domain = EventDomain(plugIn.rawValue)
        if params?[AppTierMethod.EventParam.group]?.stringValue == "error" {
            eventBus.error(name, domain: domain, params: eventParams)
        } else {
            eventBus.event(name, domain: domain, params: eventParams)
        }
    }

    /// The storage scope a request names.
    ///
    /// - Throws: A `JSONRPCError` naming the valid scopes.
    private func scope(in params: JSONValue?) throws -> StorageScope {
        guard let raw = params?[AppTierMethod.StorageParam.scope]?.stringValue, let scope = StorageScope(rawValue: raw)
        else {
            throw JSONRPCError(
                code: .invalidParams,
                message:
                    "A storage call needs a 'scope' of \(StorageScope.allCases.map(\.rawValue).joined(separator: " or "))."
            )
        }
        return scope
    }

    /// The secret name a request carries: a non-empty string, which is not
    /// itself a secret.
    ///
    /// - Throws: A `JSONRPCError` when the name is missing or empty.
    private func secretName(in params: JSONValue?) throws -> String {
        guard let name = params?[AppTierMethod.SecretParam.name]?.stringValue, !name.isEmpty else {
            throw JSONRPCError(code: .invalidParams, message: "A secrets call needs a non-empty 'name'.")
        }
        return name
    }

    /// A secure store's refusal, reported on the bus as a `plugin.secrets`
    /// error naming the plug-in, the secret's name, and the operation, and
    /// returned as the JSON-RPC error the plug-in is answered with — both
    /// carrying the store's own description, which names no value.
    ///
    /// - Parameters:
    ///   - error: What the store threw.
    ///   - operation: `read`, `write`, or `remove`.
    ///   - name: The secret's name.
    /// - Returns: The error to throw to the session.
    private func refusedSecret(_ error: any Error, operation: String, name: String) -> JSONRPCError {
        let description = String(describing: error)
        eventBus.error(
            "plugin.secrets", domain: .plugIn,
            params: [
                "tier": .string("app"), "id": .string(plugIn.rawValue), "name": .string(name),
                "operation": .string(operation), "error": .string(description),
            ])
        return JSONRPCError(
            code: .internalError,
            message: "The secure store refused to \(operation) the secret '\(name)': \(description)")
    }

    /// Turns an event's JSON params into bus params: scalars as themselves,
    /// anything nested as compact JSON text, so a plug-in's structured
    /// detail still reaches the log.
    static func eventValues(_ params: JSONValue?) -> [String: EventValue]? {
        guard let members = params?.objectValue, !members.isEmpty else { return nil }
        var values: [String: EventValue] = [:]
        for (key, value) in members {
            switch value {
            case .string(let string): values[key] = .string(string)
            case .int(let int): values[key] = .int(int)
            case .double(let double): values[key] = .double(double)
            case .bool(let bool): values[key] = .bool(bool)
            case .null: continue
            case .array, .object:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                if let data = try? encoder.encode(value) {
                    values[key] = .string(String(decoding: data, as: UTF8.self))
                }
            }
        }
        return values.isEmpty ? nil : values
    }
}
