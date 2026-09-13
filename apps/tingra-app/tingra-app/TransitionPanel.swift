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
/// staged on preview to program — Cut and Take, the transition the take
/// uses, and how long it runs — on one row under a Transition heading.
///
/// Its own panel, under its own heading, because these controls used to
/// trail the preview row of shot buttons, and that row is gone (the shot
/// bank is the switcher row now — ARCHITECTURE.md, "The shot bank"): the take
/// must have a home that is always on screen, and it deserves one anyway —
/// Take is the one step to air, and it should not be the last button on a
/// row of nine.
///
/// **One row: the take leads, its settings trail** (Larry, 2026-09-13,
/// revising the 2026-09-07 arm-then-take order). Cut and Take sit at the
/// row's leading edge — they are the panel's reason, the two buttons the
/// operator's hand goes to, and a button at a fixed position is one the
/// hand learns. After them, the armed transition: the kind as a **pop-up
/// menu** rather than the segmented control it started as — four segments
/// plus a heading took a row of their own, where a pop-up names the armed
/// transition in one word — with the wipe edge and shader pickers beside it
/// only while they apply: a wipe has an edge and a shader has a name, a cut
/// has neither, and a control for a choice that does not exist would be a
/// control the operator has to learn to ignore. Right after those, the
/// **duration** — a field and stepper in seconds, the panel's one rate
/// knob, applied to every timed take (a shot's own default transition keeps
/// its kind, edge, and shader and takes the panel's length — the AUTO rate
/// of a hardware panel, which the shot buttons do not override). It sits
/// beside the pickers rather than at the row's far end (Larry, 2026-09-13):
/// it is the armed transition's third setting, and a setting that is read
/// with its kind belongs next to it, not across a wide window from it. It
/// is disabled rather than hidden while Cut is armed, so the group keeps its
/// shape across kinds; a cut has no length to set.
///
/// The length is **time, not frames**: `Transition` carries seconds, and the
/// compositor converts to whole program ticks at take time (rounded, at
/// least one), so the same half second is 15 ticks at 30 fps and 30 at 60
/// — the operator's setting survives a frame-rate change.
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

    /// The panel: heading, then the one row — Cut, Take, the transition kind
    /// (and its detail picker), the duration, and the hint while nothing is
    /// staged.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transition", comment: "Section heading over the Cut, Take, and transition controls")
                .font(.headline)

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

                kindPicker

                if model.takeTransitionKind == .wipe {
                    edgePicker
                }

                if model.takeTransitionKind == .shader {
                    shaderPicker
                }

                durationControls

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

    /// The duration field's width: room for "10.00" and a grouping-free
    /// locale's decimal mark.
    private static let durationFieldWidth: CGFloat = 56

    /// The stepper's increment in seconds: a tenth, the resolution a rate is
    /// usually spoken in ("half a second", "a second and a half").
    private static let durationStep: TimeInterval = 0.1

    /// The take duration beside the pickers: a label, the committing
    /// field (``CommittingNumberField`` — commits once, on Return or when
    /// focus leaves, never per keystroke), a stepper, and the unit. Disabled
    /// while Cut is armed. The field reports `transitionDuration.field` and
    /// the stepper `transitionDuration.stepper`, each where its action
    /// executes.
    private var durationControls: some View {
        HStack(spacing: 4) {
            Text("Duration", comment: "Label before the transition duration field on the transition panel")
                .foregroundStyle(.secondary)
            CommittingNumberField(
                value: model.takeTransitionDuration,
                fractionDigits: 2,
                label: Text(
                    "Duration",
                    comment: "Label before the transition duration field on the transition panel")
            ) { typed in
                model.eventBus.tap(
                    "transitionDuration.field",
                    domain: .composition,
                    params: ["seconds": .double(typed)]
                )
                model.setTakeTransitionDuration(typed)
            }
            .frame(width: Self.durationFieldWidth)
            Stepper(
                value: durationBinding.reportingTap(
                    to: model.eventBus, "transitionDuration.stepper", domain: .composition,
                    params: { ["seconds": .double($0)] }),
                in: EngineModel.takeTransitionDurationRange,
                step: Self.durationStep
            ) {
                Text(
                    "Duration",
                    comment: "Label before the transition duration field on the transition panel")
            }
            .labelsHidden()
            Text("s", comment: "Unit after the transition duration field: seconds, abbreviated")
                .foregroundStyle(.secondary)
        }
        .disabled(model.takeTransitionKind == .cut)
        .help(
            Text(
                "How long a dissolve, wipe, or shader transition runs, in seconds. A cut is instant.",
                comment: "Tooltip on the transition duration field and stepper"
            )
        )
    }

    /// The duration as a binding for the stepper: reads the model's value and
    /// writes through ``EngineModel/setTakeTransitionDuration(_:)``, which
    /// clamps.
    private var durationBinding: Binding<TimeInterval> {
        Binding {
            model.takeTransitionDuration
        } set: { seconds in
            model.setTakeTransitionDuration(seconds)
        }
    }

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
