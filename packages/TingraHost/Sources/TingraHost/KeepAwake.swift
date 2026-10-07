//
//  KeepAwake.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization

/// The seam a ``StreamSession`` holds the Mac and the process awake through
/// for as long as it runs (CLOCK.md, "System sleep and App Nap").
///
/// A system sleep stops the master clock and the scheduler together, so a
/// session running when the Mac idles to sleep produces nothing for the
/// length of the sleep. A session is exactly the stretch of time that must
/// not happen in, which is why the hold belongs to the session rather than
/// to whoever started it: `tingra-cli stream`, the `serve` daemon, and the
/// app all get it by handing the session one of these.
///
/// A protocol so a test counts holds instead of taking a real power
/// assertion, and so an embedder that wants no hold passes none.
public protocol KeepAwake: Sendable {
    /// Starts holding the Mac and the process awake.
    ///
    /// - Parameter reason: Why, in words an operator reading
    ///   `pmset -g assertions` would recognize.
    /// - Returns: The hold; the Mac may sleep again once it is released.
    func hold(reason: String) -> any KeepAwakeHold
}

/// One hold taken through ``KeepAwake``, released exactly once by whoever
/// took it.
public protocol KeepAwakeHold: Sendable {
    /// Ends the hold. Safe to call more than once; only the first call does
    /// anything.
    func release()
}

/// The real ``KeepAwake``: an activity declared to the system through
/// `ProcessInfo`, the Foundation front of the power assertions `pmset -g
/// assertions` lists.
///
/// One activity covers the three things a live session needs:
/// - **The Mac stays awake** (`.userInitiated` carries
///   `.idleSystemSleepDisabled`), so an idle timer cannot pause the master
///   clock under the session.
/// - **The displays stay awake** (`.idleDisplaySleepDisabled`).
///   ScreenCaptureKit stops a display capture whenever the displays sleep,
///   and a command-line process is never told they woke (ARCHITECTURE.md,
///   "Display capture across display sleep"), so for a session a sleeping
///   display is a lost input, not a power saving.
/// - **The process is not napped** (`.userInitiated` opts out of App Nap,
///   and `.latencyCritical` asks for the timer precision audio and video
///   work needs), so the program tick keeps its grid while the app's
///   windows are covered.
///
/// It prevents **idle** sleep only. A closed lid, the Sleep menu item, and a
/// drained battery still sleep the Mac; nothing an app may do stops those.
public struct ProcessActivityKeepAwake: KeepAwake {
    /// What the activity asks of the system; see the type's own discussion.
    static let options: ProcessInfo.ActivityOptions = [
        .userInitiated, .idleDisplaySleepDisabled, .latencyCritical,
    ]

    /// Creates the system-backed keep-awake.
    public init() {}

    /// Begins the activity.
    ///
    /// - Parameter reason: The activity's reason, shown by `pmset -g
    ///   assertions`.
    /// - Returns: The hold that ends the activity.
    public func hold(reason: String) -> any KeepAwakeHold {
        Hold(token: ProcessInfo.processInfo.beginActivity(options: Self.options, reason: reason))
    }

    /// One begun activity. A class because ending it is a one-time effect
    /// shared by every copy of the reference.
    private final class Hold: KeepAwakeHold {
        /// The activity's token until it is ended, then nil. `ProcessInfo`
        /// hands back an object that is not `Sendable`, so it lives behind
        /// the mutex and never leaves it.
        private let token: Mutex<(any NSObjectProtocol)?>

        /// Wraps a begun activity.
        ///
        /// - Parameter token: What `beginActivity` returned.
        init(token: sending any NSObjectProtocol) {
            self.token = Mutex(token)
        }

        /// Ends the activity the first time it is called.
        func release() {
            token.withLock { token in
                guard let begun = token else { return }
                ProcessInfo.processInfo.endActivity(begun)
                token = nil
            }
        }

        /// Ends the activity if its owner never did, so a dropped hold
        /// cannot keep the Mac awake for the life of the process.
        deinit {
            release()
        }
    }
}
