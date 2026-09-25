//
//  CodeSignatureChecking.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Security

/// What a code signature check concluded about a plug-in bundle.
public enum CodeSignatureVerdict: Sendable, Equatable {
    /// The bundle carries a valid signature — ad-hoc counts — and, when it
    /// arrived through a download, is notarized.
    case valid

    /// The bundle has no signature, or one that does not validate (its
    /// contents changed after signing, say).
    ///
    /// - Parameter detail: The Security framework's own words for why.
    case unsigned(detail: String)

    /// The bundle carries the quarantine attribute, so it arrived through a
    /// download, and it is not notarized.
    case notNotarized
}

/// The seam under ``PlugInBundleLoader`` that decides whether a bundle's
/// signature admits it, checked before any of its code is loaded
/// (PLUGINS.md, Decision 26).
///
/// The production conformance is ``StaticCodeSignatureChecker``; tests
/// substitute a scripted verdict.
public protocol CodeSignatureChecking: Sendable {
    /// Checks the bundle's signature, and its notarization when quarantined.
    ///
    /// - Parameter url: The bundle's directory.
    func verdict(forBundleAt url: URL) -> CodeSignatureVerdict
}

/// The production ``CodeSignatureChecking``: the Security framework's static
/// code checks, the rule Gatekeeper applies to a plug-in a notarized app
/// loads, enforced by Tingra with a message Tingra writes.
///
/// Any valid signature passes, including ad-hoc, so a developer's own build
/// loads; a bundle carrying `com.apple.quarantine` must also satisfy the
/// `notarized` code requirement.
public struct StaticCodeSignatureChecker: CodeSignatureChecking {
    /// Creates the checker. Stateless.
    public init() {}

    /// Validates the whole bundle, nested code included, strictly; then,
    /// when it is quarantined, validates it again against `notarized`.
    public func verdict(forBundleAt url: URL) -> CodeSignatureVerdict {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else {
            return .unsigned(detail: Self.message(for: created))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate)
        let validity = SecStaticCodeCheckValidity(staticCode, flags, nil)
        guard validity == errSecSuccess else {
            return .unsigned(detail: Self.message(for: validity))
        }
        guard Self.isQuarantined(url) else { return .valid }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else {
            return .notNotarized
        }
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess ? .valid : .notNotarized
    }

    /// Whether the bundle carries the quarantine attribute a download sets.
    static func isQuarantined(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey])
        return values?.quarantineProperties != nil
    }

    /// The Security framework's description of a status code, with the code
    /// itself so it can be looked up.
    static func message(for status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown signature error"
        return "\(text) (\(status))"
    }
}
