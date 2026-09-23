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
/// condition the plug-in declared — and two notifications, ``meters`` and
/// ``frame``, to a connection that asked for them.
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

    /// Extension → app request: give one of the plug-in's declared status
    /// items its text, or take the item off the status bar. Params:
    /// ``StatusItemParam/item``, ``StatusItemParam/text`` (a string; JSON
    /// `null` or an empty string removes the reading). Result: `{}`. An
    /// item the manifest does not declare is invalid params.
    public static let statusItemSet = "tingra/statusItem.set"

    /// Extension → app request: opt this connection in to the ``meters``
    /// notification (PLUGINS.md, Decision 18). No params. Result: `{}`.
    /// Subscribing twice is one subscription; it ends with
    /// ``metersUnsubscribe`` or the connection.
    public static let metersSubscribe = "tingra/meters.subscribe"

    /// Extension → app request: stop the ``meters`` notification on this
    /// connection. No params. Result: `{}`, subscribed or not.
    public static let metersUnsubscribe = "tingra/meters.unsubscribe"

    /// App → extension notification, to a connection that subscribed: every
    /// channel strip's level and the master's, inline, over the window
    /// since the last one — coalesced to at most ten a second, and none
    /// while the mixer is not running. Params: ``MetersParam``, read as
    /// ``MeterLevels``.
    public static let meters = "tingra/meters"

    /// Extension → app request: ask for the next frame of a bus — the
    /// demand half of ``frame`` (PLUGINS.md, "Frames across the boundary").
    /// Params: ``FrameParam/bus``. Result: `{}`, at once; the frame follows
    /// as a ``frame`` notification as soon as the bus has one newer than
    /// the last this connection was sent, which may be now. One demand per
    /// bus is outstanding at a time — asking again before the frame arrives
    /// changes nothing — so frames can never queue behind a slow reader. A
    /// bus the app does not know is invalid params.
    public static let frameNext = "tingra/frame.next"

    /// App → extension notification, answering a ``frameNext``: one frame
    /// of a bus, its `IOSurface` attached to the message beside the JSON
    /// (`SurfaceMessageTransport`) — shared memory, not a copy. Params:
    /// ``FrameParam``, read with the attachment as ``BusFrame``.
    public static let frame = "tingra/frame"

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

    /// The parameter keys of ``statusItemSet``.
    public enum StatusItemParam {
        /// The status item's id within the plug-in.
        public static let item = "item"

        /// The reading's text (a string; `null` removes the reading).
        public static let text = "text"
    }

    /// The parameter keys of ``meters``.
    public enum MetersParam {
        /// The window's last mix tick on the master clock, in seconds.
        public static let time = "time"

        /// An object of each live channel strip's pre-fader level, keyed by
        /// input id.
        public static let strips = "strips"

        /// The program mix's post-fader level: an object of ``left`` and
        /// ``right``.
        public static let master = "master"

        /// The master's left program channel.
        public static let left = "left"

        /// The master's right program channel.
        public static let right = "right"

        /// A level's largest absolute sample value in the window, linear
        /// (`1` is full scale).
        public static let peak = "peak"

        /// A level's root-mean-square over the window, linear.
        public static let rms = "rms"
    }

    /// The parameter keys of ``frameNext`` and ``frame``.
    public enum FrameParam {
        /// The bus: ``FrameBus``.
        public static let bus = "bus"

        /// The frame's time on the master clock, in seconds.
        public static let time = "time"

        /// True when the bus has nothing on it — preview with no shot
        /// staged — and the message carries no surface.
        public static let empty = "empty"
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
