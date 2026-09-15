//
//  ActivationCondition.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus

/// An event on the app's bus that wakes an app-tier plug-in (PLUGINS.md,
/// Phase 2, "Activation conditions"; Decision 6): the plug-in's manifest
/// lists the conditions, and the app launches the extension's process on
/// the first event matching one — so a plug-in with no pane, a tally-light
/// bridge say, still comes alive when the stream starts — and tells the
/// extension which condition fired and what the event was
/// (``TingraAppExtension/activated(by:event:using:)``).
///
/// Written in a manifest as one string: the event's name, optionally
/// followed by a colon and one param the event must carry with a given
/// value:
///
/// ```
/// stream.started
/// device.connected:kind=camera
/// ```
///
/// The name is matched exactly against the event's `name`, whatever its
/// domain; the qualifier compares the param's string form, so `attempt=2`
/// matches an `int` param as well as a `string` one. A plug-in's own events
/// qualify like any other, since every event on the bus is one name.
public struct ActivationCondition: Hashable, Sendable, Codable, CustomStringConvertible {
    /// A param the matching event must carry: its key and the value's
    /// string form.
    public struct Qualifier: Hashable, Sendable {
        /// The param's key (`kind`).
        public let key: String

        /// The value the param must have, as text (`camera`).
        public let value: String

        /// Creates a qualifier.
        ///
        /// - Parameters:
        ///   - key: The param's key.
        ///   - value: The value the param must have, as text.
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// The event's name (`stream.started`).
    public let event: String

    /// The param the event must carry, if the condition names one.
    public let qualifier: Qualifier?

    /// Creates a condition.
    ///
    /// - Parameters:
    ///   - event: The event's name.
    ///   - qualifier: The param the event must carry, if any.
    public init(event: String, qualifier: Qualifier? = nil) {
        self.event = event
        self.qualifier = qualifier
    }

    /// Parses a condition from its manifest form, `event` or
    /// `event:key=value`.
    ///
    /// - Parameter text: The condition as a manifest writes it.
    /// - Throws: ``ActivationConditionError`` naming what is wrong with the
    ///   text, so a typo is a reported error rather than a condition that
    ///   never fires.
    public init(parsing text: String) throws {
        let name: Substring
        let qualifierText: Substring?
        if let colon = text.firstIndex(of: ":") {
            name = text[..<colon]
            qualifierText = text[text.index(after: colon)...]
        } else {
            name = text[...]
            qualifierText = nil
        }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else {
            throw ActivationConditionError.invalidEvent(text)
        }
        var qualifier: Qualifier?
        if let qualifierText {
            guard let equals = qualifierText.firstIndex(of: "=") else {
                throw ActivationConditionError.malformedQualifier(text)
            }
            let key = qualifierText[..<equals]
            let value = qualifierText[qualifierText.index(after: equals)...]
            guard !key.isEmpty, !value.isEmpty else { throw ActivationConditionError.malformedQualifier(text) }
            qualifier = Qualifier(key: String(key), value: String(value))
        }
        self.init(event: String(name), qualifier: qualifier)
    }

    /// The condition in its manifest form.
    public var rawValue: String {
        guard let qualifier else { return event }
        return "\(event):\(qualifier.key)=\(qualifier.value)"
    }

    public var description: String { rawValue }

    /// Whether an event with `name` and `params` meets the condition.
    ///
    /// - Parameters:
    ///   - name: The event's name.
    ///   - params: The event's params.
    public func matches(name: String, params: [String: EventValue]?) -> Bool {
        guard name == event else { return false }
        guard let qualifier else { return true }
        return params?[qualifier.key]?.description == qualifier.value
    }

    /// Whether a bus event meets the condition.
    ///
    /// - Parameter event: The event.
    public func matches(_ event: EventBusEvent) -> Bool {
        matches(name: event.name, params: event.params)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            try self.init(parsing: text)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What can be wrong with an activation condition's text, each naming the
/// fix.
public enum ActivationConditionError: Error, Equatable, CustomStringConvertible {
    /// The event name is empty or carries a character an event name cannot.
    case invalidEvent(String)

    /// The text after the colon is not `key=value` with both sides present.
    case malformedQualifier(String)

    public var description: String {
        switch self {
        case .invalidEvent(let text):
            "Activation condition '\(text)' needs an event name of letters, digits, '_' and '.' before any ':'."
        case .malformedQualifier(let text):
            "Activation condition '\(text)' must qualify its event as 'event:key=value', with both a key and a value."
        }
    }
}
