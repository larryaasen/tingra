//
//  SecureStorageTestSupport.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-08-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization

@testable import TingraHost

/// An in-memory ``SecureStorage`` double, so the seam's contract is exercised
/// without touching the real Keychain — no unlocked login keychain and no
/// prompt on a CI runner (``KeychainSecureStorage`` is validated by hand). It
/// implements the same documented semantics the app depends on: a store
/// overwrites, a read of a missing account is `nil`, and a remove is
/// idempotent.
///
/// It also injects faults. ``readFailure`` makes every read throw, which is
/// the only way to reach the unsigned-development-build path in
/// ``DestinationStore`` — a real process either has the entitlement or does
/// not, and a test cannot un-sign itself.
final class InMemorySecureStorage: SecureStorage {
    /// The stored secrets, keyed by account.
    private let secrets = Mutex<[String: String]>([:])

    /// The error every ``secret(forAccount:)`` throws, or nil to read
    /// normally — the stand-in for a Keychain that refuses this binary.
    private let readFailure: SecureStorageError?

    /// Creates a double.
    ///
    /// - Parameter readFailure: An error every read throws, or nil for a
    ///   store that reads normally.
    init(readFailure: SecureStorageError? = nil) {
        self.readFailure = readFailure
    }

    func setSecret(_ secret: String, forAccount account: String) throws {
        secrets.withLock { $0[account] = secret }
    }

    func secret(forAccount account: String) throws -> String? {
        if let readFailure { throw readFailure }
        return secrets.withLock { $0[account] }
    }

    func removeSecret(forAccount account: String) throws {
        secrets.withLock { $0[account] = nil }
    }
}
