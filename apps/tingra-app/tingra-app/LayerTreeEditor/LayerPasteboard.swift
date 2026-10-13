//
//  LayerPasteboard.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation
import TingraComposition
import UniformTypeIdentifiers

/// A copied layer on a pasteboard: what Edit > Copy writes and Edit > Paste
/// reads, so a layer built in one shot can be put into another
/// (ARCHITECTURE.md, "Copying a layer between shots").
///
/// The payload is the `Layer` itself in its document encoding — the input
/// it binds, its frame, its opacity, and its effect chain — under the app's
/// own exported type, so a copied layer is never mistaken for text and text
/// copied elsewhere is never mistaken for a layer. Because it is the system
/// pasteboard and the document's own JSON, a layer also pastes into another
/// preset or another project; one whose input that project cannot see lands
/// dormant, like any layer whose device is away.
///
/// The pasteboard is a parameter rather than `NSPasteboard.general` so the
/// tests run against a pasteboard of their own.
///
/// `nonisolated`: these are pure functions over the pasteboard handed in,
/// and the app target defaults every type to the main actor.
nonisolated enum LayerPasteboard {
    /// The pasteboard type a copied layer travels under.
    static let type = NSPasteboard.PasteboardType(UTType.tingraLayer.identifier)

    /// Replaces the pasteboard's contents with a layer.
    ///
    /// - Parameters:
    ///   - layer: The layer to copy.
    ///   - pasteboard: The pasteboard to write.
    /// - Throws: The encoding error, if the layer cannot be encoded — the
    ///   pasteboard is then left as it was.
    static func write(_ layer: Layer, to pasteboard: NSPasteboard) throws {
        let data = try JSONEncoder().encode(layer)
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
    }

    /// Whether the pasteboard holds a layer — what enables Edit > Paste.
    ///
    /// - Parameter pasteboard: The pasteboard to look at.
    /// - Returns: Whether a layer payload is on it. The payload is not
    ///   decoded; ``layer(on:)`` is what proves it readable.
    static func containsLayer(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [type]) != nil
    }

    /// The layer on the pasteboard.
    ///
    /// - Parameter pasteboard: The pasteboard to read.
    /// - Returns: The layer, or nil when the pasteboard holds none or holds
    ///   a payload this build cannot decode.
    static func layer(on pasteboard: NSPasteboard) -> Layer? {
        guard let data = pasteboard.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(Layer.self, from: data)
    }
}

extension UTType {
    /// The exported type a copied layer travels under —
    /// `com.moonwink.tingra.layer`, declared in the app's Info.plist beside
    /// ``tingraInput``.
    nonisolated static let tingraLayer = UTType(exportedAs: "com.moonwink.tingra.layer", conformingTo: .json)
}
