//
//  PlugInMethodHandler.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
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
/// plug-in's own Keychain items — the plug-in id is the connection's, never
/// a param, so a plug-in cannot reach another's data — and events, landed
/// on the bus under the plug-in's domain. A secret's value passes through
/// here and nowhere else: never into an event, an error message, or a log.
final class PlugInMethodHandler: SessionMethodHandler {
    /// The plug-in this connection belongs to.
    private let plugIn: PlugInID

    /// The bus events land on.
    private let eventBus: EventBus

    /// Where the plug-in's values live.
    private let storage: any PlugInStoring

    /// Creates the handler for one plug-in's connection.
    ///
    /// - Parameters:
    ///   - plugIn: The plug-in this connection belongs to.
    ///   - eventBus: The bus events land on.
    ///   - storage: Where the plug-in's values live.
    init(plugIn: PlugInID, eventBus: EventBus, storage: any PlugInStoring) {
        self.plugIn = plugIn
        self.eventBus = eventBus
        self.storage = storage
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
        default:
            return nil
        }
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
