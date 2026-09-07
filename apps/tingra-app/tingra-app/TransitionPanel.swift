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
/// staged on preview to program — Cut, Take, and the transition the take
/// uses — with Fade to Black at the far end, the hardware panel's own
/// arrangement (CUT and AUTO beside each other, the transition type above
/// them, FTB off to the side).
///
/// Its own panel, under its own heading, because these controls used to
/// trail the preview row of shot buttons, and that row is gone (the shot
/// bank is the switcher row now — ARCHITECTURE.md, "The shot bank"): the take
/// must have a home that is always on screen, and it deserves one anyway —
/// Take is the one step to air, and it should not be the last button on a
/// row of nine.
///
/// **What the panel does not repeat.** Which shot is staged and which is on
/// program are read off the monitors' captions directly above; the panel
/// only says what to do about it. Its one line of text appears when there is
/// nothing to take, so a disabled Take never reads as broken.
///
/// **The two transition pickers show only while they apply.** A wipe has an
/// edge and a shader has a name; a cut has neither, and a control for a
/// choice that does not exist would be a control the operator has to learn
/// to ignore. The kind picker itself is always present, so the panel's
/// height is stable across kinds except for that trailing control.
///
/// Every control reports its own `tap` where the action executes (EVENTS.md,
/// "The `tap` convention"), under the names these controls have always
/// reported from the switcher rows, so a log reader sees the same session
/// whichever surface the take came from. The shortcuts stay on the controls
/// they fire (``ProductionShortcut``): Cut ⇧⌘↩, Take ⌘↩, Fade to Black ⇧⌘B —
/// a shortcut on the control inherits the control's disabled state, so ⌘↩
/// with nothing staged does nothing, as the Take button does.
struct TransitionPanel: View {
    /// The engine model, bindable so the pickers drive its transition
    /// selection.
    @Bindable var model: EngineModel

    /// The panel: heading, the transition kind (and its detail picker), then
    /// the transport buttons.
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
            }

            HStack(spacing: 12) {
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

                fadeToBlackControl
            }
        }
    }

    /// The transport buttons' minimum width, so Cut and Take read as a
    /// matched pair whatever their titles' lengths in a given language.
    private static let transportButtonWidth: CGFloat = 72

    /// The transition kind picker: Default (each shot's own default
    /// transition, ``EngineModel/takeTransitionKind``), or an explicit Cut,
    /// Dissolve, Wipe, or Shader overriding it for the next take. Its label
    /// is the panel's heading, so the picker's own is hidden but kept for
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
        .pickerStyle(.segmented)
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

    /// The **fade to black** control: one latching button that takes the
    /// whole program off air — picture *and* sound together — and brings it
    /// back (GLOSSARY.md, "Fade to black").
    ///
    /// At the panel's trailing end rather than among the transport buttons,
    /// because it is a **master stage rather than a transition**: a
    /// transition is the move from one shot to the next, where this holds
    /// across shot switches. It stays enabled when the preset has no shots —
    /// the operator must always be able to take the program down. Prominent
    /// and red while active, the broadcast convention for a latched FTB.
    private var fadeToBlackControl: some View {
        HStack(spacing: 8) {
            if model.isFadedToBlack {
                Text(
                    "Viewers see and hear nothing. Preview and multiview stay live.",
                    comment: "Hint beside the fade to black control while the program is off air"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                model.eventBus.tap(
                    "fadeToBlack.button",
                    domain: .composition,
                    params: ["state": .string(model.isFadedToBlack ? "clear" : "black")]
                )
                model.setFadeToBlack(!model.isFadedToBlack)
            } label: {
                ProductionShortcut.fadeToBlack.name
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.isFadedToBlack ? .red : .gray)
            .keyboardShortcut(ProductionShortcut.fadeToBlack.shortcut)
        }
    }
}
