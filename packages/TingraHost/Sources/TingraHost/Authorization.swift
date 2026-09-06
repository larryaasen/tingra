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
