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
/// `tingra/*` requests below. The app sends two requests the other way:
/// ``commandPerform``, when the operator invokes a command the plug-in
/// declared, and ``activation``, when a bus event meets an activation
/// condition the plug-in declared.
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

    /// Extension → app request: read one of the plug-in's own secrets from
    /// the app's Keychain-backed secure storage — the narrowed method
    /// PLUGINS.md's Decision 7 deferred, keyed by the connection's plug-in
    /// so a plug-in reads its own secrets and no other's. Params:
    /// ``SecretParam/name``. Result: `{"value": …}`, the secret as a string,
    /// or JSON `null` when none is stored under that name.
    public static let secretsGet = "tingra/secrets.get"

    /// Extension → app request: store or remove one of the plug-in's own
    /// secrets. Params: ``SecretParam/name``, ``SecretParam/value`` (a
    /// string; JSON `null` removes). Result: `{}`. A store that refuses the
    /// write answers with an error, never a silent drop — a plug-in must
    /// know its token was not kept.
    public static let secretsSet = "tingra/secrets.set"

    /// App → extension request: perform a declared command. Params:
    /// ``CommandParam/command``. Result: `{}`.
    public static let commandPerform = "tingra/command.perform"

    /// App → extension request: a bus event met one of the plug-in's
    /// declared activation conditions — the request that launched the
    /// process, when it was not already running. Params:
    /// ``ActivationParam/condition``, ``ActivationParam/event``. Result:
    /// `{}`.
    public static let activation = "tingra/activation"

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

    /// The parameter keys of ``secretsGet`` and ``secretsSet``.
    public enum SecretParam {
        /// The secret's name within the plug-in (`token`): not itself a
        /// secret, and free to appear in events.
        public static let name = "name"

        /// The secret to store (a string; `null` removes), or the secret
        /// read.
        public static let value = "value"
    }

    /// The parameter keys of ``commandPerform``.
    public enum CommandParam {
        /// The command id.
        public static let command = "command"
    }

    /// The parameter keys of ``activation``.
    public enum ActivationParam {
        /// The condition the event met, in its manifest form
        /// (`device.connected:kind=camera`).
        public static let condition = "condition"

        /// The event itself, as `EventBusEvent` encodes to JSON: `date`,
        /// `group`, `domain`, `name`, `params`, `from`.
        public static let event = "event"
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
