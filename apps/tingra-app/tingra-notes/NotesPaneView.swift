//
//  NotesPaneView.swift
//  TingraNotes
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraAppPlugInKit

/// The Notes pane: a text editor over the project-scoped notes, and a
/// Clear button. The app supplies the chrome around it (the header with
/// the title and symbol), so the pane is the editor alone.
struct NotesPaneView: View {
    /// The extension's connections to the app.
    @Environment(PlugInRuntime.self) private var runtime

    /// The notes.
    private let model = NotesModel.shared

    /// The pane.
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $model.text)
                .font(.system(size: model.fontSize))
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text("Notes save with the project.", comment: "Placeholder in the empty Notes editor")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                Button {
                    model.clear()
                } label: {
                    Text("Clear", comment: "Button emptying the notes")
                }
                .disabled(model.text.isEmpty)
            }
        }
        .padding(8)
        // The connection arrives after the view exists; each one reloads
        // once and becomes the one edits are written over.
        .task(id: runtime.acceptedCount) {
            guard let connection = runtime.connection else { return }
            await model.load(over: connection)
        }
        .onDisappear {
            Task { await model.flush() }
        }
    }
}
