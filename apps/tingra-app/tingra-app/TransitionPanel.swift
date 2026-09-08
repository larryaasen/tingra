//
//  TransitionPanel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// The main window's **transition panel**: the controls that move what is
/// staged on preview to program — the transition the take uses, then Cut and
/// Take — on one row under a Transition heading.
///
/// Its own panel, under its own heading, because these controls used to
/// trail the preview row of shot buttons, and that row is gone (the shot
/// bank is the switcher row now — ARCHITECTURE.md, "The shot bank"): the take
/// must have a home that is always on screen, and it deserves one anyway —
/// Take is the one step to air, and it should not be the last button on a
/// row of nine.
///
/// **One row, reading left to right in the order the operator works it**
/// (2026-09-07): arm a transition, then take. The transition kind is a
/// **pop-up menu** rather than the segmented control it started as — four
/// segments plus a heading took a row of their own, where a pop-up names the
/// armed transition in one word and leaves the row to the buttons. The wipe
/// edge and shader pickers show beside it only while they apply: a wipe has
/// an edge and a shader has a name, a cut has neither, and a control for a
/// choice that does not exist would be a control the operator has to learn
/// to ignore. The kind menu itself is always present, so the row's leading
/// edge is stable across kinds.
///
/// **What the panel does not carry.** Which shot is staged and which is on
/// program are read off the monitors' captions directly above; the panel
/// only says what to do about it. Its one line of text appears when there is
/// nothing to take, so a disabled Take never reads as broken. Fade to Black
/// is not here either: it is a master stage rather than a transition (it
/// holds across shot switches), and it lives in the window's toolbar with
/// the other controls that change what viewers get (``FadeToBlackButton``).
///
/// Every control reports its own `tap` where the action executes (EVENTS.md,
/// "The `tap` convention"), under the names these controls have always
/// reported from the switcher rows, so a log reader sees the same session
/// whichever surface the take came from. The shortcuts stay on the controls
/// they fire (``ProductionShortcut``): Cut ⇧⌘↩ and Take ⌘↩ — a shortcut on
/// the control inherits the control's disabled state, so ⌘↩ with nothing
/// staged does nothing, as the Take button does.
struct TransitionPanel: View {
    /// The engine model, bindable so the pickers drive its transition
    /// selection.
    @Bindable var model: EngineModel

    /// The panel: heading, then the one row — the transition kind (and its
    /// detail picker), Cut, Take, and the hint while nothing is staged.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transition", comment: "Section heading over the Cut, Take, and transition controls")
                .font(.headline)

            HStack(spacing: 12) {
                kindPicker

                if model.takeTransitionKind == .wipe {
                    edgePicker
                }

                if model.takeTransitionKind == .shader {
                    shaderPicker
                }

                // Cut left of Take, the order the two live side by side on a
                // hardware panel: CUT takes instantly, AUTO takes over the
                // armed transition.
                Button {
                    model.eventBus.tap(
                        "cut.button",
                        domain: .composition,
                        params: ["shot": .string(model.previewShotID?.rawValue ?? "none")]
                    )
                    model.cutPreview()
                } label: {
                    ProductionShortcut.cut.name
                        .frame(minWidth: Self.transportButtonWidth)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.previewShotID == nil)
                .keyboardShortcut(ProductionShortcut.cut.shortcut)
                .help(
                    Text(
                        "Take the staged shot to program instantly",
                        comment: "Tooltip on the Cut button"
                    )
                )

                Button {
                    model.eventBus.tap(
                        "take.button",
                        domain: .composition,
                        params: ["shot": .string(model.previewShotID?.rawValue ?? "none")]
                    )
                    model.takePreview()
                } label: {
                    ProductionShortcut.take.name
                        .fontWeight(.semibold)
                        .frame(minWidth: Self.transportButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .disabled(model.previewShotID == nil)
                .keyboardShortcut(ProductionShortcut.take.shortcut)
                .help(
                    Text(
                        "Take the staged shot to program with the selected transition",
                        comment: "Tooltip on the Take button"
                    )
                )

                if model.previewShotID == nil {
                    Text(
                        "Stage a shot on preview to take it.",
                        comment: "Hint beside the Take button while nothing is staged on preview"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// The transport buttons' minimum width, so Cut and Take read as a
    /// matched pair whatever their titles' lengths in a given language.
    private static let transportButtonWidth: CGFloat = 72

    /// The transition kind picker: Default (each shot's own default
    /// transition, ``EngineModel/takeTransitionKind``), or an explicit Cut,
    /// Dissolve, Wipe, or Shader overriding it for the next take. A pop-up
    /// menu, so the armed kind reads as one word on the row. Its label is the
    /// panel's heading, so the picker's own is hidden but kept for
    /// accessibility.
    private var kindPicker: some View {
        Picker(
            selection: $model.takeTransitionKind.reportingTap(
                to: model.eventBus, "transition.picker", domain: .composition,
                params: { ["kind": .string($0.rawValue)] })
        ) {
            Text(
                "Default",
                comment: "Transition picker option: take each shot with its own default transition"
            )
            .tag(TakeTransitionKind.default)
            Text(
                "Cut",
                comment:
                    "Switch to the next shot taken instantly — the transition picker option, and the Cut button"
            )
            .tag(TakeTransitionKind.cut)
            Text("Dissolve", comment: "Transition picker option: crossfade to the next shot taken")
                .tag(TakeTransitionKind.dissolve)
            Text(
                "Wipe",
                comment:
                    "Transition picker option: reveal the next shot taken across the frame from an edge"
            )
            .tag(TakeTransitionKind.wipe)
            Text(
                "Shader",
                comment:
                    "Transition picker option: reveal the next shot taken through a built-in custom shader"
            )
            .tag(TakeTransitionKind.shader)
        } label: {
            Text(
                "Transition",
                comment: "Label of the picker choosing the transition kind for the next shot take")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    /// The wipe edge picker, shown while Wipe is the selected kind.
    private var edgePicker: some View {
        Picker(
            selection: $model.wipeEdge.reportingTap(
                to: model.eventBus, "wipeEdge.picker", domain: .composition,
                params: { ["edge": .string($0.rawValue)] })
        ) {
            Text("Left", comment: "Wipe edge picker option: reveal from the left edge of the frame")
                .tag(WipeEdge.left)
            Text("Right", comment: "Wipe edge picker option: reveal from the right edge of the frame")
                .tag(WipeEdge.right)
            Text("Top", comment: "Wipe edge picker option: reveal from the top edge of the frame")
                .tag(WipeEdge.top)
            Text("Bottom", comment: "Wipe edge picker option: reveal from the bottom edge of the frame")
                .tag(WipeEdge.bottom)
        } label: {
            Text(
                "Edge",
                comment: "Label of the picker choosing the frame edge a wipe reveals the next shot from"
            )
        }
        .fixedSize()
    }

    /// The shader picker, shown while Shader is the selected kind.
    private var shaderPicker: some View {
        Picker(
            selection: $model.shaderName.reportingTap(
                to: model.eventBus, "shaderName.picker", domain: .composition,
                params: { ["shader": .string($0.rawValue)] })
        ) {
            Text("Iris", comment: "Shader picker option: circular reveal opening from the center")
                .tag(TransitionShader.iris)
            Text(
                "Diagonal",
                comment: "Shader picker option: diagonal sweep from the top-left corner"
            )
            .tag(TransitionShader.diagonal)
            Text("Blinds", comment: "Shader picker option: horizontal bands revealing in parallel")
                .tag(TransitionShader.blinds)
        } label: {
            Text(
                "Shader",
                comment:
                    "Label of the picker choosing the built-in shader a shader transition reveals with"
            )
        }
        .fixedSize()
    }
}
