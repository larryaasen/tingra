//
//  ApplicationAudioProvider.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraApplicationAudio
import TingraEventBus
import TingraPlugInKit

/// A running application that can be added as an audio input — what the
/// Add Application picker lists, free of any Core Audio type.
public struct CaptureApplication: Sendable, Equatable, Identifiable {
    /// The application's bundle identifier — its identity across launches.
    public let bundleIdentifier: String

    /// The application's user-facing name.
    public let name: String

    /// The bundle identifier.
    public var id: String { bundleIdentifier }

    /// Creates a record.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The bundle identifier.
    ///   - name: The user-facing name.
    public init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

/// Why the running applications could not be listed.
public enum ApplicationListingError: Error, Equatable {
    /// Core Audio would not list its processes; carries why.
    case unavailable(String)
}

extension ApplicationListingError: CustomStringConvertible {
    /// A developer-facing description.
    public var description: String {
        switch self {
        case .unavailable(let reason):
            return "The running applications could not be listed: \(reason)"
        }
    }
}

/// Where application inputs come from: the running applications that have
/// audio now, and the input for the one the operator picks.
///
/// An application is *chosen*, not discovered — the window arrangement
/// (ARCHITECTURE.md, "Application audio", A1): no plug-in registers
/// applications at activation; a front end asks this provider for the list,
/// makes an input for the choice, and registers it on the project's behalf.
/// Core Audio stays behind the `Input` seam: this type hands out
/// ``CaptureApplication`` records and `any Input`, nothing of the library's.
public struct ApplicationAudioProvider: Sendable {
    /// The host's event bus, handed to each input.
    private let eventBus: EventBus?

    /// Reads the running applications with audio. Production asks Core
    /// Audio; tests inject fixtures.
    private let listApplications: @Sendable () throws -> [CaptureApplication]

    /// Creates the production provider.
    ///
    /// - Parameter eventBus: The host's event bus. Omit it where nothing
    ///   listens.
    public init(eventBus: EventBus? = nil) {
        self.init(eventBus: eventBus, listApplications: Self.liveApplications)
    }

    /// Creates a provider over an injected list (the test seam).
    ///
    /// - Parameters:
    ///   - eventBus: The host's event bus.
    ///   - listApplications: Reads the running applications with audio.
    init(eventBus: EventBus?, listApplications: @escaping @Sendable () throws -> [CaptureApplication]) {
        self.eventBus = eventBus
        self.listApplications = listApplications
    }

    /// The applications a picker offers: those running with an audio
    /// process now, by name, never this app itself. Listing prompts for
    /// nothing; the first capture is what asks for the permission.
    ///
    /// - Returns: The applications.
    /// - Throws: ``ApplicationListingError/unavailable(_:)`` when Core Audio
    ///   will not list its processes.
    public func availableApplications() async throws -> [CaptureApplication] {
        try listApplications()
    }

    /// Creates the input that captures an application's sound.
    ///
    /// The input is created, not started: nothing is tapped until
    /// ``Input/start()``, and an application that is not running then is
    /// waited for rather than thrown.
    ///
    /// - Parameters:
    ///   - application: The application to capture.
    ///   - id: The stable identifier the input must report — the project's
    ///     identity for the application.
    /// - Returns: A fresh input; the caller owns its lifecycle.
    public func makeInput(for application: CaptureApplication, id: InputID) -> any Input {
        ApplicationAudioInput(application: application, id: id, eventBus: eventBus)
    }

    /// The production list: Core Audio's processes grouped into their
    /// applications.
    private static let liveApplications: @Sendable () throws -> [CaptureApplication] = {
        do {
            return try AudioApplication.running().map {
                CaptureApplication(bundleIdentifier: $0.bundleIdentifier, name: $0.name)
            }
        } catch {
            throw ApplicationListingError.unavailable(String(describing: error))
        }
    }
}
