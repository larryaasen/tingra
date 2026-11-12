//
//  SharedSetting.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization

/// A value shared between a generator and every live renderer of its
/// streams: written by the generator's `setParameters` from whatever
/// isolation the host calls it on, read once per tick on each synthesis
/// task. A class around the lock because a `Mutex` cannot be copied into
/// the render closures, only referenced — the shape the tone generator's
/// tuning already has, made generic for the time generators' settings.
final class SharedSetting<Value: Sendable>: Sendable {
    /// The lock guarding the value.
    private let storage: Mutex<Value>

    /// Creates the shared setting with its first value.
    init(_ value: Value) {
        storage = Mutex(value)
    }

    /// The value as last set.
    var current: Value { storage.withLock { $0 } }

    /// Changes the value in place, under the lock, so a read never sees a
    /// half-applied payload.
    ///
    /// - Parameter change: Edits the value.
    func update(_ change: (inout Value) -> Void) {
        storage.withLock { change(&$0) }
    }
}
