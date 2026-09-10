//
//  ProgramFormatSheet.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// The **Custom Size…** sheet: width, height, and frame rate typed into
/// ``CommittingNumberField``s, prefilled with the program's current format,
/// with the first rule the typed values break shown beneath them
/// (``ProgramFormatProblem``) and Apply held back until none is. Any even
/// size is accepted — 8K and odd aspect ratios included — because "any
/// size" is the sketch's own words; the named sizes are the menu's.
///
/// Opened from the Program menu (``ProgramCommands``) through window state
/// the app scene owns, and presented by ``ContentView``, since a menu
/// command cannot present a sheet itself.
struct ProgramFormatSheet: View {
    /// The engine model the format is applied through.
    let model: EngineModel

    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss

    /// The typed width.
    @State private var width: Int

    /// The typed height.
    @State private var height: Int

    /// The typed frame rate.
    @State private var frameRate: Int

    /// Creates the sheet prefilled with the program's current format.
    ///
    /// - Parameter model: The engine model.
    init(model: EngineModel) {
        self.model = model
        _width = State(initialValue: model.format.width)
        _height = State(initialValue: model.format.height)
        _frameRate = State(initialValue: model.format.frameRate)
    }

    /// The first rule the typed values break, or `nil`.
    private var problem: ProgramFormatProblem? {
        ProgramFormatChoice.problem(width: width, height: height, frameRate: frameRate)
    }

    /// The sheet: a caption, the three fields, the problem line, and the
    /// buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Size", comment: "Title of the sheet for a typed program size and frame rate")
                .font(.headline)
            Text(
                "The size and frame rate the program is composited and delivered at. Changes apply at once; they are unavailable while streaming or recording.",
                comment: "Caption of the custom program size sheet"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Form {
                CommittingNumberField(
                    value: Double(width),
                    fractionDigits: 0,
                    label: Text("Width", comment: "Layer frame slider label")
                ) { typed in
                    width = Int(typed.rounded())
                }
                CommittingNumberField(
                    value: Double(height),
                    fractionDigits: 0,
                    label: Text("Height", comment: "Layer frame slider label")
                ) { typed in
                    height = Int(typed.rounded())
                }
                CommittingNumberField(
                    value: Double(frameRate),
                    fractionDigits: 0,
                    label: Text("Frame Rate", comment: "Program menu: the submenu of frame rates")
                ) { typed in
                    frameRate = Int(typed.rounded())
                }
            }
            .formStyle(.columns)

            Text(problem?.message ?? " ")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button {
                    model.eventBus.tap("programFormatCustomCancel.button", domain: .composition)
                    dismiss()
                } label: {
                    Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    let format = ProgramFormat(width: width, height: height, frameRate: frameRate)
                    model.eventBus.tap(
                        "programFormatCustom.button",
                        domain: .composition,
                        params: [
                            "resolution": .string("\(format.width)x\(format.height)"),
                            "fps": .int(format.frameRate),
                        ]
                    )
                    model.setProgramFormat(format)
                    dismiss()
                } label: {
                    Text("Apply", comment: "Custom program size sheet: applies the typed format")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
