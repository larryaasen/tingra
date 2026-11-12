//
//  StreamingPreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost

/// How the operator's stream is compressed, where they have a choice:
/// **machine-local preferences**, not the project document
/// (ARCHITECTURE.md, "Compression settings in the app").
///
/// ``RecordingPreferences``' reasoning applies: what a destination will
/// accept is a fact about the operator's services and uplink, not about the
/// show, so a project carried to another Mac should not carry it. Today the
/// one choice is the audio bit rate; every leg of the stream is compressed
/// with it, and per-destination compression is a later iteration.
struct StreamingPreferences {
    /// The defaults database the values live in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The audio bit rate key.
    private static let audioBitRateKey = "streaming.audioBitsPerSecond"

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The audio bit rate the stream is compressed at, in bits per second:
    /// always one of the offered rates (``CompressionChoices``). Nothing
    /// stored reads as the default; a stored rate off the menu reads as the
    /// nearest one on it.
    var audioBitsPerSecond: Int {
        get {
            guard defaults.object(forKey: Self.audioBitRateKey) != nil else {
                return CompressionChoices.defaultAudioBitsPerSecond
            }
            return CompressionChoices.audioBitsPerSecond(nearest: defaults.integer(forKey: Self.audioBitRateKey))
        }
        nonmutating set { defaults.set(newValue, forKey: Self.audioBitRateKey) }
    }
}
