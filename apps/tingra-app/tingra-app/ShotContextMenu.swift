//
//  ShotContextMenu.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// Which surface a shot's context menu is attached to: the switcher rows'
/// shot buttons across the main window, or the sidebar's shot rows.
///
/// ``PresetMenuSurface`` one level down. The menu is one view
/// (``ShotContextMenu``) on both, so the two cannot drift — but two controls
/// performing one action still report separately (EVENTS.md, "The `tap`
/// convention"), a horizontal row moves things left and right where a
/// vertical list moves them up and down, and the two surfaces remove
/// differently: the switcher's Remove Shot is immediate, the sidebar's Delete
/// asks first. The surface is what says which `tap` names and which words a
/// given menu carries.
///
/// The switcher surface exists even though the rows are hidden by default
/// (``SwitcherRowsPreferences``): an operator who turns them on gets the same
/// menu on them the sidebar has, under the names the rows always reported.
enum ShotMenuSurface: Sendable, CaseIterable {
    /// The Program row of the main window's switcher rows.
    case switcher

    /// The Shots section of the main window's sidebar.
    case sidebar

    /// The actions the menu and its rename dialog report.
    enum Action: Sendable, CaseIterable {
        /// The Duplicate item.
        case duplicate

        /// The Rename… item, which opens the dialog.
        case rename

        /// A choice in the Default Transition submenu.
        case defaultTransition

        /// The item moving the shot one place earlier: Move Left on the
        /// switcher, Move Up in the sidebar.
        case moveEarlier

        /// The item moving the shot one place later: Move Right on the
        /// switcher, Move Down in the sidebar.
        case moveLater

        /// The removing item: Remove Shot on the switcher, Delete in the
        /// sidebar.
        case remove

        /// The rename dialog's confirm button.
        case renameConfirm

        /// The rename dialog's cancel button.
        case renameCancel
    }

    /// The `tap` name one of the menu's actions reports from this surface.
    ///
    /// The switcher keeps the names the shot buttons have always reported
    /// (`shotRename.menu` and so on); the sidebar's are prefixed
    /// `sidebarShot`, on the pattern its rows already follow
    /// (`sidebarShot.row`), and its remove item keeps the `sidebarShotDelete.menu`
    /// name it reported when Delete was the only item it had. The move items
    /// are named for the direction the operator sees, since that is what a
    /// log reader replaying a session would look for.
    ///
    /// - Parameter action: The action reporting.
    /// - Returns: The tap name.
    func tapName(for action: Action) -> String {
        let prefix =
            switch self {
            case .switcher: "shot"
            case .sidebar: "sidebarShot"
            }
        switch action {
        case .duplicate:
            return "\(prefix)Duplicate.menu"
        case .rename:
            return "\(prefix)Rename.menu"
        case .defaultTransition:
            return "\(prefix)DefaultTransition.menu"
        case .moveEarlier:
            return "\(prefix)\(self == .switcher ? "MoveLeft" : "MoveUp").menu"
        case .moveLater:
            return "\(prefix)\(self == .switcher ? "MoveRight" : "MoveDown").menu"
        case .remove:
            return "\(prefix)\(self == .switcher ? "Remove" : "Delete").menu"
        case .renameConfirm:
            return "\(prefix)RenameConfirm.button"
        case .renameCancel:
            return "\(prefix)RenameCancel.button"
        }
    }
}

/// One shot's context menu: duplicate, rename, set its default transition,
/// reorder, and remove that shot (ARCHITECTURE.md, "Shot management", "Shot
/// and preset reordering", "Per-shot default transitions").
///
/// Shared by the switcher rows' shot buttons and the sidebar's shot rows, so
/// right-clicking a shot offers the same commands wherever the shot is
/// listed — which matters now that the switcher rows are hidden by default:
/// the sidebar is where an operator manages shots unless they turn the rows
/// on. ``ShotMenuSurface`` supplies each surface's `tap` names and the
/// direction words its reorder items use. Reorder rides the menu rather than
/// drag-and-drop so a shot button's single click stays reserved for the
/// on-air take.
///
/// The rename **dialog** and the removal are the caller's: a context menu
/// cannot present an alert from inside itself, so Rename… hands the shot back
/// through `onRename` and the owning view opens the dialog
/// (``ShotRenameDialog``); the remove item hands it back through `onRemove`
/// because the two surfaces remove differently — the switcher removes at
/// once (shots are quick to create, switch, and discard; GLOSSARY.md,
/// "Shot"), the sidebar raises its confirmation first, since a compact row
/// in a scanned list should not lose a shot to one stray click.
struct ShotContextMenu: View {
    /// The engine model the commands act on.
    let model: EngineModel

    /// The shot the menu was opened on.
    let shot: Shot

    /// Which surface the menu is attached to.
    let surface: ShotMenuSurface

    /// What Rename… does after its `tap`: the caller opens its rename dialog
    /// over this shot.
    let onRename: (Shot) -> Void

    /// What the remove item does after its `tap`: the caller removes the
    /// shot, or asks first.
    let onRemove: (Shot) -> Void

    /// The items, in the order the preset menu uses, with the Default
    /// Transition submenu after Rename….
    var body: some View {
        let index = model.shots.firstIndex { $0.id == shot.id }

        Button {
            model.eventBus.tap(
                surface.tapName(for: .duplicate),
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            model.duplicateShot(shot.id)
        } label: {
            Text("Duplicate", comment: "Context menu: duplicate this shot or preset")
        }

        Button {
            model.eventBus.tap(
                surface.tapName(for: .rename),
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            onRename(shot)
        } label: {
            Text("Rename…", comment: "Context menu: rename this shot or preset")
        }

        Menu {
            defaultTransitionPicker
        } label: {
            Text("Default Transition", comment: "Shot context menu: submenu setting this shot's default transition")
        }

        Divider()

        Button {
            guard let index else { return }
            model.eventBus.tap(
                surface.tapName(for: .moveEarlier),
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "index": .int(index)]
            )
            model.moveShot(shot.id, to: index - 1)
        } label: {
            switch surface {
            case .switcher:
                Text("Move Left", comment: "Context menu: move this shot or preset earlier in the switcher order")
            case .sidebar:
                Text("Move Up", comment: "Sidebar shot context menu: move this shot earlier in the preset's order")
            }
        }
        .disabled((index ?? 0) <= 0)

        Button {
            guard let index else { return }
            model.eventBus.tap(
                surface.tapName(for: .moveLater),
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "index": .int(index)]
            )
            model.moveShot(shot.id, to: index + 1)
        } label: {
            switch surface {
            case .switcher:
                Text("Move Right", comment: "Context menu: move this shot or preset later in the switcher order")
            case .sidebar:
                Text("Move Down", comment: "Sidebar shot context menu: move this shot later in the preset's order")
            }
        }
        .disabled(index.map { $0 >= model.shots.count - 1 } ?? true)

        Divider()

        Button(role: .destructive) {
            model.eventBus.tap(
                surface.tapName(for: .remove),
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            onRemove(shot)
        } label: {
            switch surface {
            case .switcher:
                Text("Remove Shot", comment: "Shot context menu: remove this shot from the preset")
            case .sidebar:
                Text("Delete", comment: "Sidebar shot context menu item, and its confirmation's confirm button")
            }
        }
    }

    /// The Default Transition submenu's picker: a checkmarked radio group
    /// choosing the shot's ``Shot/defaultTransition`` — None (an unresolved
    /// take is a cut), Cut, Dissolve, a wipe from each frame edge, or a
    /// built-in shader transition, all at the default durations, matching
    /// what the transition panel's own picker offers (ARCHITECTURE.md,
    /// "Per-shot default transitions"). The selection binding reports its
    /// `tap` event in its setter — the menu item is where this user action
    /// executes (EVENTS.md, "The `tap` convention") — then hands the edit to
    /// the model, which autosaves it like any other document edit.
    private var defaultTransitionPicker: some View {
        let selection = Binding<DefaultTransitionChoice> {
            DefaultTransitionChoice(shot.defaultTransition)
        } set: { choice in
            var params: [String: EventValue] = [
                "shot": .string(shot.id.rawValue),
                "transition": .string(choice.tapValue),
            ]
            if case .wipe(let edge) = choice { params["edge"] = .string(edge.rawValue) }
            if case .shader(let name) = choice { params["shader"] = .string(name.rawValue) }
            model.eventBus.tap(surface.tapName(for: .defaultTransition), domain: .composition, params: params)
            model.setShotDefaultTransition(choice.transition, for: shot.id)
        }
        return Picker(selection: selection) {
            Text("No Default", comment: "Default transition option: this shot has no default, so it is taken as set")
                .tag(DefaultTransitionChoice.none)
            Text("Cut", comment: "Transition picker option: switch to the next shot taken instantly")
                .tag(DefaultTransitionChoice.cut)
            Text("Dissolve", comment: "Transition picker option: crossfade to the next shot taken")
                .tag(DefaultTransitionChoice.dissolve)
            Text("Wipe from Left", comment: "Default transition option: wipe revealing this shot from the left edge")
                .tag(DefaultTransitionChoice.wipe(.left))
            Text("Wipe from Right", comment: "Default transition option: wipe revealing this shot from the right edge")
                .tag(DefaultTransitionChoice.wipe(.right))
            Text("Wipe from Top", comment: "Default transition option: wipe revealing this shot from the top edge")
                .tag(DefaultTransitionChoice.wipe(.top))
            Text(
                "Wipe from Bottom",
                comment: "Default transition option: wipe revealing this shot from the bottom edge"
            )
            .tag(DefaultTransitionChoice.wipe(.bottom))
            Text("Iris", comment: "Shader picker option: circular reveal opening from the center")
                .tag(DefaultTransitionChoice.shader(.iris))
            Text("Diagonal", comment: "Shader picker option: diagonal sweep from the top-left corner")
                .tag(DefaultTransitionChoice.shader(.diagonal))
            Text("Blinds", comment: "Shader picker option: horizontal bands revealing in parallel")
                .tag(DefaultTransitionChoice.shader(.blinds))
        } label: {
            EmptyView()
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The Default Transition submenu's selectable choices, mapping a shot's
/// stored ``Shot/defaultTransition`` to and from a checkmarkable menu
/// selection. The mapping is by kind and edge only — a stored default with a
/// hand-edited duration still checkmarks its kind, and choosing a kind here
/// stores it at the default duration, matching what the transition panel's
/// own picker takes with.
private enum DefaultTransitionChoice: Hashable {
    /// No default: an unresolved take of this shot is a cut.
    case none

    /// An instant cut.
    case cut

    /// A crossfade at the default dissolve duration.
    case dissolve

    /// A directional reveal from the given frame edge at the default wipe
    /// duration.
    case wipe(WipeEdge)

    /// A custom-shader reveal with the given built-in shader at the default
    /// shader-transition duration.
    case shader(TransitionShader)

    /// The choice a stored default transition checkmarks.
    ///
    /// - Parameter transition: The shot's stored default, or nil for none.
    /// (`Transition` is module-qualified here: at this file's scope the name
    /// would otherwise collide with SwiftUI's `Transition` protocol.)
    init(_ transition: TingraComposition.Transition?) {
        switch transition {
        case Optional.none:
            self = .none
        case .some(.cut):
            self = .cut
        case .some(.dissolve(duration: _)):
            self = .dissolve
        case .some(.wipe(edge: let edge, duration: _)):
            self = .wipe(edge)
        case .some(.shader(name: let name, duration: _)):
            self = .shader(name)
        }
    }

    /// The default transition this choice stores on the shot — nil for
    /// ``none``, the concrete transition at its default duration otherwise.
    var transition: TingraComposition.Transition? {
        switch self {
        case .none: nil
        case .cut: .cut
        case .dissolve: .dissolve
        case .wipe(let edge): .wipe(edge: edge)
        case .shader(let name): .shader(name: name)
        }
    }

    /// The choice's stable name for the menu's `tap` event params (the wipe
    /// edge and the shader name ride in separate `edge`/`shader` params).
    var tapValue: String {
        switch self {
        case .none: "none"
        case .cut: "cut"
        case .dissolve: "dissolve"
        case .wipe: "wipe"
        case .shader: "shader"
        }
    }
}

/// The shot rename alert — a text field prefilled with the shot's name,
/// Rename and Cancel — presented by whichever surface's menu opened it.
///
/// ``PresetRenameDialog``'s shape: a modifier rather than a view so the two
/// surfaces carrying ``ShotContextMenu`` present one dialog with one pair of
/// `tap` names per surface, each keeping its own subject — which shot is
/// being renamed is transient session state that belongs to the view showing
/// the dialog. The `isPresented` binding derives from the subject and clears
/// it on dismissal, so Escape and Cancel both leave nothing pending.
struct ShotRenameDialog: ViewModifier {
    /// The engine model the rename is applied to.
    let model: EngineModel

    /// Which surface opened the dialog, for its buttons' `tap` names.
    let surface: ShotMenuSurface

    /// The shot being renamed, or `nil` while the dialog is closed.
    @Binding var shot: Shot?

    /// The dialog's working text, prefilled by the caller with the shot's
    /// current name.
    @Binding var text: String

    /// Whether the dialog is up.
    private var isPresented: Binding<Bool> {
        Binding {
            shot != nil
        } set: { presented in
            if !presented { shot = nil }
        }
    }

    func body(content: Content) -> some View {
        content.alert(
            Text("Rename Shot", comment: "Rename shot dialog title"),
            isPresented: isPresented,
            presenting: shot
        ) { shot in
            TextField(text: $text) {
                Text("Name", comment: "Name text field label — for a shot, a preset, or a destination")
            }
            Button {
                model.eventBus.tap(
                    surface.tapName(for: .renameConfirm),
                    domain: .composition,
                    params: ["shot": .string(shot.id.rawValue), "name": .string(text)]
                )
                model.renameShot(shot.id, to: text)
            } label: {
                Text("Rename", comment: "Rename dialog confirm button, for a shot or a preset")
            }
            Button(role: .cancel) {
                model.eventBus.tap(
                    surface.tapName(for: .renameCancel),
                    domain: .composition,
                    params: ["shot": .string(shot.id.rawValue)]
                )
            } label: {
                Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
            }
        }
    }
}

extension View {
    /// Attaches the shot rename dialog (``ShotRenameDialog``).
    ///
    /// - Parameters:
    ///   - model: The engine model the rename is applied to.
    ///   - surface: Which surface opened it, for its `tap` names.
    ///   - shot: The shot being renamed, or `nil` while closed.
    ///   - text: The dialog's working text.
    /// - Returns: The view with the dialog attached.
    func shotRenameDialog(
        model: EngineModel,
        surface: ShotMenuSurface,
        shot: Binding<Shot?>,
        text: Binding<String>
    ) -> some View {
        modifier(ShotRenameDialog(model: model, surface: surface, shot: shot, text: text))
    }
}
