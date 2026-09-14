//
//  AppTierProtocol.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The JSON-RPC methods the app tier adds beside MCP's own, spoken over the
/// same connection (PLUGINS.md, Decisions 10 and 14; MCP.md, "The app
/// tier"). The extension is the MCP client: it sends `initialize`,
/// `tools/list`, and `tools/call` exactly as an agent does, plus the
/// `tingra/*` requests below. The app sends one request the other way,
/// ``commandPerform``, when the operator invokes a command the plug-in
/// declared.
///
/// Shared by both sides so a method name is spelled once.
public enum AppTierMethod {
    /// Extension → app notification: an event for the app's bus, landing
    /// under the plug-in's domain. Params: ``EventParam``.
    public static let event = "tingra/event"

    /// Extension → app request: read the plug-in's stored value for a
    /// scope. Params: ``StorageParam/scope``. Result: `{"value": …}` with
    /// JSON `null` when nothing is stored.
    public static let storageGet = "tingra/storage.get"

    /// Extension → app request: replace the plug-in's stored value for a
    /// scope. Params: ``StorageParam/scope``, ``StorageParam/value``
    /// (JSON `null` clears). Result: `{}`.
    public static let storageSet = "tingra/storage.set"

    /// App → extension request: perform a declared command. Params:
    /// ``CommandParam/command``. Result: `{}`.
    public static let commandPerform = "tingra/command.perform"

    /// The parameter keys of ``event``.
    public enum EventParam {
        /// The event name (`notes.edited`).
        public static let name = "name"

        /// The event's params object, optional.
        public static let params = "params"

        /// The event group, optional: `event` (the default) or `error`.
        public static let group = "group"
    }

    /// The parameter keys of ``storageGet`` and ``storageSet``.
    public enum StorageParam {
        /// The scope: ``StorageScope``.
        public static let scope = "scope"

        /// The value to store, or the value read.
        public static let value = "value"
    }

    /// The parameter keys of ``commandPerform``.
    public enum CommandParam {
        /// The command id.
        public static let command = "command"
    }
}

/// Where a plug-in's stored value lives (PLUGINS.md, Decision 7).
public enum StorageScope: String, Sendable, Codable, CaseIterable {
    /// In the project document, under the plug-in's id: travels with the
    /// project, saves with it, dirties it like a layer edit.
    case project

    /// On this Mac, in the app's Application Support folder under the
    /// plug-in's id: the plug-in's own settings.
    case application
}
