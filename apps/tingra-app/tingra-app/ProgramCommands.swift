//
//  ProgramCommands.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// The **Program** menu: a **Size** submenu of the named program sizes
/// (``ProgramSize``) with a **Custom Size…** item that opens the sheet
/// (``ProgramFormatSheet``), and a **Frame Rate** submenu of the common
/// rates (``ProgramFormatChoice/frameRates``). Each item is a checkmark
/// toggle, the way a radio group reads in a Mac menu; a custom size checks
/// the Custom Size… item and a custom rate checks nothing.
///
/// A menu rather than a settings pane because the format is **document
/// state** — it saves with the project, like Keynote's slide size — and the
/// app's settings panes hold what is set once per operator. It leads the
/// app's own menus (before Shots and Layer) because the program is what a
/// shot is composed onto and a layer sits in: the signal path's order, the
/// sidebar's rule.
///
/// **Disabled while streaming or recording.** The sinks' compression
/// sessions are open at a size; the model refuses a change then too
/// (``EngineModel/setProgramFormat(_:)``), so the disabled items are the
/// courtesy and the refusal is the rule (ARCHITECTURE.md, "The program
/// format as a project setting").
struct ProgramCommands: Commands {
    /// The engine model the items change the format through, and report
    /// their `tap` to.
    let model: EngineModel

    /// Whether the Custom Size… sheet is shown — window state owned by the
    /// app scene, like the inspector's visibility.
    @Binding var isCustomSizePresented: Bool

    /// The menu.
    var body: some Commands {
        CommandMenu(Text("Program", comment: "Title of the Program menu: the program's size and frame rate")) {
            Menu {
                ForEach(ProgramSize.allCases) { size in
                    Toggle(isOn: sizeBinding(size)) {
                        Text(size.title)
                    }
                }

                Divider()

                Toggle(isOn: customSizeBinding) {
                    Text("Custom Size…", comment: "Program menu item opening the sheet for a typed program size")
                }
            } label: {
                Text("Size", comment: "Program menu: the submenu of named program sizes")
            }
            .disabled(isOnAir)

            Menu {
                ForEach(ProgramFormatChoice.frameRates, id: \.self) { rate in
                    Toggle(isOn: rateBinding(rate)) {
                        Text("\(rate) fps", comment: "Program menu item: a frame rate in frames per second")
                    }
                }
            } label: {
                Text("Frame Rate", comment: "Program menu: the submenu of frame rates")
            }
            .disabled(isOnAir)
        }
    }

    /// Whether a change is refused right now — the items are disabled
    /// rather than left to be refused.
    private var isOnAir: Bool {
        ProgramFormatChoice.refusal(isStreaming: model.isStreaming, isRecording: model.isRecording) != nil
    }

    /// A named size's checkmark: on when the program has its dimensions;
    /// setting it picks the size at the current frame rate. Clicking the
    /// checked item asks to turn it off, which a radio group ignores.
    ///
    /// - Parameter size: The item's size.
    private func sizeBinding(_ size: ProgramSize) -> Binding<Bool> {
        Binding {
            ProgramSize.named(matching: model.format) == size
        } set: { isOn in
            guard isOn else { return }
            let format = size.format(at: model.format.frameRate)
            model.eventBus.tap(
                "programSize.menuItem",
                domain: .composition,
                params: ["size": .string(size.rawValue), "resolution": .string("\(format.width)x\(format.height)")]
            )
            model.setProgramFormat(format)
        }
    }

    /// The Custom Size… item's checkmark: on when no named size matches;
    /// setting it opens the sheet rather than changing anything.
    private var customSizeBinding: Binding<Bool> {
        Binding {
            ProgramSize.named(matching: model.format) == nil
        } set: { _ in
            model.eventBus.tap("programFormatCustom.menuItem", domain: .composition)
            isCustomSizePresented = true
        }
    }

    /// A frame rate's checkmark: on when the program runs at it; setting it
    /// keeps the size and changes the rate.
    ///
    /// - Parameter rate: The item's frame rate.
    private func rateBinding(_ rate: Int) -> Binding<Bool> {
        Binding {
            model.format.frameRate == rate
        } set: { isOn in
            guard isOn else { return }
            model.eventBus.tap("programFrameRate.menuItem", domain: .composition, params: ["fps": .int(rate)])
            model.setProgramFormat(
                ProgramFormat(width: model.format.width, height: model.format.height, frameRate: rate))
        }
    }
}
