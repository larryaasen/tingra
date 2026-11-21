//
//  InputClaims.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-21.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// Which of the engine's two passes needs each input running — the one rule
/// that decides when an input starts and stops: **an input runs while a layer
/// or an unmuted strip needs it.**
///
/// The video pass (an input some shot shows) and the audio pass (an input an
/// unmuted strip hears) start and stop the very same `Input` object, and a
/// video file with sound is needed by both at once. Each pass used to keep its
/// own running set and call `stop()` on its own say-so, so muting a movie's
/// strip stopped the input a layer was still showing, and the picture froze
/// (found 2026-11-09). Now each pass **claims** an input before starting it
/// and **releases** it instead of stopping it, and only the first claim starts
/// the input and only the last release stops it.
///
/// Claims change synchronously, before the pass awaits the start or the stop,
/// so two passes interleaving on the main actor can never both start one
/// input, or one stop it while the other is starting it.
nonisolated struct InputClaims: Equatable {
    /// One of the two passes that need inputs running.
    enum Claimant: Hashable, CaseIterable {
        /// The video pass: a shot shows the input.
        case picture

        /// The audio pass: an unmuted strip hears the input.
        case sound
    }

    /// The claimants holding each input, never an empty set.
    private var claims: [InputID: Set<Claimant>] = [:]

    /// Claims an input for one pass.
    ///
    /// - Parameters:
    ///   - id: The input.
    ///   - claimant: The pass claiming it.
    /// - Returns: Whether this is the input's first claim, so the caller must
    ///   start it; false when another pass already holds it running (or
    ///   starting), or this pass already held it.
    mutating func claim(_ id: InputID, by claimant: Claimant) -> Bool {
        let wasClaimed = claims[id] != nil
        claims[id, default: []].insert(claimant)
        return !wasClaimed
    }

    /// Releases one pass's claim on an input.
    ///
    /// - Parameters:
    ///   - id: The input.
    ///   - claimant: The pass letting go.
    /// - Returns: Whether that was the input's last claim, so the caller must
    ///   stop it; false while the other pass still needs it, or when this
    ///   pass held no claim.
    mutating func release(_ id: InputID, by claimant: Claimant) -> Bool {
        guard var holders = claims[id], holders.remove(claimant) != nil else { return false }
        claims[id] = holders.isEmpty ? nil : holders
        return holders.isEmpty
    }

    /// Drops every claim on an input — one whose capture died on its own, so
    /// it has already stopped and the next claim must start it afresh.
    ///
    /// - Parameter id: The input.
    mutating func forget(_ id: InputID) {
        claims[id] = nil
    }

    /// Whether a pass holds a claim on an input.
    ///
    /// - Parameters:
    ///   - id: The input.
    ///   - claimant: The pass.
    /// - Returns: Whether it holds one.
    func isClaimed(_ id: InputID, by claimant: Claimant) -> Bool {
        claims[id]?.contains(claimant) ?? false
    }
}
