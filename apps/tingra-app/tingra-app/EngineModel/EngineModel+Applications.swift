//
//  EngineModel+Applications.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraCapturePlugIns
import TingraComposition
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// Application inputs: the applications whose sound a project captures.
extension EngineModel {
    /// Where the application list and the application inputs come from.
    private var applicationProvider: ApplicationAudioProvider {
        ApplicationAudioProvider(eventBus: eventBus)
    }

    /// The applications that can be added now — those running with an audio
    /// process, by name — for the Add Application sheet. Listing asks for no
    /// permission; the first capture does.
    ///
    /// - Returns: The applications.
    /// - Throws: An `ApplicationListingError` when Core Audio will not list
    ///   its processes.
    func availableApplications() async throws -> [CaptureApplication] {
        try await applicationProvider.availableApplications()
    }

    /// Whether the project already holds an input for an application, so the
    /// picker can say so instead of adding a second capture of it.
    ///
    /// - Parameter application: An application the picker lists.
    /// - Returns: Whether a record with its bundle identifier exists.
    func isApplicationAdded(_ application: CaptureApplication) -> Bool {
        ApplicationChoice.isAdded(application, to: applications)
    }

    /// Adds an application to the project as an audio input and puts its
    /// channel strip on the mixer, muted with audio follows video off
    /// (``MixerStrip/added(_:hasPicture:)``) — an application input exists
    /// only to be heard, so adding it is adding its strip. Nothing is
    /// captured, and the application keeps playing to its speakers, until
    /// the operator unmutes the strip. An application the project already
    /// holds is left alone. The document autosaves when one was added.
    ///
    /// - Parameter application: The application to add, as the picker listed
    ///   it.
    func addApplication(_ application: CaptureApplication) async {
        guard !isApplicationAdded(application) else { return }
        let record = ApplicationChoice.record(for: application)
        guard await registerApplication(record) else { return }
        applications.append(record)
        eventBus.event(
            "application.added",
            domain: .capture,
            params: [
                "id": .string(record.id.rawValue),
                "name": .string(record.name),
                "application": .string(record.bundleIdentifier),
            ]
        )
        await readDeviceLists()
        addStrip(for: record.id)
        scheduleAutosave()
    }

    /// Removes an application from the project, its strip from the mixer,
    /// and its input from the registry; the audio pass stops it if it was
    /// capturing, which makes the application heard on its speakers again.
    /// The strip goes too because nothing could bring it back: adding the
    /// application again makes a new input.
    ///
    /// - Parameter id: The application input to remove.
    func removeApplication(_ id: InputID) async {
        guard let index = applications.firstIndex(where: { $0.id == id }) else { return }
        let record = applications.remove(at: index)
        await removeStrip(id)
        await registry.unregister(id)
        eventBus.event(
            "application.removed",
            domain: .capture,
            params: ["id": .string(id.rawValue), "name": .string(record.name)]
        )
        await readDeviceLists()
        await reconfigureAudio()
        scheduleAutosave()
    }

    /// Whether an input is one of the project's applications — what puts
    /// **Remove Application** on its sidebar row.
    ///
    /// - Parameter id: The input.
    /// - Returns: Whether the project holds it as an application.
    func isApplication(_ id: InputID) -> Bool {
        applications.contains { $0.id == id }
    }

    /// Registers the inputs for the loaded project's application list, at
    /// boot and when a project is opened.
    func registerProjectApplications() async {
        for record in applications {
            _ = await registerApplication(record)
        }
    }

    /// Makes and registers the input for one application record. Nothing is
    /// tapped until the strip is unmuted and the input starts.
    ///
    /// - Parameter record: The record to register.
    /// - Returns: Whether the input registered; a registry refusal is
    ///   reported as an `application.add` error.
    private func registerApplication(_ record: ProjectApplication) async -> Bool {
        do {
            try await registry.register(
                applicationProvider.makeInput(for: ApplicationChoice.application(of: record), id: record.id))
            return true
        } catch {
            eventBus.error(
                "application.add",
                domain: .capture,
                params: [
                    "id": .string(record.id.rawValue),
                    "name": .string(record.name),
                    "error": .string(String(describing: error)),
                ]
            )
            return false
        }
    }
}
