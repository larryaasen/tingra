//
//  AddShotMenu.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus
import TingraPlugInKit

/// Which surface the Add Shot items (``AddShotMenuItems``) are on — the pure,
/// unit-tested source of that surface's `tap` names, on the
/// ``ShotMenuSurface`` pattern.
///
/// Three surfaces open the same items, and three controls performing one
/// action still report separately (EVENTS.md, "The `tap` convention"): a log
/// reader should be able to tell a shot added from the sidebar's Shots
/// section from one added from the Shots heading's plus button over the bank
/// or from the menu bar.
enum AddShotMenuSurface: Sendable, CaseIterable {
    /// The Add Shot submenu of the sidebar's Shots section header context
    /// menu (``SidebarView``).
    case sidebar

    /// The plus button beside the **Shots** heading over the shot bank
    /// (``ContentView``).
    case bank

    /// The Add Shot submenu of the menu bar's Shots menu (``ShotCommands``).
    case menuBar

    /// The menu's items, as far as their `tap` names differ.
    enum Item: Sendable, CaseIterable {
        /// Empty Shot: a new shot with no layers.
        case empty

        /// One of the input items in the Camera, Display, and Video Generator
        /// submenus: a full-frame shot of that input. One name for all three
        /// submenus — the params carry which input, and its kind.
        case input
    }

    /// The `tap` name one of this surface's items reports.
    ///
    /// - Parameter item: The item.
    /// - Returns: `sidebarShotAddEmpty.menuItem` / `sidebarShotAddInput.menuItem`
    ///   on the sidebar; `shotBankAddEmpty.menuItem` / `shotBankAddInput.menuItem`
    ///   on the bank; `shotsMenuAddEmpty.menuItem` / `shotsMenuAddInput.menuItem`
    ///   in the menu bar.
    func tapName(for item: Item) -> String {
        let prefix =
            switch self {
            case .sidebar: "sidebarShotAdd"
            case .bank: "shotBankAdd"
            case .menuBar: "shotsMenuAdd"
            }
        switch item {
        case .empty: return "\(prefix)Empty.menuItem"
        case .input: return "\(prefix)Input.menuItem"
        }
    }
}

/// The **Add Shot** menu opened by a control: ``AddShotMenuItems`` under a
/// caller-drawn label — the Shots heading's plus button over the bank
/// (``ContentView``). The other two surfaces host the items directly, as a
/// submenu of a menu that already exists: the sidebar's Shots section
/// context menu and the menu bar's Shots menu.
struct AddShotMenu<Label: View>: View {
    /// The engine model the items add through, and report their `tap` to.
    let model: EngineModel

    /// Which surface the menu is on.
    let surface: AddShotMenuSurface

    /// The control that opens the menu.
    @ViewBuilder let label: () -> Label

    /// The menu.
    var body: some View {
        Menu {
            AddShotMenuItems(model: model, surface: surface)
        } label: {
            label()
        }
    }
}

/// The **Add Shot** items: Empty Shot, then a Camera, a Display, and a Video
/// Generator submenu listing each discovered input, each item adding a
/// full-frame authored shot of that input to the active preset
/// (ARCHITECTURE.md, "The shot bank").
///
/// One set of items for every place they open — the plus button beside the
/// Shots heading over the bank, the Add Shot submenu of the sidebar's Shots
/// section context menu, and the Add Shot submenu of the menu bar's Shots
/// menu — so the three cannot offer different things. The items are a view
/// rather than a menu because two of those hosts are menus already (a
/// `.contextMenu` and a `CommandMenu`), which only take items;
/// ``AddShotMenuSurface`` supplies the `tap` names.
///
/// A submenu with nothing to list shows the sidebar's own placeholder for
/// that section, disabled, rather than an empty menu: "No cameras connected"
/// is an answer, a blank submenu is a bug.
struct AddShotMenuItems: View {
    /// The engine model the items add through, and report their `tap` to.
    let model: EngineModel

    /// Which surface the items are on.
    let surface: AddShotMenuSurface

    /// The items.
    var body: some View {
        Group {
            Button {
                model.eventBus.tap(surface.tapName(for: .empty), domain: .composition)
                model.addShot()
            } label: {
                Text("Empty Shot", comment: "Add Shot menu item: a new shot with no layers")
            }

            Divider()

            submenu(
                Text("Camera", comment: "Camera input picker label"),
                inputs: model.cameras,
                emptyLabel: Text(
                    "No cameras connected", comment: "Device rail placeholder when no camera is discovered")
            )
            submenu(
                Text("Display", comment: "Display input picker label"),
                inputs: model.displays,
                emptyLabel: Text("No displays available", comment: "Sidebar placeholder when no display is discovered")
            )
            submenu(
                Text("Video Generator", comment: "Add Shot menu submenu listing the video generators"),
                inputs: model.videoInputs.filter { $0.kind == .generator },
                emptyLabel: Text(
                    "No video generators available",
                    comment: "Sidebar placeholder when no video generator is registered"
                )
            )
        }
    }

    /// One submenu of inputs, each item adding a shot showing that input.
    ///
    /// - Parameters:
    ///   - title: The submenu's title.
    ///   - inputs: The inputs to list, in the model's stable order.
    ///   - emptyLabel: What the submenu shows, disabled, when there are none.
    /// - Returns: The submenu.
    private func submenu(_ title: Text, inputs: [EngineModel.InputChoice], emptyLabel: Text) -> some View {
        Menu {
            if inputs.isEmpty {
                Button {
                } label: {
                    emptyLabel
                }
                .disabled(true)
            } else {
                ForEach(inputs) { input in
                    Button {
                        model.eventBus.tap(
                            surface.tapName(for: .input),
                            domain: .composition,
                            params: [
                                "input": .string(input.id.rawValue),
                                "name": .string(input.name),
                                "kind": .string(input.kind.rawValue),
                            ]
                        )
                        Task { await model.addShot(showing: input.id) }
                    } label: {
                        // A device name reported by discovery: runtime data,
                        // drawn verbatim.
                        Text(verbatim: input.name)
                    }
                }
            }
        } label: {
            title
        }
    }
}
