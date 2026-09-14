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
}

/// Serves the app tier's `tingra/*` methods for one plug-in's connection
/// (PLUGINS.md, Decision 14; `AppTierMethod`): storage reads and writes
/// against the plug-in's own scopes — the plug-in id is the connection's,
/// never a param, so a plug-in cannot reach another's data — and events,
/// landed on the bus under the plug-in's domain.
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
