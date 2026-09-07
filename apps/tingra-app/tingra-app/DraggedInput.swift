//
//  DraggedInput.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreTransferable
import TingraPlugInKit
import UniformTypeIdentifiers

/// The payload of an input dragged from the sidebar — onto the shot bank,
/// where the drop inserts a full-frame shot of it, or onto the layer editor's
/// layer list, where the drop adds a layer bound to it (ARCHITECTURE.md, "The
/// shot bank").
///
/// Its own exported type rather than plain text, so a dropped payload is
/// never mistaken for text and text dropped from another app is never
/// mistaken for an input: only a sidebar input row produces one, and only
/// the two surfaces above accept one. The type is declared in the target's
/// `Info.plist` (`UTExportedTypeDeclarations`, beside `Tingra.xcconfig` and
/// merged into the generated plist), which the declared-type rule requires of
/// an exported identifier.
///
/// `nonisolated`: `Transferable`'s requirement is nonisolated, and the app
/// target defaults every type to the main actor.
nonisolated struct DraggedInput: Codable, Sendable, Equatable, Transferable {
    /// The dragged input's stable identifier. The name is not carried —
    /// the drop resolves it through the model, so a device renamed between
    /// the drag and the drop reads its current name.
    let id: InputID

    /// The one representation: the id, encoded under the app's own type.
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tingraInput)
    }
}

extension UTType {
    /// The exported type a ``DraggedInput`` travels under —
    /// `com.moonwink.tingra.input`, one of the app's `com.moonwink.tingra.*`
    /// identifiers (CLAUDE.md, "Toolchain & CI").
    nonisolated static let tingraInput = UTType(exportedAs: "com.moonwink.tingra.input")
}
