//
//  EngineModel+Windows.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Foundation
import TingraCapturePlugIns
import TingraComposition
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// Window inputs: the windows a project captures.
extension EngineModel {
    /// Where the window list and the window inputs come from.
    private var windowProvider: WindowInputProvider {
        WindowInputProvider(eventBus: eventBus)
    }

    /// The windows that can be added now — those on screen, by application
    /// and then title — for the Add Window sheet. Reading the list is what
    /// asks for Screen Recording access the first time.
    ///
    /// - Returns: The windows.
    /// - Throws: A `WindowListingError` when Screen Recording access is
    ///   denied or the list cannot be read.
    func availableWindows() async throws -> [CaptureWindow] {
        try await windowProvider.availableWindows()
    }

    /// Whether the project already holds an input for a window, so the picker
    /// can say so instead of adding a second capture of it.
    ///
    /// - Parameter window: A window the picker lists.
    /// - Returns: Whether a record with its application and title exists.
    func isWindowAdded(_ window: CaptureWindow) -> Bool {
        WindowChoice.isAdded(window, to: windows)
    }

    /// Adds a window to the project as an input the sidebar lists and a
    /// layer can bind to. A window the project already holds is left alone.
    ///
    /// - Parameter window: The window to add, as the picker listed it.
    func addWindow(_ window: CaptureWindow) async {
        guard !isWindowAdded(window) else { return }
        let record = WindowChoice.record(for: window)
        guard await registerWindow(record, windowID: window.id) else { return }
        windows.append(record)
        windowSizes[record.id] = CGSize(width: window.width, height: window.height)
        eventBus.event(
            "window.added",
            domain: .capture,
            params: [
                "id": .string(record.id.rawValue),
                "name": .string(window.target.name),
                "application": .string(record.bundleIdentifier),
            ]
        )
        await readDeviceLists()
        scheduleAutosave()
    }

    /// Removes a window from the project and its input from the registry; the
    /// reconfigure pass stops a running capture. Never edits shots: a bound
    /// layer stays bound and dormant, the removed-device semantic.
    ///
    /// - Parameter id: The window input to remove.
    func removeWindow(_ id: InputID) async {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let record = windows.remove(at: index)
        windowSizes[id] = nil
        await registry.unregister(id)
        eventBus.event(
            "window.removed",
            domain: .capture,
            params: ["id": .string(id.rawValue), "name": .string(WindowChoice.target(of: record).name)]
        )
        await readDeviceLists()
        await reconfigure()
        scheduleAutosave()
    }

    /// Registers the inputs for the loaded project's window list, at boot
    /// and when a project is opened.
    func registerProjectWindows() async {
        for record in windows {
            _ = await registerWindow(record, windowID: nil)
        }
    }

    /// Makes and registers the input for one window record. Nothing is
    /// captured and no window is looked for until a shot references the
    /// input and it starts.
    ///
    /// - Parameters:
    ///   - record: The record to register.
    ///   - windowID: The window's identifier when the operator has just
    ///     picked it, or nil for a record loaded from a project.
    /// - Returns: Whether the input registered; a registry refusal is
    ///   reported as a `window.add` error.
    private func registerWindow(_ record: ProjectWindow, windowID: UInt32?) async -> Bool {
        let target = WindowChoice.target(of: record)
        do {
            try await registry.register(windowProvider.makeInput(for: target, id: record.id, windowID: windowID))
            return true
        } catch {
            eventBus.error(
                "window.add",
                domain: .capture,
                params: [
                    "id": .string(record.id.rawValue),
                    "name": .string(target.name),
                    "error": .string(String(describing: error)),
                ]
            )
            return false
        }
    }
}
