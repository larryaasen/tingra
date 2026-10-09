//
//  WindowInputProvider.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraPlugInKit

/// Why the windows open right now could not be listed.
public enum WindowListingError: Error, Equatable {
    /// Screen Recording access has not been granted, and macOS lists no
    /// other application's windows without it.
    case screenRecordingDenied

    /// ScreenCaptureKit could not read the window list for another reason,
    /// described.
    case unavailable(String)
}

extension WindowListingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .screenRecordingDenied:
            return """
                The open windows cannot be listed without Screen Recording access. Grant it in \
                System Settings > Privacy & Security > Screen Recording, then try again.
                """
        case .unavailable(let reason):
            return "The open windows could not be listed: \(reason)."
        }
    }
}

/// Where window inputs come from: the list of windows that can be captured
/// now, and the input for the one the operator picks.
///
/// A window is *chosen*, not discovered — applications open and close
/// windows all day, and registering each as an input would bury the registry
/// and the bus in `device.connected` noise for things nobody asked to
/// capture. So ``ScreenCaptureKitCapturePlugIn`` registers displays at
/// activation and nothing for windows; a front end asks this provider for
/// the list, makes an input for the choice, and registers it on the
/// project's behalf — the arrangement media files have (ARCHITECTURE.md,
/// "Window capture"). ScreenCaptureKit stays behind the `Input` seam: this
/// type hands out ``CaptureWindow`` records and `any Input`, nothing of the
/// framework's.
public struct WindowInputProvider: Sendable {
    /// The host's event bus, handed to each input for its interruption and
    /// resume events.
    private let eventBus: EventBus?

    /// Reads every capturable window open now. Production asks
    /// ScreenCaptureKit; tests inject fixtures.
    private let listWindows: @Sendable () async throws -> [CaptureWindow]

    /// Creates the production provider.
    ///
    /// - Parameter eventBus: The host's event bus. Omit it where nothing
    ///   listens.
    public init(eventBus: EventBus? = nil) {
        self.init(eventBus: eventBus, listWindows: WindowInput.listWindows)
    }

    /// Creates a provider over an injected window list (the test seam).
    ///
    /// - Parameters:
    ///   - eventBus: The host's event bus.
    ///   - listWindows: Reads every capturable window open now.
    init(eventBus: EventBus?, listWindows: @escaping @Sendable () async throws -> [CaptureWindow]) {
        self.eventBus = eventBus
        self.listWindows = listWindows
    }

    /// The windows a picker offers: those on screen now, by application and
    /// then title. Reading the list is what prompts for Screen Recording
    /// access the first time.
    ///
    /// - Returns: The windows.
    /// - Throws: ``WindowListingError/screenRecordingDenied`` without Screen
    ///   Recording access, ``WindowListingError/unavailable(_:)`` when the
    ///   list cannot be read for another reason.
    public func availableWindows() async throws -> [CaptureWindow] {
        WindowMatching.pickerWindows(from: try await listWindows())
    }

    /// Creates the input that captures a window.
    ///
    /// The input is created, not started: it asks for nothing and looks for
    /// no window until ``Input/start()``, and a window that is not open then
    /// is waited for rather than thrown.
    ///
    /// - Parameters:
    ///   - target: The window to capture, as the project remembers it.
    ///   - id: The stable identifier the input must report as ``Input/id``
    ///     — the project's identity for the window, since a window has none
    ///     of its own.
    ///   - windowID: The ``CaptureWindow/id`` of the window the operator has
    ///     just picked, so the first capture is of exactly that window; nil
    ///     (the default) for a window loaded from a project.
    /// - Returns: A fresh input; the caller owns its lifecycle.
    public func makeInput(for target: WindowTarget, id: InputID, windowID: UInt32? = nil) -> any Input {
        WindowInput(target: target, id: id, windowID: windowID, eventBus: eventBus)
    }
}
