//
//  HaishinKitLogging.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import HaishinKit
import Logboard
import RTMPHaishinKit

/// Routes HaishinKit's internal logging (Logboard) into OSLog.
///
/// Logboard's default appender prints to standard output, which would
/// interleave HaishinKit's diagnostics with the CLI's NDJSON stream and
/// break the `--json` scripting contract (CLI.md). Rerouting to OSLog
/// keeps those diagnostics in the system of record (EVENTS.md, "OSLog
/// sink") and keeps stdout clean. This is dependency containment, not
/// logging: no Tingra code emits through Logboard, and the failures a
/// user must see still surface as Tingra `error` events.
enum HaishinKitLogging {
    /// One-time configuration, run when the first service is created.
    private static let configured: Bool = {
        for identifier in [kHaishinKitIdentifier, kRTMPHaishinKitIdentifier] {
            let logger = LBLogger.with(identifier)
            logger.appender = OSLoggerAppender(sybsystem: "com.moonwink.tingra", category: "haishinkit")
            logger.level = .info
        }
        return true
    }()

    /// Ensures the routing is in place. Idempotent and cheap.
    static func configure() {
        _ = configured
    }
}
