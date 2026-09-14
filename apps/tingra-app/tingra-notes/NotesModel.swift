//
//  NotesModel.swift
//  TingraNotes
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import TingraAppPlugInKit
import TingraPlugInKit

/// The notes and the editor's font size, shared by the pane and the
/// settings scene (one process serves both): the text is project-scoped
/// storage, so it saves with the project and travels with it; the font
/// size is app-scoped, this Mac's preference.
///
/// Edits reach the app debounced — one `tingra/storage.set` and one
/// `notes.edited` event per pause in typing, never one per keystroke.
@MainActor
@Observable
final class NotesModel {
    /// The one model of the process.
    static let shared = NotesModel()

    /// The key the text is stored under in the project-scoped value.
    static let textKey = "text"

    /// The key the font size is stored under in the app-scoped value.
    static let fontSizeKey = "fontSize"

    /// The font size before the operator chose one.
    static let defaultFontSize = 13.0

    /// The font sizes the settings pane offers.
    static let fontSizes: [Double] = [11, 12, 13, 14, 16, 18, 20, 24]

    /// The notes text.
    var text = "" {
        didSet { if text != oldValue, isLoaded { textEdited() } }
    }

    /// The editor's font size.
    private(set) var fontSize = NotesModel.defaultFontSize

    /// Whether the stored values have been read, so an edit is the
    /// operator's and not the load.
    private(set) var isLoaded = false

    /// The connection edits are written over.
    private var connection: PlugInConnection?

    /// Coalesces edits into one write per pause.
    private var writer: DebouncedWriter?

    /// Creates the model, empty until ``load(over:)``.
    private init() {}

    /// Reads the stored text and font size over `connection` and keeps the
    /// connection for writes. Called whenever a scene's connection arrives;
    /// a later connection replaces the earlier for writes.
    ///
    /// - Parameter connection: The connection to the app.
    func load(over connection: PlugInConnection) async {
        self.connection = connection
        writer = DebouncedWriter(delay: .milliseconds(600)) { [weak self] value in
            await self?.write(value)
        }
        guard !isLoaded else { return }
        let project = try? await connection.projectData()
        let application = try? await connection.applicationData()
        text = project?[Self.textKey]?.stringValue ?? ""
        if let size = application?[Self.fontSizeKey]?.doubleValue, Self.fontSizes.contains(size) {
            fontSize = size
        }
        isLoaded = true
    }

    /// Clears the notes: the stored value goes, and `notes.cleared` says so.
    func clear() {
        text = ""
        Task { [connection] in
            await writer?.flush()
            try? await connection?.setProjectData(nil)
            await connection?.event("notes.cleared")
        }
    }

    /// Chooses the font size, persisting it on this Mac.
    ///
    /// - Parameter size: The size, one of ``fontSizes``.
    func setFontSize(_ size: Double) {
        guard Self.fontSizes.contains(size), size != fontSize else { return }
        fontSize = size
        Task { [connection] in
            try? await connection?.setApplicationData(.object([Self.fontSizeKey: .double(size)]))
            await connection?.event("notes.fontSize", params: ["size": .double(size)])
        }
    }

    /// Writes any edit waiting in the debounce now (the pane is going away).
    func flush() async {
        await writer?.flush()
    }

    /// Schedules the edited text for writing.
    private func textEdited() {
        let value: JSONValue = text.isEmpty ? .null : .object([Self.textKey: .string(text)])
        Task { await writer?.schedule(value) }
    }

    /// Writes one debounced value and reports the edit.
    private func write(_ value: JSONValue) async {
        guard let connection else { return }
        let characters = value[Self.textKey]?.stringValue?.count ?? 0
        try? await connection.setProjectData(value == .null ? nil : value)
        await connection.event("notes.edited", params: ["characters": .int(characters)])
    }
}
