//
//  StreamKey.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Errors reading the stream key at connect time.
enum StreamKeyError: Error, Equatable {
    /// `--key-stdin` was passed but standard input yielded no key.
    case emptyStdin

    /// The `--key-env` variable disappeared between validation and connect.
    case missingEnvironment(String)
}

extension StreamKeyError {
    /// The stable error identifier this error reports under (see CLI.md,
    /// "Error identifiers").
    var identifier: ErrorIdentifier { .invalidArgument }
}

extension StreamKeyError: CustomStringConvertible {
    var description: String {
        switch self {
        case .emptyStdin:
            return "No stream key arrived on standard input; pipe or type the key when using --key-stdin."
        case .missingEnvironment(let name):
            return "The --key-env variable '\(name)' is not set (or is empty)."
        }
    }
}

/// Reads the stream key from whichever source the command was given —
/// `--key`, `--key-env`, or `--key-stdin` (see CLI.md, "Destination").
/// The key is read here, at connect time, and never printed, logged, or
/// put on the event bus.
enum StreamKey {
    /// Resolves the key value, or nil when no source was given (a
    /// destination that needs no key).
    ///
    /// Throws ``StreamKeyError`` when a given source yields nothing.
    static func read(option: String?, environmentVariable: String?, stdin: Bool) throws -> String? {
        if let option {
            return option
        }
        if let environmentVariable {
            guard
                let value = ProcessInfo.processInfo.environment[environmentVariable],
                !value.isEmpty
            else {
                throw StreamKeyError.missingEnvironment(environmentVariable)
            }
            return value
        }
        if stdin {
            guard let line = readLine(strippingNewline: true), !line.isEmpty else {
                throw StreamKeyError.emptyStdin
            }
            return line
        }
        return nil
    }
}
