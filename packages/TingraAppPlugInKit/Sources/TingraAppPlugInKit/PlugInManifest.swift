//
//  PlugInManifest.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// What an app-tier plug-in declares about itself, read by the app from the
/// extension's Info.plist at discovery — before the extension has ever run,
/// so menus render and panes take their place with no process launched
/// (PLUGINS.md, Decision 5; the Phase 0 spike, row 5).
///
/// The manifest lives in the extension's Info.plist under
/// `EXAppExtensionAttributes` → `TingraPlugIn`, beside the
/// `EXExtensionPointIdentifier` ExtensionKit reads, as a property list
/// dictionary mirroring this type's `Codable` shape.
public struct PlugInManifest: Hashable, Sendable, Codable {
    /// The Info.plist key under `EXAppExtensionAttributes` the manifest
    /// dictionary sits at.
    public static let infoDictionaryKey = "TingraPlugIn"

    /// The ExtensionKit attributes key the manifest dictionary sits under.
    public static let attributesKey = "EXAppExtensionAttributes"

    /// The plug-in's identifier — its event domain too, and the key its
    /// project-scoped storage is filed under (PLUGINS.md, Decision 3).
    public let id: PlugInID

    /// The plug-in's display name.
    public let name: String

    /// The panes the plug-in contributes.
    public let panes: [PaneDescriptor]

    /// The commands the plug-in contributes.
    public let commands: [CommandDescriptor]

    /// The settings panes the plug-in contributes.
    public let settingsPanes: [SettingsPaneDescriptor]

    /// Creates a manifest.
    ///
    /// - Parameters:
    ///   - id: The plug-in's identifier.
    ///   - name: The plug-in's display name.
    ///   - panes: The panes the plug-in contributes.
    ///   - commands: The commands the plug-in contributes.
    ///   - settingsPanes: The settings panes the plug-in contributes.
    public init(
        id: PlugInID, name: String, panes: [PaneDescriptor] = [], commands: [CommandDescriptor] = [],
        settingsPanes: [SettingsPaneDescriptor] = []
    ) {
        self.id = id
        self.name = name
        self.panes = panes
        self.commands = commands
        self.settingsPanes = settingsPanes
    }

    /// The stable manifest keys; the three lists may be omitted.
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case panes
        case commands
        case settingsPanes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PlugInID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        panes = try container.decodeIfPresent([PaneDescriptor].self, forKey: .panes) ?? []
        commands = try container.decodeIfPresent([CommandDescriptor].self, forKey: .commands) ?? []
        settingsPanes = try container.decodeIfPresent([SettingsPaneDescriptor].self, forKey: .settingsPanes) ?? []
    }

    /// Reads the manifest out of an Info.plist dictionary.
    ///
    /// - Parameter infoDictionary: A bundle's Info.plist contents.
    /// - Throws: ``PlugInManifestError`` naming what is missing or
    ///   malformed, so a typo is a reported error, not a silently missing
    ///   menu.
    public init(infoDictionary: [String: Any]) throws {
        guard let attributes = infoDictionary[Self.attributesKey] as? [String: Any] else {
            throw PlugInManifestError.missingKey(Self.attributesKey)
        }
        guard let manifest = attributes[Self.infoDictionaryKey] else {
            throw PlugInManifestError.missingKey("\(Self.attributesKey).\(Self.infoDictionaryKey)")
        }
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        } catch {
            throw PlugInManifestError.malformed(String(describing: error))
        }
        do {
            self = try PropertyListDecoder().decode(PlugInManifest.self, from: data)
        } catch {
            throw PlugInManifestError.malformed(String(describing: error))
        }
        try validate()
    }

    /// Reads the manifest out of a bundle's Info.plist.
    ///
    /// - Parameter bundle: The extension's bundle (`Bundle.main` from
    ///   inside the extension).
    /// - Throws: ``PlugInManifestError``.
    public init(bundle: Bundle) throws {
        try self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    /// Checks the ids: every pane and settings pane id must start with the
    /// plug-in id (the namespacing rule), and no id may repeat.
    ///
    /// - Throws: ``PlugInManifestError`` naming the offending id.
    private func validate() throws {
        let prefix = id.rawValue + "."
        var paneIDs = Set<PaneID>()
        for pane in panes.map(\.id) + settingsPanes.map(\.id) {
            guard pane.rawValue.hasPrefix(prefix) else {
                throw PlugInManifestError.paneOutsidePlugIn(pane, plugIn: id)
            }
            guard paneIDs.insert(pane).inserted else { throw PlugInManifestError.duplicatePane(pane) }
        }
        var commandIDs = Set<CommandID>()
        for command in commands.map(\.id) {
            guard commandIDs.insert(command).inserted else { throw PlugInManifestError.duplicateCommand(command) }
        }
    }
}

/// What can be wrong with a manifest, each naming the fix.
public enum PlugInManifestError: Error, Equatable, CustomStringConvertible {
    /// A required key is absent from the Info.plist.
    case missingKey(String)

    /// The manifest dictionary does not decode.
    case malformed(String)

    /// A pane id does not start with the plug-in id.
    case paneOutsidePlugIn(PaneID, plugIn: PlugInID)

    /// Two panes share an id.
    case duplicatePane(PaneID)

    /// Two commands share an id.
    case duplicateCommand(CommandID)

    public var description: String {
        switch self {
        case .missingKey(let key):
            "The extension's Info.plist has no '\(key)' entry; add the TingraPlugIn manifest under EXAppExtensionAttributes."
        case .malformed(let detail):
            "The TingraPlugIn manifest does not decode: \(detail)"
        case .paneOutsidePlugIn(let pane, let plugIn):
            "Pane id '\(pane.rawValue)' must start with the plug-in id '\(plugIn.rawValue)' followed by a dot."
        case .duplicatePane(let pane):
            "Pane id '\(pane.rawValue)' is declared more than once."
        case .duplicateCommand(let command):
            "Command id '\(command.rawValue)' is declared more than once."
        }
    }
}
