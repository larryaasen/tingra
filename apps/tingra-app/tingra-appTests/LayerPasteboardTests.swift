//
//  LayerPasteboardTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import CoreGraphics
import Testing
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

@Suite("LayerPasteboard")
struct LayerPasteboardTests {
    /// A layer with every property away from its default, so a round trip
    /// that dropped one would show.
    private let layer = Layer(
        input: InputID(rawValue: "camera-1"),
        frame: CGRect(x: 0.6, y: 0.55, width: 0.35, height: 0.4),
        opacity: 0.8,
        effects: [EffectConfiguration(effect: EffectID(rawValue: "blur"), parameters: ["radius": .double(4.5)])]
    )

    /// Runs a test body against a pasteboard of its own, released after.
    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    @Test("a copied layer reads back with its input, frame, opacity, and effect chain")
    func roundTrip() throws {
        try withPasteboard { pasteboard in
            try LayerPasteboard.write(layer, to: pasteboard)
            #expect(LayerPasteboard.containsLayer(pasteboard))
            #expect(LayerPasteboard.layer(on: pasteboard) == layer)
        }
    }

    @Test("an empty pasteboard holds no layer")
    func emptyPasteboard() {
        withPasteboard { pasteboard in
            #expect(!LayerPasteboard.containsLayer(pasteboard))
            #expect(LayerPasteboard.layer(on: pasteboard) == nil)
        }
    }

    @Test("text on the pasteboard is not a layer")
    func textIsNotALayer() {
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("{\"input\":\"camera-1\"}", forType: .string)
            #expect(!LayerPasteboard.containsLayer(pasteboard))
            #expect(LayerPasteboard.layer(on: pasteboard) == nil)
        }
    }

    @Test("a payload that does not decode reads as no layer")
    func undecodablePayload() {
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setData(Data("not a layer".utf8), forType: LayerPasteboard.type)
            #expect(LayerPasteboard.containsLayer(pasteboard))
            #expect(LayerPasteboard.layer(on: pasteboard) == nil)
        }
    }

    @Test("copying replaces what the pasteboard held")
    func copyReplacesContents() throws {
        try withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("earlier", forType: .string)
            try LayerPasteboard.write(layer, to: pasteboard)
            #expect(pasteboard.string(forType: .string) == nil)
            let second = Layer(input: InputID(rawValue: "display-1"))
            try LayerPasteboard.write(second, to: pasteboard)
            #expect(LayerPasteboard.layer(on: pasteboard) == second)
        }
    }

    @Test("the layer travels under the app's own type")
    func pasteboardType() {
        #expect(LayerPasteboard.type.rawValue == "com.moonwink.tingra.layer")
    }
}
