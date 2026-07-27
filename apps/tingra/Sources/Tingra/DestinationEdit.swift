//
//  DestinationEdit.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition

/// One destination as the streaming panel edits it (GLOSSARY.md,
/// "Destination"). The document-side record is
/// `TingraComposition.ProjectDestination`; this is the app's observable
/// session state for it — the ``MixerStrip``/`AudioChannel` pairing, one
/// concern over.
///
/// It exists because the panel edits a **URL as text**: a half-typed
/// `rtm` is not a `URL`, and even the strings that do parse mid-typing parse
/// into nonsense. So the panel holds text, and only text that resolves to a
/// usable destination becomes a `ProjectDestination` at save and stream time
/// (``projectDestination``).
struct DestinationEdit: Identifiable, Equatable {
    /// The destination's stable identity — carried unchanged from the
    /// document, because the stream key is filed in secure storage under it
    /// (ARCHITECTURE.md, "Multiple destinations"). Editing the URL never
    /// changes the id, so the key follows the edit.
    let id: ProjectDestinationID

    /// The destination URL as typed. Not yet a `URL`: see the type's note.
    var urlText: String

    /// The operator's label for this destination ("Twitch"), or empty for an
    /// unnamed one, which the panel labels by its URL instead.
    var name: String

    /// Whether this destination is streamed to. A disabled destination keeps
    /// its URL, name, and stored key, but contributes no leg to the next
    /// stream.
    var isEnabled: Bool

    /// Creates a destination edit.
    ///
    /// - Parameters:
    ///   - id: The stable identity (default: a fresh one).
    ///   - urlText: The destination URL as typed (default empty).
    ///   - name: The operator's label (default empty).
    ///   - isEnabled: Whether it is streamed to (default yes).
    init(
        id: ProjectDestinationID = ProjectDestinationID(),
        urlText: String = "",
        name: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.urlText = urlText
        self.name = name
        self.isEnabled = isEnabled
    }

    /// Adopts a saved destination for editing.
    ///
    /// - Parameter destination: The document's record of it.
    init(_ destination: ProjectDestination) {
        self.init(
            id: destination.id,
            urlText: destination.url.absoluteString,
            name: destination.name,
            isEnabled: destination.isEnabled
        )
    }

    /// The URL this destination streams to, or nil while the typed text is
    /// not one Tingra can stream to.
    ///
    /// Requires a supported scheme rather than merely parsing, because
    /// `URL(string:)` accepts almost any fragment: `rtm` parses fine and
    /// would otherwise be saved and offered as a destination.
    var url: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), Self.supportedSchemes.contains(scheme) else { return nil }
        guard url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Whether this destination contributes a leg to the next stream: enabled
    /// and pointing somewhere streamable.
    var isStreamable: Bool {
        isEnabled && url != nil
    }

    /// The document's record of this destination, or nil when the typed URL
    /// is not yet usable — an incomplete destination is not saved, so a
    /// half-typed URL never reaches the project file.
    var projectDestination: ProjectDestination? {
        guard let url else { return nil }
        return ProjectDestination(id: id, url: url, name: name, isEnabled: isEnabled)
    }

    /// The label the panel shows for this destination: the operator's name
    /// when given, else the URL as typed, else a placeholder for a brand new
    /// row.
    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { return trimmedName }
        let trimmedURL = urlText.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty { return trimmedURL }
        return String(
            localized: "New destination",
            bundle: .module,
            comment: "Placeholder label for a destination with no name or URL yet"
        )
    }

    /// The destination URL schemes Tingra streams to — the same set the CLI
    /// validates `--url` against (CLI.md, "Destination").
    static let supportedSchemes: Set<String> = ["rtmp", "rtmps", "srt"]

    /// The panel's destinations for a project's saved list: one edit per
    /// saved destination, in order.
    ///
    /// - Parameter destinations: The project's saved destinations, if any.
    /// - Returns: One edit per destination, in the saved order.
    static func edits(from destinations: [ProjectDestination]?) -> [DestinationEdit] {
        (destinations ?? []).map(DestinationEdit.init)
    }

    /// The saved list for the panel's destinations: every one whose URL is
    /// usable, in panel order, or nil when none is — so a project with no
    /// usable destination writes no `destinations` key at all.
    ///
    /// - Parameter edits: The panel's destinations, in order.
    /// - Returns: The document's list, or nil when empty.
    static func projectDestinations(from edits: [DestinationEdit]) -> [ProjectDestination]? {
        let saved = edits.compactMap(\.projectDestination)
        return saved.isEmpty ? nil : saved
    }
}
