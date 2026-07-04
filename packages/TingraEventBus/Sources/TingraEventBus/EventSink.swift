//
//  EventSink.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A subscriber that turns bus events into an output: an OSLog record, a
/// console line, a file entry, retained status (see EVENTS.md, "Sinks").
///
/// Sinks are independent: each applies its own filtering, and attaching or
/// detaching one never affects emitters or other sinks.
public protocol EventSink: Sendable {
    /// Handles one event. Called in emission order, one event at a time per
    /// sink.
    func receive(_ event: EventBusEvent) async
}

extension EventBus {
    /// Attaches a sink, subscribing it to every event sent after this call.
    ///
    /// Returns the task consuming the sink's stream: cancel it to detach the
    /// sink, or await it after ``shutdown()`` to be sure buffered events
    /// drained (the CLI does this before exiting so nothing is lost).
    public func attach(_ sink: some EventSink) -> Task<Void, Never> {
        // Subscribe synchronously, so events sent between this call and the
        // task's first run are buffered rather than missed.
        let events = events()
        return Task {
            for await event in events {
                await sink.receive(event)
            }
        }
    }
}
