//
//  PlugInRegistries.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import TingraAppPlugInKit
import TingraPlugInKit

/// A pane an app-tier plug-in registered, with the plug-in it belongs to.
struct RegisteredPane: Identifiable, Hashable, Sendable {
    /// The plug-in.
    let plugIn: PlugInID

    /// The plug-in's display name.
    let plugInName: String

    /// The pane as declared.
    let descriptor: PaneDescriptor

    /// The pane's identifier.
    var id: PaneID { descriptor.id }
}

/// A command an app-tier plug-in registered, with the plug-in it belongs to.
struct RegisteredCommand: Identifiable, Hashable, Sendable {
    /// The plug-in.
    let plugIn: PlugInID

    /// The plug-in's display name, the submenu's title.
    let plugInName: String

    /// The command as declared.
    let descriptor: CommandDescriptor

    /// The command's identifier, qualified by the plug-in so two plug-ins'
    /// `show` commands are distinct rows.
    var id: String { "\(plugIn.rawValue).\(descriptor.id.rawValue)" }

    /// The `tap` event name the menu item reports.
    var tapName: String { "\(id).menuItem" }
}

/// A settings pane an app-tier plug-in registered, with the plug-in it
/// belongs to.
struct RegisteredSettingsPane: Identifiable, Hashable, Sendable {
    /// The plug-in.
    let plugIn: PlugInID

    /// The pane as declared.
    let descriptor: SettingsPaneDescriptor

    /// The pane's identifier.
    var id: PaneID { descriptor.id }
}

/// What a registration can get wrong: an id already taken. Reported as an
/// `error` event naming the plug-in and the id; the next plug-in registers
/// normally (PLUGINS.md, "The app side").
enum PlugInRegistryError: Error, Equatable, CustomStringConvertible {
    /// A pane id is already registered.
    case duplicatePane(PaneID)

    /// A command id is already registered for the plug-in.
    case duplicateCommand(PlugInID, CommandID)

    var description: String {
        switch self {
        case .duplicatePane(let pane):
            "A pane with id '\(pane.rawValue)' is already registered; pane ids must be unique across plug-ins."
        case .duplicateCommand(let plugIn, let command):
            "Plug-in '\(plugIn.rawValue)' already registered a command '\(command.rawValue)'."
        }
    }
}

/// The app tier's pane registry: every sidebar pane and settings pane
/// app-tier plug-ins have declared, filled from manifests at discovery
/// before any extension runs — the app-side mirror of the host's
/// registries for the host tier (PLUGINS.md, "The app side").
@Observable
final class PaneRegistry {
    /// The sidebar panes, in registration order.
    private(set) var panes: [RegisteredPane] = []

    /// The settings panes, in registration order.
    private(set) var settingsPanes: [RegisteredSettingsPane] = []

    /// Creates an empty registry.
    init() {}

    /// Registers a sidebar pane.
    ///
    /// - Throws: ``PlugInRegistryError/duplicatePane(_:)``.
    func register(_ pane: RegisteredPane) throws {
        guard !panes.contains(where: { $0.id == pane.id }), !settingsPanes.contains(where: { $0.id == pane.id })
        else { throw PlugInRegistryError.duplicatePane(pane.id) }
        panes.append(pane)
    }

    /// Registers a settings pane.
    ///
    /// - Throws: ``PlugInRegistryError/duplicatePane(_:)``.
    func register(_ pane: RegisteredSettingsPane) throws {
        guard !panes.contains(where: { $0.id == pane.id }), !settingsPanes.contains(where: { $0.id == pane.id })
        else { throw PlugInRegistryError.duplicatePane(pane.id) }
        settingsPanes.append(pane)
    }

    /// The sidebar pane with `id`, if registered.
    func pane(_ id: PaneID) -> RegisteredPane? {
        panes.first { $0.id == id }
    }

    /// Removes every pane a plug-in registered (the plug-in was disabled
    /// or removed).
    func removeAll(for plugIn: PlugInID) {
        panes.removeAll { $0.plugIn == plugIn }
        settingsPanes.removeAll { $0.plugIn == plugIn }
    }
}

/// The app tier's command registry: every menu command app-tier plug-ins
/// have declared, grouped by plug-in for the Plug-ins menu's submenus
/// (PLUGINS.md, Decision 6).
@Observable
final class CommandRegistry {
    /// The commands, in registration order.
    private(set) var commands: [RegisteredCommand] = []

    /// Creates an empty registry.
    init() {}

    /// Registers a command.
    ///
    /// - Throws: ``PlugInRegistryError/duplicateCommand(_:_:)``.
    func register(_ command: RegisteredCommand) throws {
        guard !commands.contains(where: { $0.id == command.id }) else {
            throw PlugInRegistryError.duplicateCommand(command.plugIn, command.descriptor.id)
        }
        commands.append(command)
    }

    /// The plug-ins with commands, in the order they first registered one,
    /// each with its name — the Plug-ins menu's submenus.
    var plugIns: [(id: PlugInID, name: String)] {
        var seen = Set<PlugInID>()
        return commands.compactMap { command in
            guard seen.insert(command.plugIn).inserted else { return nil }
            return (command.plugIn, command.plugInName)
        }
    }

    /// The commands a plug-in registered, in order.
    func commands(for plugIn: PlugInID) -> [RegisteredCommand] {
        commands.filter { $0.plugIn == plugIn }
    }

    /// Removes every command a plug-in registered.
    func removeAll(for plugIn: PlugInID) {
        commands.removeAll { $0.plugIn == plugIn }
    }
}
