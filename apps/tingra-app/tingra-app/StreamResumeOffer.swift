//
//  StreamResumeOffer.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-10-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation
import TingraComposition

/// Whether this launch offers to go live again after the last run ended
/// while it was live, decided once the engine is up and the project's
/// destinations are merged (ARCHITECTURE.md, "Offering to resume a stream
/// after the app dies").
///
/// Always an offer, never an automatic restart, and streaming only: a
/// recording is not resumed.
enum StreamResumeOffer: Equatable {
    /// The last run left no record: nothing to offer, nothing to report.
    case none

    /// Ask the operator, naming the destinations that would go on air.
    case ask(destinations: [DestinationEdit], wentLive: Date)

    /// A record was found, but resuming no longer makes sense.
    case skip(SkipReason)

    /// Why a record was set aside without asking: the `reason` of the
    /// `stream.resumeSkipped` event.
    enum SkipReason: String, Equatable, Sendable {
        /// This launch opened another project than the one that was live.
        case projectChanged

        /// None of the recorded destinations is still enabled and streamable
        /// in the project.
        case noDestinations
    }

    /// The operator's answer to the offer.
    enum Answer: String, Equatable, Sendable {
        /// Resume Stream, the default button.
        case resume
        /// Don't Resume.
        case decline

        /// The answer's button, as the `tap` event that reports the click.
        var tapName: String {
            switch self {
            case .resume: "streamResume.button"
            case .decline: "streamResumeDecline.button"
            }
        }
    }

    /// The destinations a stream that just went live is on air to, as the
    /// record names them: the streamable ones, less any that rejected the
    /// connection at start. A rejected destination was never live, and the
    /// next launch must not say it was or try it again.
    ///
    /// - Parameters:
    ///   - destinations: The project's destinations, in order.
    ///   - states: Each destination's state as the session has reported it.
    static func liveDestinationIDs(
        of destinations: [DestinationEdit], states: [ProjectDestinationID: EngineModel.DestinationState]
    ) -> [String] {
        DestinationEdit.streamable(in: destinations).filter { states[$0.id] != .rejected }.map(\.id.rawValue)
    }

    /// Decides the offer from what the launch found.
    ///
    /// The launch must have opened the project the record names, and at
    /// least one recorded destination must still be enabled and streamable
    /// in it; the question names only those.
    ///
    /// - Parameters:
    ///   - record: What the last run left behind, when it ended live
    ///     (``LiveStreamRecord``).
    ///   - projectURL: The project document this launch opened.
    ///   - destinations: The open project's destinations, merged.
    static func decide(
        record: LiveStreamRecord.Contents?, projectURL: URL, destinations: [DestinationEdit]
    ) -> StreamResumeOffer {
        guard let record else { return .none }
        guard record.project.standardizedFileURL == projectURL.standardizedFileURL else {
            return .skip(.projectChanged)
        }
        let recorded = Set(record.destinations)
        let streamable = destinations.filter { $0.isStreamable && recorded.contains($0.id.rawValue) }
        guard !streamable.isEmpty else { return .skip(.noDestinations) }
        return .ask(destinations: streamable, wentLive: record.wentLive)
    }
}

/// The question the app asks at launch after its last run ended while it was
/// live (ARCHITECTURE.md, "Offering to resume a stream after the app dies").
enum StreamResumeAlert {
    /// Asks, app-modally, once the engine is up and the program is running,
    /// so the operator can see what would go on air before answering.
    ///
    /// - Parameters:
    ///   - destinations: The names of the destinations that would go live.
    ///   - wentLive: When the interrupted stream went live.
    /// - Returns: The operator's answer.
    @MainActor
    static func ask(destinations: [String], wentLive: Date) -> StreamResumeOffer.Answer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Tingra quit while it was live.",
            comment: "Launch alert title after the app's last run ended while a stream was live")
        alert.informativeText = informativeText(destinations: destinations, wentLive: wentLive)
        alert.addButton(
            withTitle: String(
                localized: "Resume Stream",
                comment: "Launch alert button: go live again to the destinations the interrupted stream had"))
        let decline = alert.addButton(
            withTitle: String(
                localized: "Don't Resume", comment: "Launch alert button: leave the interrupted stream stopped"))
        // Escape answers no: only a button titled Cancel gets it by default.
        decline.keyEquivalent = "\u{1b}"
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .resume : .decline
    }

    /// The alert's text: where the stream was going and since when, then
    /// what resuming does.
    ///
    /// - Parameters:
    ///   - destinations: The names of the destinations that would go live.
    ///   - wentLive: When the interrupted stream went live.
    static func informativeText(destinations: [String], wentLive: Date) -> String {
        let names = destinations.formatted(.list(type: .and))
        let time = wentLive.formatted(date: .abbreviated, time: .shortened)
        let interrupted = String(
            localized: "The stream to \(names) went live \(time).",
            comment:
                "Launch alert text; the first placeholder is the destinations' names, the second is the date and time the stream went live"
        )
        let explanation = String(
            localized: "Resuming starts a new stream to the same destinations. A recording is not resumed.",
            comment: "Launch alert text explaining what Resume Stream does")
        return interrupted + "\n\n" + explanation
    }
}
