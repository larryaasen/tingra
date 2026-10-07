//
//  KeepAwakeSwitch.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraHost

/// Holds the Mac awake exactly while a session is running **and** the
/// operator's Keep Mac Awake setting is on (CLOCK.md, "System sleep and App
/// Nap").
///
/// The CLI and the daemon hand their session a `KeepAwake` and let the run
/// own the hold. The app cannot: its setting is live, and a hold taken
/// inside `StreamSession.run()` is out of the model's reach until the run
/// ends. So here the app owns one hold of its own, for both of its sessions,
/// and re-decides it whenever either fact changes — a stream or a recording
/// starting or ending, or the checkbox being worked mid-session.
///
/// One hold rather than one per session: the Mac is either held or it is
/// not, and the last session to end is what lets it go.
final class KeepAwakeSwitch {
    /// What the hold is taken through (the system-backed one in the app; a
    /// counting double in tests).
    private let keepAwake: any KeepAwake

    /// Where the hold and its release are traced.
    private let eventBus: EventBus

    /// The hold while one is out, or nil.
    private var hold: (any KeepAwakeHold)?

    /// Whether the operator wants a session to hold the Mac awake.
    var isEnabled: Bool {
        didSet { update() }
    }

    /// Whether a stream or a recording is running.
    var isSessionRunning = false {
        didSet { update() }
    }

    /// Whether the Mac is being held awake right now.
    var isHolding: Bool { hold != nil }

    /// The reason the hold carries, as `pmset -g assertions` shows it — the
    /// session's own, so the app and the CLI read alike there.
    static let reason = StreamSession.keepAwakeReason

    /// Creates a switch with no session running.
    ///
    /// - Parameters:
    ///   - keepAwake: What the hold is taken through.
    ///   - eventBus: Where the hold and its release are traced.
    ///   - isEnabled: The operator's setting at launch.
    init(keepAwake: any KeepAwake, eventBus: EventBus, isEnabled: Bool) {
        self.keepAwake = keepAwake
        self.eventBus = eventBus
        self.isEnabled = isEnabled
    }

    /// Takes or releases the hold so it matches the two facts, tracing each
    /// change the way a session traces its own (`keepAwake.held`,
    /// `keepAwake.released`). Does nothing when the hold already matches.
    private func update() {
        let wanted = isEnabled && isSessionRunning
        if wanted, hold == nil {
            hold = keepAwake.hold(reason: Self.reason)
            eventBus.trace("keepAwake.held", domain: .platform)
        } else if !wanted, let held = hold {
            held.release()
            hold = nil
            eventBus.trace("keepAwake.released", domain: .platform)
        }
    }
}
