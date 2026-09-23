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

/// A window an app-tier plug-in registered, with the plug-in it belongs to.
struct RegisteredWindow: Identifiable, Hashable, Sendable {
    /// The plug-in.
    let plugIn: PlugInID

    /// The plug-in's display name.
    let plugInName: String

    /// The window as declared.
    let descriptor: WindowDescriptor

    /// The window's identifier.
    var id: PaneID { descriptor.id }
}

/// A status item an app-tier plug-in registered, with the plug-in it
/// belongs to.
struct RegisteredStatusItem: Identifiable, Hashable, Sendable {
    /// The plug-in.
    let plugIn: PlugInID

    /// The plug-in's display name.
    let plugInName: String

    /// The status item as declared.
    let descriptor: StatusItemDescriptor

    /// The item's identifier, qualified by the plug-in so two plug-ins'
    /// `link` items are distinct readings.
    var id: String { "\(plugIn.rawValue).\(descriptor.id.rawValue)" }
}

/// What a registration can get wrong: an id already taken. Reported as an
/// `error` event naming the plug-in and the id; the next plug-in registers
/// normally (PLUGINS.md, "The app side").
enum PlugInRegistryError: Error, Equatable, CustomStringConvertible {
    /// A pane id is already registered.
    case duplicatePane(PaneID)

    /// A command id is already registered for the plug-in.
    case duplicateCommand(PlugInID, CommandID)

    /// A status item id is already registered for the plug-in.
    case duplicateStatusItem(PlugInID, StatusItemID)

    /// A text was set for a status item the plug-in never declared.
    case unknownStatusItem(PlugInID, StatusItemID)

    var description: String {
        switch self {
        case .duplicatePane(let pane):
            "A pane with id '\(pane.rawValue)' is already registered; pane ids must be unique across plug-ins."
        case .duplicateCommand(let plugIn, let command):
            "Plug-in '\(plugIn.rawValue)' already registered a command '\(command.rawValue)'."
        case .duplicateStatusItem(let plugIn, let item):
            "Plug-in '\(plugIn.rawValue)' already registered a status item '\(item.rawValue)'."
        case .unknownStatusItem(let plugIn, let item):
            "Plug-in '\(plugIn.rawValue)' declares no status item '\(item.rawValue)'; add it to the manifest's statusItems list."
        }
    }
}

/// The app tier's pane registry: every sidebar pane, settings pane, and
/// window app-tier plug-ins have declared — every scene the app hosts — filled from manifests at discovery
/// before any extension runs — the app-side mirror of the host's
/// registries for the host tier (PLUGINS.md, "The app side").
@Observable
final class PaneRegistry {
    /// The sidebar panes, in registration order.
    private(set) var panes: [RegisteredPane] = []

    /// The settings panes, in registration order.
    private(set) var settingsPanes: [RegisteredSettingsPane] = []

    /// The windows, in registration order.
    private(set) var windows: [RegisteredWindow] = []

    /// Creates an empty registry.
    init() {}

    /// Whether any pane, settings pane, or window already carries `id`:
    /// the three share one id space, since each is a hosted scene.
    private func isRegistered(_ id: PaneID) -> Bool {
        panes.contains { $0.id == id } || settingsPanes.contains { $0.id == id } || windows.contains { $0.id == id }
    }

    /// Registers a sidebar pane.
    ///
    /// - Throws: ``PlugInRegistryError/duplicatePane(_:)``.
    func register(_ pane: RegisteredPane) throws {
        guard !isRegistered(pane.id) else { throw PlugInRegistryError.duplicatePane(pane.id) }
        panes.append(pane)
    }

    /// Registers a settings pane.
    ///
    /// - Throws: ``PlugInRegistryError/duplicatePane(_:)``.
    func register(_ pane: RegisteredSettingsPane) throws {
        guard !isRegistered(pane.id) else { throw PlugInRegistryError.duplicatePane(pane.id) }
        settingsPanes.append(pane)
    }

    /// Registers a window.
    ///
    /// - Throws: ``PlugInRegistryError/duplicatePane(_:)``.
    func register(_ window: RegisteredWindow) throws {
        guard !isRegistered(window.id) else { throw PlugInRegistryError.duplicatePane(window.id) }
        windows.append(window)
    }

    /// The sidebar pane with `id`, if registered.
    func pane(_ id: PaneID) -> RegisteredPane? {
        panes.first { $0.id == id }
    }

    /// The window with `id`, if registered.
    func window(_ id: PaneID) -> RegisteredWindow? {
        windows.first { $0.id == id }
    }

    /// The plug-in a hosted scene belongs to, whichever kind it is.
    func plugIn(hosting id: PaneID) -> PlugInID? {
        panes.first { $0.id == id }?.plugIn ?? settingsPanes.first { $0.id == id }?.plugIn
            ?? windows.first { $0.id == id }?.plugIn
    }

    /// Removes every pane a plug-in registered (the plug-in was disabled
    /// or removed).
    func removeAll(for plugIn: PlugInID) {
        panes.removeAll { $0.plugIn == plugIn }
        settingsPanes.removeAll { $0.plugIn == plugIn }
        windows.removeAll { $0.plugIn == plugIn }
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

/// Sets a status item's text for the plug-in a connection belongs to — the
/// seam the method handler reaches the status items through, so it is
/// tested against a fake with no registry.
protocol PlugInStatusReporting: Sendable {
    /// Gives a declared status item its text; nil or empty removes it.
    ///
    /// - Throws: ``PlugInRegistryError/unknownStatusItem(_:_:)``.
    func setText(_ text: String?, for item: StatusItemID, plugIn: PlugInID) async throws
}

/// The app tier's status item registry: every status bar reading app-tier
/// plug-ins have declared, and the text each currently reports (PLUGINS.md,
/// Phase 2, "More app-tier registries"). An item is on the bar only while
/// it has a text; the texts of a plug-in are dropped when its last
/// connection closes, so a reading never outlives the process behind it.
@Observable
final class StatusItemRegistry: PlugInStatusReporting {
    /// The status items, in registration order.
    private(set) var items: [RegisteredStatusItem] = []

    /// The texts reported, by ``RegisteredStatusItem/id``.
    private(set) var texts: [String: String] = [:]

    /// Creates an empty registry.
    init() {}

    /// The longest text the bar draws; a longer one is cut here, once, so
    /// a plug-in cannot push the app's own readings off the bar.
    static let maximumTextLength = 40

    /// The readings on the bar: every item with a text, in registration
    /// order.
    var readings: [(item: RegisteredStatusItem, text: String)] {
        items.compactMap { item in texts[item.id].map { (item, $0) } }
    }

    /// Registers a status item.
    ///
    /// - Throws: ``PlugInRegistryError/duplicateStatusItem(_:_:)``.
    func register(_ item: RegisteredStatusItem) throws {
        guard !items.contains(where: { $0.id == item.id }) else {
            throw PlugInRegistryError.duplicateStatusItem(item.plugIn, item.descriptor.id)
        }
        items.append(item)
    }

    func setText(_ text: String?, for item: StatusItemID, plugIn: PlugInID) throws {
        guard let registered = items.first(where: { $0.plugIn == plugIn && $0.descriptor.id == item }) else {
            throw PlugInRegistryError.unknownStatusItem(plugIn, item)
        }
        guard let text, !text.isEmpty else {
            texts[registered.id] = nil
            return
        }
        texts[registered.id] = String(text.prefix(Self.maximumTextLength))
    }

    /// Drops every text a plug-in reported (its last connection closed).
    func clearTexts(for plugIn: PlugInID) {
        for item in items where item.plugIn == plugIn { texts[item.id] = nil }
    }

    /// Removes every status item a plug-in registered, texts included.
    func removeAll(for plugIn: PlugInID) {
        clearTexts(for: plugIn)
        items.removeAll { $0.plugIn == plugIn }
    }
}
