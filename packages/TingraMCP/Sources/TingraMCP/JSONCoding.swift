//
//  JSONCoding.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Encodes a ``JSONValue`` to compact JSON text — the human-readable text
/// block inside a `tools/call` result, and a small helper anywhere a
/// value needs a string rendering.
enum JSONText {
    /// The shared compact encoder: sorted keys (so the same value always
    /// renders identically, which keeps tests deterministic) and unescaped
    /// slashes (URLs stay readable).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The value as compact JSON text, or `"{}"` if it somehow cannot be
    /// encoded — a rendering helper must never throw into the message path.
    static func encode(_ value: JSONValue) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
