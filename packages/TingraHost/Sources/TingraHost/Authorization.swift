//
//  Authorization.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// A system permission Tingra's capture depends on — one of the TCC
/// (Transparency, Consent, and Control) grants macOS keys to the app's
/// signature.
///
/// The host owns authorization (ARCHITECTURE.md, "The host"): the capture
/// plug-ins *request* a permission the moment an input starts, but only the
/// host answers the standing question a front end needs — what has been
/// granted, what refused, and what never asked — without starting anything.
/// The raw values are a scripting contract, stable across releases.
public enum AuthorizationPermission: String, CaseIterable, Sendable, Codable {
    /// Camera access: cameras as inputs, including Continuity Cameras.
    case camera

    /// Microphone access: microphones as inputs.
    case microphone

    /// Screen Recording: displays as inputs, through ScreenCaptureKit.
    case screenRecording
}

/// Where one permission stands.
///
/// Camera and microphone report all four states, straight from AVFoundation.
/// Screen Recording reports only ``granted`` and ``denied``: CoreGraphics'
/// preflight answers a yes-or-no question and cannot tell a permission the
/// operator refused from one that was never asked — the first capture
/// attempt is what prompts (see `DisplayInput`) — so a Screen Recording
/// ``denied`` means "not currently granted", and the fix is the same either
/// way: System Settings.
public enum AuthorizationStatus: String, Sendable, Codable, Equatable {
    /// The operator has not been asked yet; a request will prompt.
    case notDetermined

    /// Access is granted.
    case granted

    /// The operator refused, or (Screen Recording) has not granted.
    case denied

    /// A policy — parental controls, a device profile — forbids the access,
    /// and no prompt can change it.
    case restricted
}

/// The authorization seam: what the front ends ask about permissions, so
/// the settings pane and its tests can run against a scripted answer rather
/// than the operator's real TCC database.
///
/// Both requirements are synchronous or `async` reads of system state and
/// never touch a device — asking where a permission stands is not capture,
/// so it lights no indicator and prompts nothing. Only ``request(_:)`` can
/// prompt, and only for a permission still ``AuthorizationStatus/notDetermined``.
public protocol AuthorizationChecking: Sendable {
    /// Where the permission currently stands. Never prompts.
    ///
    /// - Parameter permission: The permission to look up.
    /// - Returns: Its status.
    func status(of permission: AuthorizationPermission) -> AuthorizationStatus

    /// Asks the system for the permission, prompting the operator when the
    /// permission has not been decided, and returns where it stands
    /// afterwards.
    ///
    /// A permission already decided is not prompted for again — macOS shows
    /// the dialog once — so for a ``AuthorizationStatus/denied`` permission
    /// this simply returns `denied`; the operator changes that in System
    /// Settings.
    ///
    /// - Parameter permission: The permission to request.
    /// - Returns: The status after the request.
    func request(_ permission: AuthorizationPermission) async -> AuthorizationStatus

    /// Forgets the system's recorded decision for a permission — granted or
    /// denied — so it reads ``AuthorizationStatus/notDetermined`` again and
    /// macOS asks the next time the permission is needed.
    ///
    /// The one way an app can move a TCC decision on its own: it cannot grant
    /// itself anything, but it can ask the system to forget. Resetting a
    /// permission that was never decided is not an error.
    ///
    /// - Parameter permission: The permission to reset.
    /// - Throws: ``AuthorizationError`` when the system refuses or the
    ///   process has no bundle identifier to reset for.
    func reset(_ permission: AuthorizationPermission) async throws
}

/// A failure from ``AuthorizationChecking/reset(_:)``. Recoverable and
/// developer-facing — the reset runs a system tool, and the tool's own words
/// are the diagnosis.
public enum AuthorizationError: Error, Equatable, CustomStringConvertible {
    /// The running process has no bundle identifier, so there is no TCC
    /// client to reset — a bare executable such as `tingra-cli`.
    case noBundleIdentifier

    /// `tccutil` exited with a status other than success; carries the status
    /// and what the tool printed.
    case resetRefused(permission: AuthorizationPermission, status: Int32, output: String)

    /// A developer-facing description.
    public var description: String {
        switch self {
        case .noBundleIdentifier:
            return "The process has no bundle identifier, so there is no permission record to reset."
        case .resetRefused(let permission, let status, let output):
            let detail = output.isEmpty ? "no output" : output
            return "tccutil could not reset the \(permission.rawValue) permission (exit status \(status): \(detail))."
        }
    }
}

/// The production ``AuthorizationChecking``: AVFoundation for the camera and
/// microphone, CoreGraphics for Screen Recording.
///
/// CoreGraphics rather than ScreenCaptureKit for the Screen Recording read,
/// deliberately: `CGPreflightScreenCaptureAccess` answers without touching
/// the capture system, where `SCShareableContent.current` — the probe the
/// display input uses when it *starts* — is the very call that makes macOS
/// show the Screen Recording prompt, and a settings pane that prompted just
/// by being opened would be wrong.
extension AuthorizationPermission {
    /// The service name `tccutil` knows this permission by — the TCC
    /// service identifiers, which are not the framework names.
    public var tccServiceName: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screenRecording: "ScreenCapture"
        }
    }
}

public struct SystemAuthorization: AuthorizationChecking {
    /// Creates the production checker.
    public init() {}

    public func status(of permission: AuthorizationPermission) -> AuthorizationStatus {
        switch permission {
        case .camera: Self.status(of: AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: Self.status(of: AVCaptureDevice.authorizationStatus(for: .audio))
        case .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    public func request(_ permission: AuthorizationPermission) async -> AuthorizationStatus {
        switch permission {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording:
            // Prompts when undecided; for a refused permission it opens
            // nothing and returns false, which the status read below
            // reports as it is. Its return value is discarded for the same
            // reason as the two above: one status read serves every case.
            _ = CGRequestScreenCaptureAccess()
        }
        return status(of: permission)
    }

    /// Maps AVFoundation's status to the seam's.
    ///
    /// - Parameter status: AVFoundation's answer for a media type.
    /// - Returns: The seam's equivalent; an unknown future case reads as
    ///   `denied`, the safe answer for a permission the app cannot vouch for.
    /// Resets the permission through `tccutil`, the system's own tool for
    /// forgetting a TCC decision, for this process's bundle identifier.
    ///
    /// `tccutil reset <Service> <bundle id>` acts on the user's own TCC
    /// database and needs no privilege for the user-level services capture
    /// uses (Camera, Microphone, ScreenCapture). There is no framework API
    /// for this — resetting is deliberately out of an app's reach except by
    /// asking the system — so the tool is spawned and its exit status read.
    /// A running input keeps the access it already opened; the decision is
    /// asked again the next time the permission is needed.
    public func reset(_ permission: AuthorizationPermission) async throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw AuthorizationError.noBundleIdentifier
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tccutil")
        process.arguments = ["reset", permission.tccServiceName, bundleIdentifier]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else {
            throw AuthorizationError.resetRefused(permission: permission, status: status, output: printed)
        }
    }

    private static func status(of status: AVAuthorizationStatus) -> AuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }
}
