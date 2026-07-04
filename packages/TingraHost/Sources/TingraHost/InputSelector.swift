//
//  InputSelector.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Errors thrown by selector resolution (`--camera` / `--mic`, see CLI.md
/// "Input selection").
public enum InputSelectorError: Error, Equatable {
    /// No registered input of the kind matches the selector.
    case notFound(selector: String, kind: InputKind)

    /// A name-substring selector matched more than one input of the kind;
    /// the names carry the matches for the error message.
    case ambiguous(selector: String, kind: InputKind, matches: [String])
}

extension InputSelectorError {
    /// The stable error identifier this error reports under (see CLI.md,
    /// "Error identifiers").
    public var identifier: ErrorIdentifier {
        switch self {
        case .notFound: return .inputNotFound
        case .ambiguous: return .inputAmbiguous
        }
    }
}

extension InputSelectorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let selector, let kind):
            return """
                No \(kind.rawValue) input matches '\(selector)'. Run `tingra-cli devices` to list \
                the connected inputs and their identifiers; a selector is an index, a unique name \
                substring, or an ID from `devices --json`.
                """
        case .ambiguous(let selector, let kind, let matches):
            return """
                The \(kind.rawValue) selector '\(selector)' matches more than one input: \
                \(matches.joined(separator: ", ")). Use a longer name substring, the index, or the \
                ID from `devices --json` to pick one.
                """
        }
    }
}

extension InputRegistry {
    /// The registered inputs of one kind, in the canonical listing order —
    /// name, then identifier for devices sharing a name. This is the order
    /// `devices` output presents and index selectors count in; listing and
    /// resolution must never disagree.
    public func inputs(ofKind kind: InputKind) -> [any Input] {
        allInputs
            .filter { $0.kind == kind }
            .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
    }

    /// Resolves a `--camera` / `--mic` style selector against the
    /// registered inputs of one kind (CLI.md, "Input selection").
    ///
    /// Selector forms, tried in order:
    /// 1. **ID** — an exact match on an input's stable identifier (the
    ///    `devices --json` form) wins outright.
    /// 2. **Index** — an integer selects by position in the canonical
    ///    listing order (the numbers `devices` prints).
    /// 3. **Name substring** — anything else matches case-insensitively
    ///    against input names and must match exactly one.
    ///
    /// Throws ``InputSelectorError/notFound(selector:kind:)`` when nothing
    /// matches and ``InputSelectorError/ambiguous(selector:kind:matches:)``
    /// when a name substring matches more than one input.
    public func resolveInput(selector: String, ofKind kind: InputKind) throws -> any Input {
        let candidates = inputs(ofKind: kind)
        if let exact = candidates.first(where: { $0.id.rawValue == selector }) {
            return exact
        }
        if let index = Int(selector) {
            guard candidates.indices.contains(index) else {
                throw InputSelectorError.notFound(selector: selector, kind: kind)
            }
            return candidates[index]
        }
        let matches = candidates.filter { $0.name.localizedStandardContains(selector) }
        switch matches.count {
        case 0:
            throw InputSelectorError.notFound(selector: selector, kind: kind)
        case 1:
            return matches[0]
        default:
            throw InputSelectorError.ambiguous(selector: selector, kind: kind, matches: matches.map(\.name))
        }
    }
}
