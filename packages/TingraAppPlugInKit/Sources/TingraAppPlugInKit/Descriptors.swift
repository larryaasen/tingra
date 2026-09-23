//
//  Descriptors.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The identifier of a pane an app-tier plug-in declares: the plug-in id
/// and a name, joined with a dot (`com.moonwink.tingra.notes.pane`), so
/// pane ids from different plug-ins never collide (PLUGINS.md, Decision 5).
public struct PaneID: RawRepresentable, Hashable, Sendable, Codable {
    /// The dotted identifier string.
    public let rawValue: String

    /// Creates a pane id from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The identifier of a command an app-tier plug-in declares, unique within
/// the plug-in (`show`); the app qualifies it with the plug-in id where a
/// global name is needed, as in the `tap` event's name.
public struct CommandID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string.
    public let rawValue: String

    /// Creates a command id from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The identifier of a status item an app-tier plug-in declares, unique
/// within the plug-in (`link`), like a ``CommandID``.
public struct StatusItemID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string.
    public let rawValue: String

    /// Creates a status item id from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Which sidebar a pane would like to live in (GLOSSARY.md, "Sidebar"). A
/// preference the app may override — the operator's layout always wins —
/// and in Phase 1 every pane is hosted in the trailing sidebar, `.bottom`
/// included, until a bottom sidebar exists (PLUGINS.md, "The app side").
public enum SidebarPosition: String, Sendable, Codable, CaseIterable {
    /// The leading sidebar, where the inputs and shots are listed.
    case leading

    /// The trailing sidebar, below the Library.
    case trailing

    /// A bottom sidebar, when one exists.
    case bottom
}

/// A pane an app-tier plug-in contributes to a sidebar: hosted by the app
/// in shared chrome (a disclosure header carrying the title and symbol),
/// drawn by the plug-in's extension process as the scene `sceneID` names.
public struct PaneDescriptor: Hashable, Sendable, Codable, Identifiable {
    /// The pane's identifier.
    public let id: PaneID

    /// The title in the pane's header.
    public let title: String

    /// The SF Symbol beside the title.
    public let systemImage: String

    /// The sidebar the pane would like.
    public let preferredSidebar: SidebarPosition

    /// The extension scene the app hosts for the pane.
    public let sceneID: String

    /// Creates a pane descriptor.
    ///
    /// - Parameters:
    ///   - id: The pane's identifier.
    ///   - title: The title in the pane's header.
    ///   - systemImage: The SF Symbol beside the title.
    ///   - preferredSidebar: The sidebar the pane would like.
    ///   - sceneID: The extension scene the app hosts for the pane.
    public init(
        id: PaneID, title: String, systemImage: String, preferredSidebar: SidebarPosition = .trailing, sceneID: String
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.preferredSidebar = preferredSidebar
        self.sceneID = sceneID
    }

    /// The stable manifest keys; `preferredSidebar` may be omitted.
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case systemImage
        case preferredSidebar
        case sceneID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PaneID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        systemImage = try container.decode(String.self, forKey: .systemImage)
        preferredSidebar = try container.decodeIfPresent(SidebarPosition.self, forKey: .preferredSidebar) ?? .trailing
        sceneID = try container.decode(String.self, forKey: .sceneID)
    }
}

/// A keyboard shortcut declared in a manifest — `Codable`, which SwiftUI's
/// `KeyboardShortcut` is not. The app turns it into one.
public struct ShortcutDescriptor: Hashable, Sendable, Codable {
    /// A modifier key, named as in a manifest.
    public enum Modifier: String, Sendable, Codable, CaseIterable {
        /// The Command key.
        case command

        /// The Option key.
        case option

        /// The Shift key.
        case shift

        /// The Control key.
        case control
    }

    /// The key, one character (`n`).
    public let key: String

    /// The modifiers held with the key.
    public let modifiers: [Modifier]

    /// Creates a shortcut descriptor.
    ///
    /// - Parameters:
    ///   - key: The key, one character.
    ///   - modifiers: The modifiers held with the key.
    public init(key: String, modifiers: [Modifier]) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Where a command appears. Phase 1 has one placement: the plug-in's
/// submenu under the app's Plug-ins menu (PLUGINS.md, Decision 6).
public enum CommandPlacement: String, Sendable, Codable, CaseIterable {
    /// The plug-in's submenu of the Plug-ins menu.
    case plugInMenu
}

/// A command an app-tier plug-in contributes: a menu item the app renders
/// before the extension has run, forwarding the invocation to the
/// extension's ``TingraAppExtension/perform(_:using:)`` after emitting the
/// `tap` itself.
public struct CommandDescriptor: Hashable, Sendable, Codable, Identifiable {
    /// The command's identifier within the plug-in.
    public let id: CommandID

    /// The menu item's title.
    public let title: String

    /// The keyboard shortcut, if any.
    public let shortcut: ShortcutDescriptor?

    /// Where the command appears.
    public let placement: CommandPlacement

    /// A pane of the plug-in the app reveals — expands in its sidebar —
    /// before forwarding the command, so "Show Notes" needs no round trip
    /// to open the pane it names.
    public let showsPane: PaneID?

    /// A window of the plug-in the app opens — or brings forward, when it
    /// is already open — before forwarding the command: how a plug-in's
    /// window is reached, the way ``showsPane`` reaches a pane.
    public let showsWindow: PaneID?

    /// Creates a command descriptor.
    ///
    /// - Parameters:
    ///   - id: The command's identifier within the plug-in.
    ///   - title: The menu item's title.
    ///   - shortcut: The keyboard shortcut, if any.
    ///   - placement: Where the command appears.
    ///   - showsPane: A pane the app reveals before forwarding.
    ///   - showsWindow: A window the app opens before forwarding.
    public init(
        id: CommandID, title: String, shortcut: ShortcutDescriptor? = nil, placement: CommandPlacement = .plugInMenu,
        showsPane: PaneID? = nil, showsWindow: PaneID? = nil
    ) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.placement = placement
        self.showsPane = showsPane
        self.showsWindow = showsWindow
    }

    /// The stable manifest keys; `placement`, `showsPane`, and `showsWindow`
    /// may be omitted.
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case shortcut
        case placement
        case showsPane
        case showsWindow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CommandID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        shortcut = try container.decodeIfPresent(ShortcutDescriptor.self, forKey: .shortcut)
        placement = try container.decodeIfPresent(CommandPlacement.self, forKey: .placement) ?? .plugInMenu
        showsPane = try container.decodeIfPresent(PaneID.self, forKey: .showsPane)
        showsWindow = try container.decodeIfPresent(PaneID.self, forKey: .showsWindow)
    }
}

/// A settings pane an app-tier plug-in contributes to the app's Settings
/// window: a row in its source list, and a remote view like any pane.
public struct SettingsPaneDescriptor: Hashable, Sendable, Codable, Identifiable {
    /// The pane's identifier.
    public let id: PaneID

    /// The row's title.
    public let title: String

    /// The SF Symbol beside the title.
    public let systemImage: String

    /// The extension scene the app hosts for the pane.
    public let sceneID: String

    /// Creates a settings pane descriptor.
    ///
    /// - Parameters:
    ///   - id: The pane's identifier.
    ///   - title: The row's title.
    ///   - systemImage: The SF Symbol beside the title.
    ///   - sceneID: The extension scene the app hosts for the pane.
    public init(id: PaneID, title: String, systemImage: String, sceneID: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.sceneID = sceneID
    }
}

/// A window an app-tier plug-in contributes: a pane hosted in a window of
/// its own rather than a sidebar — a rundown, a multiview-style surface —
/// titled by the app and drawn by the plug-in's extension process as the
/// scene `sceneID` names (PLUGINS.md, Phase 2, "More app-tier registries").
/// Identified by a ``PaneID`` like every hosted scene, so
/// ``TingraAppExtension/pane(for:)`` answers for it too. A window is opened
/// by a command naming it (``CommandDescriptor/showsWindow``).
public struct WindowDescriptor: Hashable, Sendable, Codable, Identifiable {
    /// The window's identifier.
    public let id: PaneID

    /// The window's title.
    public let title: String

    /// The extension scene the app hosts in the window.
    public let sceneID: String

    /// Creates a window descriptor.
    ///
    /// - Parameters:
    ///   - id: The window's identifier.
    ///   - title: The window's title.
    ///   - sceneID: The extension scene the app hosts in the window.
    public init(id: PaneID, title: String, sceneID: String) {
        self.id = id
        self.title = title
        self.sceneID = sceneID
    }
}

/// A status item an app-tier plug-in contributes to the windows' status
/// bar: one reading — a symbol and a short text — the app draws itself, so
/// no extension scene is hosted for a dozen points of text. The manifest
/// declares the item; the plug-in gives it a text while it has something to
/// report (``PlugInConnection/setStatusText(_:for:)``), and the item is
/// absent from the bar while it has none. Like the bar's own readings it
/// reports and never acts (GLOSSARY.md, "Status bar").
public struct StatusItemDescriptor: Hashable, Sendable, Codable, Identifiable {
    /// The item's identifier within the plug-in.
    public let id: StatusItemID

    /// What the reading is (`Tally Link`): the item's tooltip and the name
    /// VoiceOver says before the text.
    public let title: String

    /// The SF Symbol before the text.
    public let systemImage: String

    /// Creates a status item descriptor.
    ///
    /// - Parameters:
    ///   - id: The item's identifier within the plug-in.
    ///   - title: What the reading is.
    ///   - systemImage: The SF Symbol before the text.
    public init(id: StatusItemID, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}
