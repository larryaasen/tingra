//
//  Resource.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// One thing the engine lets an MCP client observe — MCP's *resource*
/// primitive beside the tools (PLUGINS.md, "Phase 2 — seams into the
/// engine"): a JSON document at a stable `tingra://` URI (the session, the
/// program, the inputs) that a client reads with `resources/read` and,
/// having subscribed, is told to read again whenever it changes. A tool is
/// how a client *acts* on the engine; a resource is how it *sees* what the
/// engine is doing.
///
/// A resource renders value types and identifiers only, never an engine
/// object — its document is a scripting contract on the same terms as a
/// tool's result (camelCase keys, append-only; CLAUDE.md, "Data Models").
/// The host's `ResourceRegistry` holds them; the app fills it from its
/// model, and a plug-in-contributed resource seam follows (PLUGINS.md,
/// Phase 4).
public protocol Resource: Sendable {
    /// The resource's URI, unique in the registry, e.g. `tingra://session`.
    /// Append-only: once shipped, never renamed or reused.
    var uri: String { get }

    /// A short machine-friendly name, e.g. `session`.
    var name: String { get }

    /// A short human-facing title, e.g. "Session".
    var title: String { get }

    /// What the resource carries, written for a reader who cannot see the
    /// code — a client chooses what to read from this.
    var description: String { get }

    /// The MIME type of what ``read()`` renders. Defaults to
    /// `application/json`, which every JSON resource is.
    var mimeType: String { get }

    /// The resource's current contents.
    ///
    /// - Returns: The document, a ``JSONValue`` object.
    /// - Throws: Any error; the MCP/Control service answers the read as an
    ///   internal error naming it.
    func read() async throws -> JSONValue

    /// A signal per change of the contents, for subscriptions: a subscriber
    /// is told the resource updated and reads it again. Signals coalesce —
    /// a burst of changes may arrive as one — so a subscriber never counts
    /// them. A resource that never changes returns an already-finished
    /// stream, the default. Each call returns an independent stream.
    func changes() -> AsyncStream<Void>
}

extension Resource {
    /// JSON, which every resource is until one is not.
    public var mimeType: String { "application/json" }

    /// Never changes: a finished stream.
    public func changes() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
