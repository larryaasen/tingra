//
//  DestinationEdit.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition
import TingraHost

/// One destination as the streaming panel edits it (GLOSSARY.md,
/// "Destination"). This is the app's observable session state, merged from the
/// **two** places a destination now lives (DESTINATIONS.md): the name and URL
/// come from the operator-global store (`TingraHost.StoredDestination`), and
/// the enabled flag from this project's `TingraComposition.DestinationReference`.
/// The ``MixerStrip``/`AudioChannel` pairing, one concern over.
///
/// The split is why editing a name here writes to the store — where every
/// project sees it — while toggling Enabled writes only to this project.
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
    /// - Parameters:
    ///   - destination: The operator's saved record — name and URL.
    ///   - isEnabled: Whether this project streams to it (default yes).
    init(_ destination: StoredDestination, isEnabled: Bool = true) {
        self.init(
            id: ProjectDestinationID(rawValue: destination.id.rawValue),
            urlText: destination.url.absoluteString,
            name: destination.name,
            isEnabled: isEnabled
        )
    }

    /// The store's id for this destination — the same string as ``id``,
    /// carried in the host's type because the document and the store name the
    /// concept with types from packages that do not depend on each other
    /// (DESTINATIONS.md).
    var storeID: DestinationID {
        DestinationID(rawValue: id.rawValue)
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

    /// The operator's record of this destination, or nil when the typed URL
    /// is not yet usable — an incomplete destination is not saved, so a
    /// half-typed URL never reaches the store.
    var storedDestination: StoredDestination? {
        guard let url else { return nil }
        return StoredDestination(id: storeID, name: name, url: url)
    }

    /// This project's reference to the destination: which one, and whether
    /// this show streams to it. Always available — a reference needs no URL,
    /// so parking a half-typed row still records the operator's intent.
    var reference: DestinationReference {
        DestinationReference(id: id, isEnabled: isEnabled)
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
            comment: "Placeholder label for a destination with no name or URL yet"
        )
    }

    /// The destination URL schemes Tingra streams to — the same set the CLI
    /// validates `--url` against (CLI.md, "Destination").
    static let supportedSchemes: Set<String> = ["rtmp", "rtmps", "srt"]

    /// The panel's rows: every destination the operator has saved, in store
    /// order, each carrying this project's enabled flag for it.
    ///
    /// Store order rather than project order, because the list is
    /// operator-global — the same destinations in the same order in every
    /// project (DESTINATIONS.md). Two consequences follow from that ownership:
    ///
    /// - A **dangling reference** — one naming a destination the operator has
    ///   since deleted from the store — contributes no row. Deleting a
    ///   destination removes it from every project that used it, which is what
    ///   operator-global means; a project cannot hold one back.
    /// - A destination this project has **never referenced** appears disabled,
    ///   so one saved in another show is offered here without going surprise-live.
    ///
    /// - Parameters:
    ///   - saved: The operator's destinations, in store order.
    ///   - references: This project's references, if any.
    /// - Returns: One edit per saved destination, in store order.
    static func edits(
        saved: [StoredDestination],
        references: [DestinationReference]?
    ) -> [DestinationEdit] {
        let enabled = Dictionary(
            (references ?? []).map { ($0.id.rawValue, $0.isEnabled) },
            uniquingKeysWith: { _, last in last }
        )
        return saved.map { destination in
            DestinationEdit(destination, isEnabled: enabled[destination.id.rawValue] ?? false)
        }
    }

    /// This project's references for the panel's rows, or nil when there are
    /// none — so a project with no destination writes no `destinations` key.
    ///
    /// A reference is written for every row, parked ones included: the enabled
    /// flag is exactly the per-show state the project owns, and dropping a
    /// disabled row would lose the operator's decision not to stream there.
    ///
    /// - Parameter edits: The panel's destinations, in order.
    /// - Returns: The document's references, or nil when empty.
    static func references(from edits: [DestinationEdit]) -> [DestinationReference]? {
        edits.isEmpty ? nil : edits.map(\.reference)
    }
}
