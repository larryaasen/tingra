//
//  AppPlugInHost.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ExtensionFoundation
import ExtensionKit
import Foundation
import Observation
import TingraAppPlugInKit
import TingraEventBus
import TingraHost
import TingraJSONRPC
import TingraMCP
import TingraPlugInKit

/// The app's host for app-tier plug-ins (PLUGINS.md, "The app side"): it
/// discovers the ExtensionKit extensions targeting the app's extension
/// point, reads each one's manifest from its Info.plist, and fills the pane
/// and command registries before any extension runs. An extension's process
/// starts on demand — when a hosted pane activates, a command is invoked,
/// or a bus event meets an activation condition the manifest declared — and
/// each connection carries an MCP session the plug-in talks to
/// (``AppPlugInLink``). The host-tier mirror is `TingraHost`'s loader and
/// registries.
///
/// Discovery follows the system's own change stream, never polling.
@Observable
final class AppPlugInHost {
    /// A plug-in the host discovered: its identity and manifest.
    struct DiscoveredPlugIn: Identifiable {
        /// The extension the system reported.
        let identity: AppExtensionIdentity

        /// The manifest read from its Info.plist.
        let manifest: PlugInManifest

        /// The plug-in's identifier.
        var id: PlugInID { manifest.id }
    }

    /// The extension point the app declares
    /// (`com.moonwink.tingra.app.plug-in.appextensionpoint`).
    nonisolated static let extensionPointID = "com.moonwink.tingra.app.plug-in"

    /// The sidebar and settings panes plug-ins declared.
    let panes = PaneRegistry()

    /// The commands plug-ins declared.
    let commands = CommandRegistry()

    /// The status items plug-ins declared, and the texts they report.
    let statusItems = StatusItemRegistry()

    /// The discovered plug-ins, in discovery order.
    private(set) var plugIns: [DiscoveredPlugIn] = []

    /// Which panes are open, mirrored from ``PanePreferences`` so the
    /// sidebar and a command's `showsPane` share one observable answer.
    private(set) var expandedPanes: Set<PaneID> = []

    /// Whether the Settings window's Plug-ins section — the collapsible
    /// heading over the plug-ins' settings panes — is open, mirrored from
    /// ``PanePreferences`` like ``expandedPanes``.
    private(set) var isSettingsSectionExpanded: Bool

    /// A generation per pane, bumped to recreate the pane's host view
    /// controller after its extension process died: an
    /// `EXHostViewController` does not relaunch its scene on its own
    /// (PLUGINS.md, "Spike findings", row 2).
    private(set) var paneGenerations: [PaneID: Int] = [:]

    /// The folder embedded extensions live in (`Contents/Extensions`).
    private let extensionsDirectory: URL

    /// Where pane expansion persists.
    private let preferences: PanePreferences

    /// What every link needs, once ``start(model:)`` has run.
    @ObservationIgnored private var services: AppPlugInServices?

    /// The per-plug-in links, by id.
    @ObservationIgnored private var links: [PlugInID: AppPlugInLink] = [:]

    /// The activation conditions the discovered plug-ins declared, by event
    /// name.
    @ObservationIgnored private var activations = ActivationTable()

    /// The task draining the bus for events that meet an activation
    /// condition.
    @ObservationIgnored private var activationTask: Task<Void, Never>?

    /// The task following discovery.
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?

    /// The task following the system's availability counts.
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?

    /// The task keeping the status sink attached to the bus.
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    /// Creates a host.
    ///
    /// - Parameters:
    ///   - extensionsDirectory: The folder embedded extensions live in.
    ///   - preferences: Where pane expansion persists.
    init(
        extensionsDirectory: URL = Bundle.main.bundleURL.appending(path: "Contents/Extensions"),
        preferences: PanePreferences = PanePreferences()
    ) {
        self.extensionsDirectory = extensionsDirectory
        self.preferences = preferences
        isSettingsSectionExpanded = preferences.isSettingsSectionExpanded
    }

    /// Begins discovery against the engine model's bus, tool registry, and
    /// project storage.
    ///
    /// - Parameter model: The engine model.
    func start(model: EngineModel) {
        guard services == nil else { return }
        let status = StatusSink()
        statusTask = model.eventBus.attach(status)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let services = AppPlugInServices(
            eventBus: model.eventBus, tools: model.toolRegistry, resources: model.resourceRegistry, status: status,
            info: DaemonInfo(name: "Tingra", version: version),
            storage: AppPlugInStorage(
                model: model, applicationStore: PlugInApplicationStore(),
                secrets: PlugInSecretStore(secureStorage: model.secureStorage)),
            statusItems: statusItems, meters: model.meterFeed,
            frames: RelayFrameFeed(program: model.programRelay, preview: model.previewRelay))
        self.services = services
        discoveryTask = Task { await discover(services: services) }
        let busEvents = model.eventBus.events()
        activationTask = Task {
            for await event in busEvents {
                wake(on: event)
            }
        }
        availabilityTask = Task {
            for await availability in AppExtensionIdentity.availabilityUpdates {
                services.eventBus.event(
                    "plugin.availability", domain: .plugIn,
                    params: [
                        "tier": .string("app"),
                        "enabled": .int(availability.enabledCount),
                        "disabled": .int(availability.disabledCount),
                        "unapproved": .int(availability.unapprovedCount),
                    ])
            }
        }
    }

    /// Stops discovery and every link.
    func stop() {
        discoveryTask?.cancel()
        availabilityTask?.cancel()
        activationTask?.cancel()
        statusTask?.cancel()
        for link in links.values { link.close() }
        links = [:]
    }

    // MARK: - Discovery

    /// Follows the identities matching the extension point, registering each
    /// batch's manifests and retiring the plug-ins that left.
    private func discover(services: AppPlugInServices) async {
        do {
            let identities = try AppExtensionIdentity.matching(appExtensionPointIDs: Self.extensionPointID)
            for await batch in identities {
                adopt(batch, services: services)
            }
        } catch {
            services.eventBus.error(
                "plugin.discovery", domain: .plugIn,
                params: ["tier": .string("app"), "error": .string(String(describing: error))])
        }
    }

    /// Registers the manifests of a batch of identities and retires the
    /// plug-ins no longer in it.
    private func adopt(_ batch: [AppExtensionIdentity], services: AppPlugInServices) {
        let present = Set(batch.map(\.bundleIdentifier))
        for plugIn in plugIns where !present.contains(plugIn.identity.bundleIdentifier) {
            retire(plugIn, services: services)
        }
        for identity in batch where !plugIns.contains(where: { $0.identity == identity }) {
            register(identity, services: services)
        }
    }

    /// Reads an identity's manifest and fills the registries from it.
    private func register(_ identity: AppExtensionIdentity, services: AppPlugInServices) {
        let manifest: PlugInManifest
        do {
            manifest = try PlugInManifest(bundle: try bundle(for: identity))
        } catch {
            services.eventBus.error(
                "plugin.manifest", domain: .plugIn,
                params: [
                    "tier": .string("app"), "bundle": .string(identity.bundleIdentifier),
                    "error": .string(String(describing: error)),
                ])
            return
        }
        guard !plugIns.contains(where: { $0.id == manifest.id }) else {
            services.eventBus.error(
                "plugin.manifest", domain: .plugIn,
                params: [
                    "tier": .string("app"), "bundle": .string(identity.bundleIdentifier),
                    "error": .string("A plug-in with id '\(manifest.id.rawValue)' is already registered."),
                ])
            return
        }
        let plugIn = DiscoveredPlugIn(identity: identity, manifest: manifest)
        plugIns.append(plugIn)
        links[manifest.id] = AppPlugInLink(plugIn: plugIn, services: services)
        for pane in manifest.panes {
            let registered = RegisteredPane(plugIn: manifest.id, plugInName: manifest.name, descriptor: pane)
            report(try panes.register(registered), plugIn: manifest.id, services: services)
            if preferences.isExpanded(pane.id) { expandedPanes.insert(pane.id) }
        }
        for pane in manifest.settingsPanes {
            report(
                try panes.register(RegisteredSettingsPane(plugIn: manifest.id, descriptor: pane)), plugIn: manifest.id,
                services: services)
        }
        for window in manifest.windows {
            let registered = RegisteredWindow(plugIn: manifest.id, plugInName: manifest.name, descriptor: window)
            report(try panes.register(registered), plugIn: manifest.id, services: services)
        }
        for command in manifest.commands {
            let registered = RegisteredCommand(plugIn: manifest.id, plugInName: manifest.name, descriptor: command)
            report(try commands.register(registered), plugIn: manifest.id, services: services)
        }
        for item in manifest.statusItems {
            let registered = RegisteredStatusItem(plugIn: manifest.id, plugInName: manifest.name, descriptor: item)
            report(try statusItems.register(registered), plugIn: manifest.id, services: services)
        }
        activations.add(manifest.activation, for: manifest.id)
        services.eventBus.event(
            "plugin.discovered", domain: .plugIn,
            params: [
                "tier": .string("app"), "id": .string(manifest.id.rawValue), "name": .string(manifest.name),
                "bundle": .string(identity.bundleIdentifier), "panes": .int(manifest.panes.count),
                "commands": .int(manifest.commands.count), "settingsPanes": .int(manifest.settingsPanes.count),
                "windows": .int(manifest.windows.count), "statusItems": .int(manifest.statusItems.count),
                "activation": .int(manifest.activation.count),
            ])
    }

    /// Removes a plug-in that is no longer available.
    private func retire(_ plugIn: DiscoveredPlugIn, services: AppPlugInServices) {
        links[plugIn.id]?.close()
        links[plugIn.id] = nil
        panes.removeAll(for: plugIn.id)
        commands.removeAll(for: plugIn.id)
        statusItems.removeAll(for: plugIn.id)
        activations.removeAll(for: plugIn.id)
        plugIns.removeAll { $0.id == plugIn.id }
        services.eventBus.event(
            "plugin.retired", domain: .plugIn, params: ["tier": .string("app"), "id": .string(plugIn.id.rawValue)])
    }

    /// Runs a registration, reporting a duplicate as an error event.
    private func report(_ registration: @autoclosure () throws -> Void, plugIn: PlugInID, services: AppPlugInServices) {
        do {
            try registration()
        } catch {
            services.eventBus.error(
                "plugin.registration", domain: .plugIn,
                params: [
                    "tier": .string("app"), "id": .string(plugIn.rawValue), "error": .string(String(describing: error)),
                ]
            )
        }
    }

    /// The bundle an identity names: the embedded extension in
    /// `Contents/Extensions` whose bundle identifier matches. Launch
    /// Services does not locate an `.appex` (Phase 0 spike, row 5); a
    /// third-party extension's container is Phase 3's question.
    private func bundle(for identity: AppExtensionIdentity) throws -> Bundle {
        let contents =
            (try? FileManager.default.contentsOfDirectory(at: extensionsDirectory, includingPropertiesForKeys: nil))
            ?? []
        for url in contents where url.pathExtension == "appex" {
            if let bundle = Bundle(url: url), bundle.bundleIdentifier == identity.bundleIdentifier {
                return bundle
            }
        }
        throw PlugInHostError.bundleNotFound(identity.bundleIdentifier, extensionsDirectory)
    }

    // MARK: - Panes

    /// Whether a pane is open in its sidebar.
    func isExpanded(_ pane: PaneID) -> Bool {
        expandedPanes.contains(pane)
    }

    /// Opens or closes a pane, persisting the choice.
    ///
    /// - Parameters:
    ///   - isExpanded: Whether the pane is open.
    ///   - pane: The pane.
    func setExpanded(_ isExpanded: Bool, for pane: PaneID) {
        if isExpanded { expandedPanes.insert(pane) } else { expandedPanes.remove(pane) }
        preferences.setExpanded(isExpanded, for: pane)
    }

    /// Opens or closes the Settings window's Plug-ins section, persisting
    /// the choice.
    ///
    /// - Parameter isExpanded: Whether the section is open.
    func setSettingsSectionExpanded(_ isExpanded: Bool) {
        isSettingsSectionExpanded = isExpanded
        preferences.setSettingsSectionExpanded(isExpanded)
    }

    /// The pane's host view controller reported its scene active: open the
    /// pane's session over a connection to the scene.
    ///
    /// - Parameters:
    ///   - pane: The pane.
    ///   - controller: The activated host view controller.
    func paneActivated(_ pane: PaneID, controller: EXHostViewController) {
        guard let plugIn = panes.plugIn(hosting: pane), let link = links[plugIn] else { return }
        do {
            let connection = try controller.makeXPCConnection()
            link.openSession(kind: "pane:\(pane.rawValue)", connection: connection)
        } catch {
            services?.eventBus.error(
                "plugin.paneConnection", domain: .plugIn,
                params: [
                    "tier": .string("app"), "id": .string(plugIn.rawValue), "pane": .string(pane.rawValue),
                    "error": .string(String(describing: error)),
                ])
        }
    }

    /// The pane's host view controller reported its scene going away. With
    /// an error — the extension process died — the pane is re-hosted after
    /// a beat, so a crash loop cannot spin the sidebar.
    ///
    /// - Parameters:
    ///   - pane: The pane.
    ///   - error: The system's reason, if it gave one.
    func paneDeactivated(_ pane: PaneID, error: (any Error)?) {
        guard let plugIn = panes.plugIn(hosting: pane), let link = links[plugIn] else { return }
        link.closeSession(kind: "pane:\(pane.rawValue)", reason: error.map { String(describing: $0) })
        guard error != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            paneGenerations[pane, default: 0] += 1
        }
    }

    // MARK: - Commands

    /// Invokes a command: reveals the pane it names, then forwards it to
    /// the extension, launching the process if needed. The caller has
    /// already emitted the `tap`, and opened the window the command names —
    /// opening a window is an environment action only a view can take
    /// (``PlugInCommands``).
    ///
    /// - Parameter command: The command.
    func invoke(_ command: RegisteredCommand) async {
        if let pane = command.descriptor.showsPane { setExpanded(true, for: pane) }
        guard let link = links[command.plugIn] else { return }
        await link.perform(command.descriptor.id)
    }

    // MARK: - Activation

    /// Wakes every plug-in whose activation conditions a bus event meets:
    /// its process is launched if it is not running, and the event is
    /// reported to it (PLUGINS.md, Decision 6, "activation conditions").
    /// One lookup per event; a bus with no conditions declared costs
    /// nothing more.
    ///
    /// - Parameter event: An event drained from the bus.
    private func wake(on event: EventBusEvent) {
        for match in activations.matches(event) {
            guard let link = links[match.plugIn] else { continue }
            Task { await link.activate(match.condition, event: event) }
        }
    }
}

/// What the host can get wrong.
enum PlugInHostError: Error, CustomStringConvertible {
    /// No embedded extension bundle carries the identity's bundle id.
    case bundleNotFound(String, URL)

    var description: String {
        switch self {
        case .bundleNotFound(let bundleID, let directory):
            "No extension bundle with identifier '\(bundleID)' is embedded in \(directory.path(percentEncoded: false)); a third-party extension's bundle is located in Phase 3."
        }
    }
}

/// What every link needs: the bus, the tool and resource registries, the
/// status sink and identity the MCP session serves, the plug-ins' storage,
/// the status items, the meters, and the bus frames.
struct AppPlugInServices {
    /// The bus events land on.
    let eventBus: EventBus

    /// The tools the endpoint lists and calls.
    let tools: ToolRegistry

    /// The resources the endpoint lists, reads, and subscribes to.
    let resources: ResourceRegistry

    /// The status sink sessions forward as notifications.
    let status: StatusSink

    /// The endpoint's identity in `initialize`.
    let info: DaemonInfo

    /// Where plug-ins' values live.
    let storage: any PlugInStoring

    /// The status items, whose texts a plug-in sets and the link clears
    /// when the plug-in's last connection closes.
    let statusItems: StatusItemRegistry

    /// The meters a connection subscribes to (`tingra/meters`).
    let meters: any PlugInMeterFeeding

    /// The bus frames a connection asks for (`tingra/frame.next`).
    let frames: any PlugInFrameFeeding
}

/// The plug-ins' storage behind the method handler: project scope through
/// the engine model (the document), app scope through the file store, and
/// secrets through the engine's own secure storage, narrowed to the
/// plug-in's accounts.
final class AppPlugInStorage: PlugInStoring {
    /// The engine model holding the open project.
    private let model: EngineModel

    /// The app-scoped file store.
    private let applicationStore: PlugInApplicationStore

    /// The plug-ins' secrets, in the app's Keychain-backed secure storage.
    private let secrets: PlugInSecretStore

    /// Creates the storage.
    init(model: EngineModel, applicationStore: PlugInApplicationStore, secrets: PlugInSecretStore) {
        self.model = model
        self.applicationStore = applicationStore
        self.secrets = secrets
    }

    func secret(named name: String, plugIn: PlugInID) async throws -> String? {
        try secrets.secret(named: name, for: plugIn)
    }

    func setSecret(_ secret: String?, named name: String, plugIn: PlugInID) async throws {
        try secrets.setSecret(secret, named: name, for: plugIn)
    }

    func value(scope: StorageScope, plugIn: PlugInID) async -> JSONValue? {
        switch scope {
        case .project: model.plugInProjectData(for: plugIn)
        case .application: applicationStore.value(for: plugIn)
        }
    }

    func setValue(_ value: JSONValue?, scope: StorageScope, plugIn: PlugInID) async {
        switch scope {
        case .project:
            model.setPlugInProjectData(value, for: plugIn)
        case .application:
            do {
                try applicationStore.setValue(value, for: plugIn)
            } catch {
                model.eventBus.error(
                    "plugin.applicationStorage", domain: .plugIn,
                    params: [
                        "tier": .string("app"), "id": .string(plugIn.rawValue),
                        "error": .string(String(describing: error)),
                    ])
            }
        }
    }
}

/// One plug-in's process and connections: the command connection through
/// `AppExtensionProcess`, opened on the first command, and a connection per
/// hosted pane, each carrying an MCP session with the plug-in's method
/// handler. The plug-in is "activated" while any connection is open.
final class AppPlugInLink {
    /// The plug-in.
    let plugIn: AppPlugInHost.DiscoveredPlugIn

    /// What the sessions need.
    private let services: AppPlugInServices

    /// The extension's process, once launched for commands.
    private var process: AppExtensionProcess?

    /// The sessions by kind (`process`, `pane:<id>`), each with its task.
    private var sessions: [String: (session: MCPSession, task: Task<Void, Never>)] = [:]

    /// Creates the link.
    init(plugIn: AppPlugInHost.DiscoveredPlugIn, services: AppPlugInServices) {
        self.plugIn = plugIn
        self.services = services
    }

    /// Forwards a command over the process connection, launching the
    /// process first if needed.
    ///
    /// - Parameter command: The command.
    func perform(_ command: CommandID) async {
        do {
            let session = try await commandSession(wokenBy: nil)
            _ = try await session.request(
                AppTierMethod.commandPerform,
                params: .object([AppTierMethod.CommandParam.command: .string(command.rawValue)]))
        } catch {
            services.eventBus.error(
                "plugin.command", domain: .plugIn,
                params: [
                    "tier": .string("app"), "id": .string(plugIn.id.rawValue), "command": .string(command.rawValue),
                    "error": .string(String(describing: error)),
                ])
        }
    }

    /// Reports an activation condition met, launching the process first if
    /// needed — the launch on demand a plug-in with no pane relies on.
    /// A handler that throws is a `plugin.activation` error naming the
    /// plug-in, the condition, and the event, the host tier's own report of
    /// a plug-in's activation going wrong.
    ///
    /// - Parameters:
    ///   - condition: The condition the event met.
    ///   - event: The event.
    func activate(_ condition: ActivationCondition, event: EventBusEvent) async {
        do {
            let session = try await commandSession(wokenBy: condition)
            let eventJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event))
            _ = try await session.request(
                AppTierMethod.activation,
                params: .object([
                    AppTierMethod.ActivationParam.condition: .string(condition.rawValue),
                    AppTierMethod.ActivationParam.event: eventJSON,
                ]))
        } catch {
            services.eventBus.error(
                "plugin.activation", domain: .plugIn,
                params: [
                    "tier": .string("app"), "id": .string(plugIn.id.rawValue),
                    "condition": .string(condition.rawValue), "event": .string(event.name),
                    "error": .string(String(describing: error)),
                ])
        }
    }

    /// The command session, launching the process on first use and again
    /// after it died.
    ///
    /// - Parameter wokenBy: The activation condition launching the process,
    ///   if that is what asked for it; recorded on `plugin.activated`.
    private func commandSession(wokenBy: ActivationCondition?) async throws -> MCPSession {
        if let existing = sessions["process"] { return existing.session }
        let interrupted: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.processInterrupted() }
        }
        let process = try await AppExtensionProcess(
            configuration: .init(appExtensionIdentity: plugIn.identity, onInterruption: interrupted))
        self.process = process
        let connection = try process.makeXPCConnection()
        return openSession(kind: "process", connection: connection, wokenBy: wokenBy)
    }

    /// The system reported the process gone: the command session is over.
    private func processInterrupted() {
        process?.invalidate()
        process = nil
        closeSession(kind: "process", reason: "interrupted")
    }

    /// Opens an MCP session over a connection this side made.
    ///
    /// - Parameters:
    ///   - kind: `process` or `pane:<id>`.
    ///   - connection: The connection, not yet resumed.
    ///   - wokenBy: The activation condition that launched the process, if
    ///     one did; `plugin.activated` names it.
    @discardableResult
    func openSession(kind: String, connection: NSXPCConnection, wokenBy: ActivationCondition? = nil) -> MCPSession {
        closeSession(kind: kind, reason: nil)
        let wasActive = !sessions.isEmpty
        let transport = XPCMessageTransport(connection: connection, opening: true)
        let handler = PlugInMethodHandler(
            plugIn: plugIn.id, eventBus: services.eventBus, storage: services.storage,
            statusItems: services.statusItems, meters: services.meters, frames: services.frames)
        let session = MCPSession(
            transport: transport, tools: services.tools, resources: services.resources, status: services.status,
            info: services.info, eventBus: services.eventBus, methods: handler)
        let task = Task { [weak self] in
            await session.run()
            self?.sessionEnded(kind: kind, session: session)
        }
        sessions[kind] = (session, task)
        if !wasActive {
            var params: [String: EventValue] = [
                "tier": .string("app"), "id": .string(plugIn.id.rawValue), "name": .string(plugIn.manifest.name),
                "kind": .string(kind),
            ]
            if let wokenBy { params["condition"] = .string(wokenBy.rawValue) }
            services.eventBus.event("plugin.activated", domain: .plugIn, params: params)
        }
        return session
    }

    /// Closes a session, if open.
    ///
    /// - Parameters:
    ///   - kind: `process` or `pane:<id>`.
    ///   - reason: Why, for the deactivation event, or nil for a plain close.
    func closeSession(kind: String, reason: String?) {
        guard let entry = sessions.removeValue(forKey: kind) else { return }
        entry.task.cancel()
        noteDeactivatedIfIdle(reason: reason ?? "closed")
    }

    /// A session's run loop ended on its own (the peer closed).
    private func sessionEnded(kind: String, session: MCPSession) {
        guard let entry = sessions[kind], entry.session === session else { return }
        sessions[kind] = nil
        noteDeactivatedIfIdle(reason: "ended")
    }

    /// Emits `plugin.deactivated` when the last session is gone, and takes
    /// the plug-in's readings off the status bar: nothing is left to keep
    /// them true.
    private func noteDeactivatedIfIdle(reason: String) {
        guard sessions.isEmpty else { return }
        services.statusItems.clearTexts(for: plugIn.id)
        services.eventBus.event(
            "plugin.deactivated", domain: .plugIn,
            params: ["tier": .string("app"), "id": .string(plugIn.id.rawValue), "reason": .string(reason)])
    }

    /// Closes everything.
    func close() {
        for kind in sessions.keys { closeSession(kind: kind, reason: "stopped") }
        process?.invalidate()
        process = nil
    }
}
