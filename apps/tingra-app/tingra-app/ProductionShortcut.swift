//
//  ProductionShortcut.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The production keyboard shortcuts the app binds — the closed list that is
/// both the **binding** the controls apply and the **listing** the Shortcuts
/// settings tab prints, so a shortcut can never be documented as one thing and
/// bound as another.
///
/// **Where the assignments come from.** They are not invented: each mirrors
/// what the professional macOS switchers already do, so an operator arriving
/// from one of them is not retrained. The survey (2026-08-08) covered
/// Blackmagic's ATEM Software Control, MixEffect (the native Apple ATEM
/// controller), Ecamm Live, Telestream Wirecast, Boinx mimoLive, and OBS
/// Studio, and five actions carry a default in more than one of them:
///
/// | Action | Prior art |
/// | --- | --- |
/// | Stage the *n*th shot | ATEM `1`–`8`, MixEffect ⌘1–⌘0, Ecamm ⌘1–⌘9, Wirecast ⌥+number |
/// | Cut | MixEffect ⇧⌘↩, ATEM `Space` |
/// | Fade to black | MixEffect ⌃⌥⌘F, and the latched FTB of every hardware panel |
/// | Go live | Ecamm ⌘G, MixEffect ⌃⌥⇧⌘S, the OBS ⌃⇧S convention |
/// | Record | MixEffect ⌃⌥⇧⌘R, Ecamm ⌘P/⌥⇧⌘N, the OBS convention |
///
/// And the take, which is the one worth stating plainly because the guess is
/// usually wrong: **the industry's take key is Return, not ⌘T** — ATEM's AUTO
/// is `Return`, MixEffect's Auto Transition is ⌘↩, and Ecamm publishes
/// preview on `↩`. ⌘T is Show Fonts on macOS and means "new tab" everywhere
/// else, so it would be the one assignment an operator has to unlearn. The
/// bare keys those apps use (`1`–`8`, `Space`, `Return`) are Windows-derived
/// and would swallow typing in every text field this window has, so each is
/// taken in its ⌘ form — which is also the form the two native Apple apps in
/// the survey, MixEffect and Ecamm Live, already use.
///
/// The production shortcuts are attached to the controls themselves rather
/// than to menu items, following the Fade to Black button that already carried
/// ⇧⌘B: a shortcut bound to the real control inherits the control's disabled
/// state (Take is dead while nothing is staged) and its state (Start Streaming
/// carries the stream keys the operator has typed but not yet submitted),
/// where a parallel menu command would have to reconstruct both and could
/// drift from them. The Shortcuts settings tab is the discovery surface.
///
/// ``toggleStatusBar`` is the one exception, and it proves the rule rather than
/// bending it: window chrome has no control to hang a shortcut on, so it rides
/// the View-menu item (``StatusBarCommands``) — which binds *this* case, so the
/// pane and the menu bar still cannot disagree.
///
/// **The case order is the reading order** the Shortcuts pane prints, so the
/// pane needs no list of its own: stage a shot, take it (instantly or over the
/// armed transition), take the program down, the two session controls, then the
/// one window command.
enum ProductionShortcut: String, CaseIterable, Sendable {
    /// Stage the *n*th shot of the switcher on preview — ⌘1 through ⌘9.
    case stageShot

    /// Take the staged shot to program with a hard cut, whatever the
    /// transition picker selects — ⇧⌘↩.
    case cut

    /// Take the staged shot to program with the selected transition — ⌘↩.
    case take

    /// Latch the whole program off air, picture and sound, or bring it back —
    /// ⇧⌘B.
    case fadeToBlack

    /// Put the program on air, or take it off — ⌘G.
    case goLive

    /// Start or stop recording the program to a local file — ⌘R.
    case record

    /// Show or hide the window's status bar — ⌘/. The one window command in
    /// the list: it has no control of its own, so the View-menu item binds it
    /// (see the type's note above).
    case toggleStatusBar

    /// The highest shot position that gets a shortcut — ⌘1 through ⌘9,
    /// stopping short of ⌘0 so the digit and the position never disagree.
    static let stageShotLimit = 9

    /// The key a shot at the given switcher position is staged with, or nil
    /// for a position past ``stageShotLimit``.
    ///
    /// - Parameter index: The shot's zero-based position in the preview row.
    /// - Returns: The digit key that stages it, or nil when it has none.
    static func stageShotKey(forIndex index: Int) -> KeyEquivalent? {
        guard index >= 0, index < stageShotLimit else { return nil }
        // 1...9 is one character wide by construction, so the digit is the
        // whole string — no formatting decision to make.
        guard let digit = String(index + 1).first else { return nil }
        return KeyEquivalent(digit)
    }

    /// The shortcut that stages the shot at the given switcher position, or
    /// nil past ``stageShotLimit`` — what the preview row hands
    /// `keyboardShortcut(_:)`, whose optional overload leaves a tenth shot
    /// unbound rather than needing a branch at the call site.
    ///
    /// - Parameter index: The shot's zero-based position in the preview row.
    /// - Returns: The shortcut that stages it, or nil when it has none.
    static func stageShotShortcut(forIndex index: Int) -> KeyboardShortcut? {
        stageShotKey(forIndex: index).map { KeyboardShortcut($0, modifiers: stageShot.modifiers) }
    }

    /// The key the shortcut is bound to, or nil for ``stageShot``, which is a
    /// range of keys rather than one (see ``stageShotKey(forIndex:)``).
    var key: KeyEquivalent? {
        switch self {
        case .stageShot: nil
        case .cut, .take: .return
        case .fadeToBlack: "b"
        case .goLive: "g"
        case .record: "r"
        case .toggleStatusBar: "/"
        }
    }

    /// The modifiers held with ``key``.
    var modifiers: EventModifiers {
        switch self {
        case .stageShot, .take, .goLive, .record, .toggleStatusBar: .command
        case .cut, .fadeToBlack: [.command, .shift]
        }
    }

    /// The shortcut as SwiftUI binds it, or nil for ``stageShot`` — see
    /// ``stageShotShortcut(forIndex:)`` for that one, whose key depends on
    /// the shot's position.
    var shortcut: KeyboardShortcut? {
        key.map { KeyboardShortcut($0, modifiers: modifiers) }
    }

    /// The shortcut as macOS prints it — modifier glyphs in the system's own
    /// order (⌃⌥⇧⌘) followed by the key, so the settings tab reads the way a
    /// menu does.
    var symbol: String {
        switch self {
        case .stageShot:
            "\(Self.symbol(modifiers: modifiers, keyLabel: "1")) – \(Self.symbol(modifiers: modifiers, keyLabel: "9"))"
        case .cut, .take:
            Self.symbol(modifiers: modifiers, keyLabel: "↩")
        case .fadeToBlack:
            Self.symbol(modifiers: modifiers, keyLabel: "B")
        case .goLive:
            Self.symbol(modifiers: modifiers, keyLabel: "G")
        case .record:
            Self.symbol(modifiers: modifiers, keyLabel: "R")
        case .toggleStatusBar:
            Self.symbol(modifiers: modifiers, keyLabel: "/")
        }
    }

    /// The action's name, as the Shortcuts tab labels it.
    var name: Text {
        switch self {
        case .stageShot:
            Text("Stage Shot on Preview", comment: "Shortcuts settings: name of the ⌘1–⌘9 action")
        case .cut:
            // The same key *and the same comment* as the transition picker's
            // Cut option, so string extraction keeps one entry rather than
            // splitting one word in two (see ``ContentView/programLabel``).
            Text(
                "Cut",
                comment:
                    "Switch to the next shot taken instantly — the transition picker option, and the Cut button"
            )
        case .take:
            Text("Take", comment: "Button taking the shot staged on preview to program")
        case .fadeToBlack:
            Text("Fade to Black", comment: "Button taking the whole program — picture and sound — off air, and back")
        case .goLive:
            Text("Go Live", comment: "Shortcuts settings: name of the start/stop streaming action")
        case .record:
            Text("Record", comment: "Button that starts recording the program to a local file")
        case .toggleStatusBar:
            Text("Show or Hide Status Bar", comment: "Shortcuts settings: name of the ⌘/ action")
        }
    }

    /// What the shortcut does, in one line beneath its name.
    var detail: Text {
        switch self {
        case .stageShot:
            Text(
                "Stages the shot in that position of the switcher, ready to take.",
                comment: "Shortcuts settings: what ⌘1–⌘9 does"
            )
        case .cut:
            Text(
                "Takes the staged shot to program instantly, whatever transition is selected.",
                comment: "Shortcuts settings: what the cut shortcut does"
            )
        case .take:
            Text(
                "Takes the staged shot to program with the selected transition, swapping the buses.",
                comment: "Shortcuts settings: what the take shortcut does"
            )
        case .fadeToBlack:
            Text(
                "Takes the whole program off air — picture and sound — and brings it back.",
                comment: "Shortcuts settings: what the fade to black shortcut does"
            )
        case .goLive:
            Text(
                "Puts the program on air to every enabled destination, or takes it off.",
                comment: "Shortcuts settings: what the go live shortcut does"
            )
        case .record:
            Text(
                "Starts recording the program to a local file, or stops and closes it.",
                comment: "Shortcuts settings: what the record shortcut does"
            )
        case .toggleStatusBar:
            Text(
                "Shows or hides the bar reporting recording and streaming across the bottom of the window.",
                comment: "Shortcuts settings: what the status bar shortcut does"
            )
        }
    }

    /// Assembles a shortcut's printed form.
    ///
    /// The glyph order is macOS's, not the order the modifiers were written
    /// in: Control, Option, Shift, Command. A tab that printed ⌘⇧B where the
    /// menu bar prints ⇧⌘B would read as a different shortcut.
    ///
    /// - Parameters:
    ///   - modifiers: The modifiers held.
    ///   - keyLabel: The key's own glyph or letter.
    /// - Returns: The shortcut as macOS prints it.
    private static func symbol(modifiers: EventModifiers, keyLabel: String) -> String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + keyLabel
    }
}
