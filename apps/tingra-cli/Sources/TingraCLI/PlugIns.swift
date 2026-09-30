//
//  PlugIns.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-09-29.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// `tingra-cli plug-ins` — what the engine loads, and why not; and turning a
/// plug-in bundle off or back on (CLI.md; PLUGINS.md, Decision 35).
///
/// With no subcommand it lists, so `tingra-cli plug-ins --json` is the
/// listing.
struct PlugIns: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plug-ins",
        abstract: "List the plug-ins the engine loads, and turn a plug-in bundle off or back on.",
        subcommands: [List.self, Enable.self, Disable.self],
        defaultSubcommand: List.self
    )

    /// `tingra-cli plug-ins [list] [--json] [--safe-mode]` — every host-tier
    /// plug-in `serve` runs, each in one state.
    ///
    /// It builds `serve`'s engine against scratch registries and loads and
    /// activates the bundles, as `devices` does, because "loaded" is only
    /// true once dyld and `activate` agree: reading the Info.plists alone
    /// would miss a bundle that fails to load. It exits 0 whatever the
    /// states, since a refused bundle is data, not a failed command.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List every plug-in the engine loads, and why any bundle was not loaded."
        )

        @Flag(help: "Emit the listing as one JSON document for scripting.")
        var json = false

        @OptionGroup var plugIns: PlugInOptions

        func run() async throws {
            let eventBus = EventBus()
            // The listing carries every plug-in event as data, so the console
            // shows only the errors from elsewhere; OSLog still records all
            // of them (EVENTS.md, "OSLog sink").
            let consoleTask = eventBus.attach(
                ConsoleSink(mode: json ? .json : .human, groups: [.error], isIncluded: { $0.domain != .plugIn }))
            let osLogTask = eventBus.attach(OSLogSink())

            let engine = DaemonEngine(eventBus: eventBus)
            let report = await engine.activatePlugIns(bundlesFrom: plugIns.bundleLoader(for: "plug-ins")).report

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
            } else {
                print(report.table)
            }

            eventBus.shutdown()
            await consoleTask.value
            await osLogTask.value
        }
    }

    /// `tingra-cli plug-ins enable <id>` — turns a plug-in bundle back on,
    /// whether the operator or a crash turned it off.
    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn a plug-in bundle back on, from the next launch."
        )

        @Argument(help: "The plug-in's id, as `tingra-cli plug-ins` lists it.")
        var id: String

        func run() throws {
            try PlugInSwitch.standard.run(id: PlugInID(rawValue: id), on: true)
        }
    }

    /// `tingra-cli plug-ins disable <id>` — turns a plug-in bundle off in
    /// every front end.
    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn a plug-in bundle off, from the next launch."
        )

        @Argument(help: "The plug-in's id, as `tingra-cli plug-ins` lists it.")
        var id: String

        func run() throws {
            try PlugInSwitch.standard.run(id: PlugInID(rawValue: id), on: false)
        }
    }
}

/// Turns one plug-in bundle on or off in `plug-ins.json`, the file every
/// front end reads (PLUGINS.md, Decision 34), after checking the id names a
/// bundle.
struct PlugInSwitch {
    /// What a switch did.
    enum Outcome: Equatable {
        /// The file now records the change.
        case changed
        /// The plug-in was already in that state; nothing was written.
        case unchanged
    }

    /// Why a switch was refused.
    enum Refusal: Error, Equatable, CustomStringConvertible {
        /// No bundle in the folders declares the id.
        case unknownID(PlugInID, folders: [String])
        /// The id is a plug-in compiled into Tingra, which is always on.
        case compiledIn(PlugInID)
        /// The enablement file could not be read or written.
        case store(PlugInEnablementStoreError)

        /// The cause and the fix.
        var description: String {
            switch self {
            case .unknownID(let id, let folders):
                return "No plug-in bundle in \(folders.joined(separator: " or ")) declares the id '\(id.rawValue)'. "
                    + "`tingra-cli plug-ins` lists the ids of every plug-in installed."
            case .compiledIn(let id):
                return "'\(id.rawValue)' is built into Tingra and is always on. Only plug-in bundles can be turned "
                    + "on or off."
            case .store(let error):
                return error.description
            }
        }

        /// The exit code: a usage error for an id, an internal error for the
        /// file (CLI.md, "Exit codes").
        var exitCode: Int32 {
            switch self {
            case .unknownID, .compiledIn: ErrorIdentifier.invalidArgument.exitCode
            case .store: ErrorIdentifier.pipelineError.exitCode
            }
        }
    }

    /// The ids of the plug-ins compiled into `serve`.
    let compiledInIDs: Set<PlugInID>

    /// The ids the installed bundles declare.
    let declaredIDs: Set<PlugInID>

    /// The folders searched, home folder as `~`, for the unknown-id message.
    let folders: [String]

    /// The enablement file.
    let store: PlugInEnablementStore

    /// The switch over the operator's own folders and file, and `serve`'s
    /// compiled-in plug-ins.
    static var standard: PlugInSwitch {
        let loader = PlugInBundleLoader()
        return PlugInSwitch(
            compiledInIDs: Set(DaemonEngine(eventBus: EventBus()).compiledInPlugIns.map(\.id)),
            declaredIDs: loader.declaredIDs(),
            folders: loader.folders.map { ($0.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath },
            store: loader.enablement)
    }

    /// Turns the plug-in on or off.
    ///
    /// `enable` also accepts an id no installed bundle declares when the
    /// file still records it, so an entry left by a bundle since removed can
    /// be cleared.
    ///
    /// - Parameters:
    ///   - id: The plug-in.
    ///   - on: Whether to turn it on.
    /// - Returns: Whether the file changed.
    /// - Throws: ``Refusal``.
    func set(_ id: PlugInID, on: Bool) throws(Refusal) -> Outcome {
        guard !compiledInIDs.contains(id) else { throw .compiledIn(id) }
        let recorded: PlugInEnablement
        do {
            recorded = try store.read()
        } catch let error as PlugInEnablementStoreError {
            throw .store(error)
        } catch {
            throw .store(.unreadable(path: store.fileURL.path(percentEncoded: false), reason: "\(error)"))
        }
        let isRecorded = recorded.isDisabled(id) || recorded.crash(of: id) != nil
        guard declaredIDs.contains(id) || (on && isRecorded) else { throw .unknownID(id, folders: folders) }

        do {
            let updated = try store.update { on ? $0.enable(id) : $0.disable(id) }
            return updated == recorded ? .unchanged : .changed
        } catch let error as PlugInEnablementStoreError {
            throw .store(error)
        } catch {
            throw .store(.unwritable(path: store.fileURL.path(percentEncoded: false), reason: "\(error)"))
        }
    }

    /// Runs the switch for a command: prints what happened, or the refusal
    /// on standard error with its exit code.
    ///
    /// - Parameters:
    ///   - id: The plug-in.
    ///   - on: Whether to turn it on.
    /// - Throws: `ExitCode` when refused.
    func run(id: PlugInID, on: Bool) throws {
        do {
            print(Self.confirmation(for: try set(id, on: on), id: id, on: on))
        } catch {
            FileHandle.standardError.write(Data("plug-ins: \(error.description)\n".utf8))
            throw ExitCode(error.exitCode)
        }
    }

    /// The line confirming a switch.
    ///
    /// - Parameters:
    ///   - outcome: What the switch did.
    ///   - id: The plug-in.
    ///   - on: Whether it was turned on.
    static func confirmation(for outcome: Outcome, id: PlugInID, on: Bool) -> String {
        let state = on ? "on" : "off"
        guard outcome == .changed else { return "'\(id.rawValue)' is already \(state)." }
        return "Turned '\(id.rawValue)' \(state). Tingra, serve, and each tingra-cli command take this from their "
            + "next launch; a running serve keeps its plug-ins until it restarts."
    }
}

extension PlugInLoadReport {
    /// The human readable listing, in the `devices` table's style: the kit
    /// version and safe mode, then the built-in plug-ins and the installed
    /// bundles, each row with its state, and under a bundle its path and
    /// anything that went wrong.
    var table: String {
        let heading = "PLUG-IN KIT \(kitVersion)" + (safeMode ? " — SAFE MODE: no plug-in bundles were loaded" : "")
        let builtIn = plugIns.filter { $0.source == .compiledIn }
        let installed = plugIns.filter { $0.source == .bundle }
        let noneInstalled = "  (none; plug-in bundles are installed in \(folders.joined(separator: " or ")))"
        return [
            heading,
            Self.section(titled: "BUILT IN", entries: builtIn, whenEmpty: "  (none)"),
            Self.section(titled: "INSTALLED", entries: installed, whenEmpty: noneInstalled),
        ].joined(separator: "\n")
    }

    /// One section: the title, then a row per entry — state, name, version,
    /// and id, names column-aligned — each followed by its detail lines.
    private static func section(titled title: String, entries: [Entry], whenEmpty: String) -> String {
        guard !entries.isEmpty else { return "\(title)\n\(whenEmpty)" }
        let stateWidth = Entry.State.allCases.map(\.rawValue.count).max() ?? 0
        let labels = entries.map { entry in [entry.name, entry.version].compactMap(\.self).joined(separator: " ") }
        let labelWidth = labels.map(\.count).max() ?? 0
        let indent = String(repeating: " ", count: 2 + stateWidth + 2)
        var lines = [title]
        for (entry, label) in zip(entries, labels) {
            let state = entry.state.rawValue.padding(toLength: stateWidth, withPad: " ", startingAt: 0)
            let padded = label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            lines.append("  \(state)  \(padded)  (id: \(entry.id ?? "none declared"))")
            if let path = entry.path {
                lines.append(indent + path)
            }
            if let message = entry.message {
                lines.append(indent + (entry.reason.map { "\($0): " } ?? "") + message)
            }
            lines += entry.warnings.map { indent + "warning: " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}
