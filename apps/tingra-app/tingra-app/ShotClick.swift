//
//  ShotClick.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-24.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraComposition

/// What picking a shot does: the two actions the click rule chooses between
/// (``ShotClick/action(mode:modifiers:)``).
enum ShotClickAction: Sendable, CaseIterable {
    /// Stage the shot on preview.
    case stage

    /// Take the shot to program.
    case take
}

/// The surfaces a shot is picked on. Each reports its own `tap` names, one
/// per action, so a log reader can tell a stage from a take and one surface
/// from another (EVENTS.md, "The `tap` convention").
enum ShotClickSurface: Sendable, CaseIterable {
    /// A shot bank tile (``ShotBankView``).
    case shotBank

    /// A Shots menu item, and its ⌘1–⌘9 (``ShotCommands``).
    case menuBar

    /// A sidebar shot row (``LeadingSidebar``).
    case sidebar

    /// The `tap` name the surface reports for an action. The stage names are
    /// the ones each surface reported before takes existed; a take has its
    /// own, so a stage is never logged as a take or the reverse.
    ///
    /// - Parameter action: The action the pick resolved to.
    /// - Returns: The tap name.
    func tapName(for action: ShotClickAction) -> String {
        switch (self, action) {
        case (.shotBank, .stage): "shotBank.tile"
        case (.shotBank, .take): "shotBankTake.tile"
        case (.menuBar, .stage): "shot.menuItem"
        case (.menuBar, .take): "shotTake.menuItem"
        case (.sidebar, .stage): "sidebarShot.row"
        case (.sidebar, .take): "sidebarShotTake.row"
        }
    }
}

/// One pick of a shot, resolved: the action it means and the `tap` name its
/// surface reports. Every shot surface builds one, reports the tap, then
/// hands the action to ``ProgramControlling/perform(_:on:)``, so the rule
/// lives in one place and the views stay thin (ARCHITECTURE.md, "Taking a
/// shot with one click").
struct ShotClick: Equatable, Sendable {
    /// What the pick does.
    let action: ShotClickAction

    /// The `tap` name the surface reports for it.
    let tapName: String

    /// Resolves a pick on a surface.
    ///
    /// - Parameters:
    ///   - surface: The surface the shot was picked on.
    ///   - mode: The switching mode in force.
    ///   - modifiers: The modifier keys held (the keys held right now by
    ///     default).
    init(on surface: ShotClickSurface, mode: SwitchingMode, modifiers: EventModifiers = .held) {
        action = Self.action(mode: mode, modifiers: modifiers)
        tapName = surface.tapName(for: action)
    }

    /// The click rule: a pick takes the shot only in Take to Program with
    /// Option up. Option leads to preview and never to air, so a
    /// mis-modified click cannot put a shot on program; no other modifier
    /// changes the answer, which is what lets ⌘1–⌘9 follow the mode.
    ///
    /// - Parameters:
    ///   - mode: The switching mode in force.
    ///   - modifiers: The modifier keys held.
    /// - Returns: Whether the pick stages or takes.
    static func action(mode: SwitchingMode, modifiers: EventModifiers) -> ShotClickAction {
        mode == .takeToProgram && !modifiers.contains(.option) ? .take : .stage
    }
}

extension EventModifiers {
    /// The modifier keys held right now, read where a shot's action executes:
    /// SwiftUI hands a button's action no event to read them from.
    static var held: EventModifiers { EventModifiers(NSEvent.modifierFlags) }

    /// The SwiftUI modifiers matching AppKit's flags, for the four keys a
    /// click can be modified with.
    ///
    /// - Parameter flags: The AppKit modifier flags.
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
    }
}

extension ProgramControlling {
    /// Carries out a resolved pick: stages the shot on preview, or takes it
    /// to program with the armed transition. A take leaves preview as it was,
    /// so the layer editor keeps following what is staged. Reports no `tap`
    /// itself: the surface's action closure does.
    ///
    /// - Parameters:
    ///   - action: What the pick resolved to.
    ///   - shotID: The id of the shot picked.
    func perform(_ action: ShotClickAction, on shotID: ShotID) {
        switch action {
        case .stage: setPreview(shotID)
        case .take: take(shotID)
        }
    }
}
