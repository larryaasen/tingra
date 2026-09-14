//
//  NotesSettingsView.swift
//  TingraNotes
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraAppPlugInKit

/// The Notes settings pane: the editor's font size, kept on this Mac as
/// app-scoped storage.
struct NotesSettingsView: View {
    /// The extension's connections to the app.
    @Environment(PlugInRuntime.self) private var runtime

    /// The notes.
    private let model = NotesModel.shared

    /// The pane.
    var body: some View {
        Form {
            Picker(
                selection: Binding(get: { model.fontSize }, set: { model.setFontSize($0) })
            ) {
                ForEach(NotesModel.fontSizes, id: \.self) { size in
                    Text(size.formatted(.number.precision(.fractionLength(0))))
                        .tag(size)
                }
            } label: {
                Text("Font Size", comment: "Label of the Notes settings pane's font size picker")
            }
            .pickerStyle(.menu)
        }
        .formStyle(.grouped)
        .task(id: runtime.acceptedCount) {
            guard let connection = runtime.connection else { return }
            await model.load(over: connection)
        }
    }
}
