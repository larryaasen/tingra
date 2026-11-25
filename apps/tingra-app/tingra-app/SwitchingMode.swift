//
//  SwitchingMode.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-24.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The **switching mode**: what picking a shot does, for a whole show
/// (GLOSSARY.md, "Switching mode"; ARCHITECTURE.md, "Taking a shot with one
/// click"). A setting of the switcher rather than of any show, so it is
/// remembered machine-locally beside the armed transition
/// (``SessionPreferences``) and stays out of the project document.
///
/// The raw values are what the preferences store, so they stay as they are.
enum SwitchingMode: String, CaseIterable, Sendable {
    /// Picking a shot stages it on preview, and Take or Cut is the one step
    /// to air. The default.
    case stageOnPreview

    /// Picking a shot takes it to program with the armed transition.
    case takeToProgram

    /// The mode's name, as the transition panel's picker and the glossary
    /// spell it.
    var title: Text {
        switch self {
        case .stageOnPreview:
            Text(
                "Stage on Preview",
                comment: "Switching mode, and the shot context menu item: picking a shot stages it on preview")
        case .takeToProgram:
            Text("Take to Program", comment: "Switching mode: picking a shot takes it to program")
        }
    }

    /// The tooltip on a shot's tile or sidebar row, naming what a click does
    /// in this mode, so no click on a shot goes to air unannounced.
    var shotHelp: Text {
        switch self {
        case .stageOnPreview:
            Text("Stage on preview", comment: "Tooltip on an input tile that stages it on preview")
        case .takeToProgram:
            Text(
                "Take to program. Option-click to stage on preview.",
                comment: "Tooltip on a shot tile or sidebar shot row while the switching mode is Take to Program")
        }
    }
}
