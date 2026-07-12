//
//  Compositor.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Synchronization
import TingraEventBus
import TingraPlugInKit

/// The tick-paced Metal/Core Image compositor: it renders the current shot's
/// layer tree to one program frame per program tick (CLOCK.md, "The program
/// tick"). This is the step-6 realization of the model the single-input
/// ``ProgramPacer`` stood in for during the CLI era — same tick, same
/// latest-wins slot semantics, same timestamps, with "take the latest frame"
/// replaced by "render the layer tree" across every input.
///
/// It holds a latest-wins slot per input (a fill task drains each input's
/// `frames()` stream into it) and the current ``Shot``. On each tick it
/// snapshots the shot and the slots, hands them to a task-confined
/// ``ShotRenderer``, and yields the composited program frame — stamped with
/// the tick's master clock time, so sinks receive a clean, monotonic,
/// constant-rate PTS regardless of any input's native cadence. A stalled
/// input keeps its last frame in its slot, so its layer keeps compositing
/// (a stalled input does not stall the program); the program is a live
/// canvas from the first tick, showing the background before any input
/// delivers.
///
/// Ownership (ARCHITECTURE.md, "Frame ownership across the `Input` seam"):
/// the compositor is the one holder of each input's latest frame, releasing
/// the previous frame as a newer one replaces it in the slot; the renderer
/// only reads the held, immutable frames and composites them into a fresh
/// program buffer.
///
/// It can hold a whole ``Preset`` worth of shots (``loadPreset(_:)``) and
/// switch which one is on program with ``take(shotID:transition:)`` — the
/// default is a **cut**, the instant transition (GLOSSARY.md, "Transition");
/// passing ``Transition/dissolve`` crossfades between the outgoing and
/// incoming shot over its duration instead. A **wipe** and custom
/// shader-based transitions are a later iteration. ``setShot(_:)`` remains
/// the low-level "render exactly this shot" path used by the pre-preset
/// callers and tests (always a hard cut, no blending); the preset path
/// (``loadPreset(_:)`` + ``take(shotID:transition:)``) is what the app drives.
///
/// The mutating controls (``setInputs(_:)``, ``setShot(_:)``,
/// ``loadPreset(_:)``, ``take(shotID:)``, ``start()``, ``stop()``) are meant
/// to be driven from one context (the app's main actor); they are internally
/// locked but not designed for concurrent callers racing each other.
public final class Compositor: Sendable {
    /// The clock whose tick paces the program (the master clock in
    /// production, a synthetic clock in tests).
    private let clock: any EngineClock

    /// The program geometry and rate every frame is rendered at.
    private let format: ProgramFormat

    /// The host's event bus, carrying the compositor's control-plane events
    /// (never per-frame traffic — EVENTS.md).
    private let eventBus: EventBus

    /// Builds the shot renderer. Called once, inside the tick task, so the
    /// renderer (and its `CIContext`) stays task-confined and needs no
    /// `Sendable` conformance (see ``ShotRenderer``).
    private let makeRenderer: @Sendable () -> any ShotRenderer

    /// The compositor's live state behind a mutex — the fill tasks, tick
    /// task, and program-frame consumers all touch it from different tasks.
    private let state = Mutex(State())

    /// The mutable compositor state.
    private struct State {
        /// The latest frame each input has produced, keyed by id — the
        /// latest-wins slots. A replaced frame is released as it is
        /// overwritten (the ownership rule's "one holder at a time").
        var slots: [InputID: CapturedFrame] = [:]

        /// The frame-draining task per input, so inputs can be swapped and
        /// cancelled cleanly.
        var fillTasks: [InputID: Task<Void, Never>] = [:]

        /// The current shot the tick renders.
        var shot = Shot()

        /// The shots of the loaded preset, the pool ``take(shotID:)`` cuts
        /// among. Empty until a preset is loaded (the pre-preset ``setShot``
        /// path does not populate it).
        var shots: [Shot] = []

        /// The id of the shot currently on program, when it came from the
        /// loaded preset. `nil` before a preset is loaded or after a direct
        /// ``setShot`` that bypassed the preset.
        var activeShotID: ShotID?

        /// A dissolve in progress, or `nil` when idle (a cut has already
        /// replaced `shot` outright and needs no tick-by-tick blending).
        /// While set, the tick renders a crossfade from `outgoing` toward
        /// `shot` (the incoming shot) instead of `shot` alone.
        var pendingTransition: PendingTransition?

        /// The single active program-frame consumer, while attached.
        var programContinuation: AsyncStream<CapturedFrame>.Continuation?

        /// The running tick task, while started.
        var tickTask: Task<Void, Never>?
    }

    /// A dissolve counted in ticks rather than wall-clock time, so its
    /// progress is exact and deterministic under both the master clock and a
    /// synthetic test clock (CLOCK.md, "The program tick" — nothing outside
    /// the tick stream decides how much time has passed).
    private struct PendingTransition {
        /// The shot being transitioned away from.
        let outgoing: Shot

        /// The number of ticks the whole dissolve spans, at least one so a
        /// zero or negative duration still completes on its first tick
        /// rather than never finishing.
        let totalTicks: Int

        /// How many of those ticks have rendered so far.
        var elapsedTicks: Int = 0
    }

    /// Creates a compositor.
    ///
    /// - Parameters:
    ///   - clock: The clock whose tick paces the program.
    ///   - format: The program geometry and rate (default 1920x1080 at 30).
    ///   - eventBus: The host's event bus.
    ///   - makeRenderer: The shot-renderer factory; defaults to the
    ///     Metal-backed Core Image renderer. Tests inject a factory that
    ///     builds a mock renderer.
    public init(
        clock: any EngineClock,
        format: ProgramFormat = ProgramFormat(),
        eventBus: EventBus,
        makeRenderer: @escaping @Sendable () -> any ShotRenderer = { CoreImageShotRenderer() }
    ) {
        self.clock = clock
        self.format = format
        self.eventBus = eventBus
        self.makeRenderer = makeRenderer
    }

    /// The program-frame stream: one composited frame per program tick. A
    /// new call replaces the previous consumer (finishing its stream),
    /// matching the one-consumer contract the media seams use.
    public func programFrames() -> AsyncStream<CapturedFrame> {
        AsyncStream { continuation in
            let previous = state.withLock { state in
                let previous = state.programContinuation
                state.programContinuation = continuation
                return previous
            }
            previous?.finish()
        }
    }

    /// Sets the inputs whose frames feed the shot's layers. Inputs must
    /// already be started (the compositor composites; it does not own device
    /// lifecycle). Inputs no longer present have their fill task cancelled
    /// and their slot cleared; newly present inputs get a fill task draining
    /// their `frames()` into a slot.
    ///
    /// - Parameter inputs: The inputs available to the current (and future)
    ///   shots.
    public func setInputs(_ inputs: [any Input]) {
        let desiredIDs = Set(inputs.map(\.id))
        // Snapshot the frame streams for genuinely new inputs outside the
        // lock: `frames()` finishes any previous consumer (one holder at a
        // time), so it must be called once per new input, never for one
        // already being drained.
        let trackedIDs = state.withLock { Set($0.fillTasks.keys) }
        let newStreams = inputs.filter { !trackedIDs.contains($0.id) }.map { ($0.id, $0.frames()) }

        state.withLock { state in
            for (id, task) in state.fillTasks where !desiredIDs.contains(id) {
                task.cancel()
                state.fillTasks[id] = nil
                state.slots[id] = nil
            }
            for (id, stream) in newStreams {
                state.fillTasks[id] = Task { [weak self] in
                    for await frame in stream {
                        self?.store(frame, for: id)
                    }
                }
            }
        }
    }

    /// Switches the shot the tick renders directly, bypassing the loaded
    /// preset. Takes effect on the next tick — switching shots does not
    /// interrupt pacing (GLOSSARY.md, "Shot"). Because it does not come from
    /// the preset, it clears ``activeShotID``; drive the preset with
    /// ``loadPreset(_:)`` and ``take(shotID:)`` instead when you want the
    /// active-shot tracking.
    ///
    /// - Parameter shot: The new layer tree and background.
    public func setShot(_ shot: Shot) {
        state.withLock {
            $0.shot = shot
            $0.activeShotID = nil
            $0.pendingTransition = nil
        }
    }

    /// Loads a preset's shots as the pool ``take(shotID:)`` cuts among, and
    /// cuts to its first shot (or the empty background-only program when the
    /// preset has no shots). Takes effect on the next tick; loading does not
    /// interrupt pacing (GLOSSARY.md, "Preset").
    ///
    /// - Parameter preset: The preset whose shots become available on program.
    public func loadPreset(_ preset: Preset) {
        let first = preset.shots.first
        state.withLock { state in
            state.shots = preset.shots
            state.activeShotID = first?.id
            state.shot = first ?? Shot()
            state.pendingTransition = nil
        }
        eventBus.event(
            "preset.loaded",
            domain: .composition,
            params: [
                "preset": .string(preset.id.rawValue),
                "name": .string(preset.name),
                "shots": .int(preset.shots.count),
            ]
        )
    }

    /// Takes the loaded preset's shot with the given id to program, effective
    /// on the next tick. `transition` defaults to a **cut** (the instant
    /// switch, unchanged from before this shot ever accepted a transition);
    /// passing ``Transition/dissolve`` crossfades from the outgoing shot to
    /// the incoming one over its duration instead — the tick renders the
    /// blend every tick until the dissolve completes, then settles on the
    /// incoming shot alone. Taking an id that is not in the loaded preset
    /// leaves the program unchanged and reports a `program.take` error event
    /// (a stale switcher selection is recoverable, never a crash); otherwise
    /// it reports the take, including the transition, on the bus.
    ///
    /// - Parameters:
    ///   - shotID: The id of the shot to take to program.
    ///   - transition: The transition to take it with (default: a cut).
    public func take(shotID: ShotID, transition: Transition = .cut) {
        let frameRate = format.frameRate
        let taken: Shot? = state.withLock { state in
            guard let shot = state.shots.first(where: { $0.id == shotID }) else { return nil }
            let outgoing = state.shot
            state.activeShotID = shotID
            state.shot = shot
            switch transition {
            case .cut:
                state.pendingTransition = nil
            case .dissolve(let duration):
                // At least one tick, so a zero or negative duration still
                // completes on its first tick rather than never finishing.
                let totalTicks = max(1, Int((duration * Double(frameRate)).rounded()))
                state.pendingTransition = PendingTransition(outgoing: outgoing, totalTicks: totalTicks)
            }
            return shot
        }
        guard let taken else {
            eventBus.error(
                "program.take",
                domain: .composition,
                params: [
                    "shot": .string(shotID.rawValue),
                    "reason": .string("unknownShot"),
                ]
            )
            return
        }
        eventBus.event(
            "program.take",
            domain: .composition,
            params: [
                "shot": .string(taken.id.rawValue),
                "name": .string(taken.name),
                "transition": .string(transition.eventName),
            ]
        )
    }

    /// The shots of the loaded preset, in switcher order (empty before a
    /// preset is loaded).
    public var shots: [Shot] {
        state.withLock { $0.shots }
    }

    /// The id of the shot currently on program when it came from the loaded
    /// preset, or `nil` before a preset is loaded or after a direct
    /// ``setShot(_:)``.
    public var activeShotID: ShotID? {
        state.withLock { $0.activeShotID }
    }

    /// Starts the program tick: the compositor renders and yields one frame
    /// per tick until ``stop()``. Idempotent — a second call while running
    /// does nothing.
    public func start() {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(format.frameRate))
        let clock = self.clock
        let format = self.format
        let makeRenderer = self.makeRenderer

        state.withLock { state in
            guard state.tickTask == nil else { return }
            state.tickTask = Task { [weak self] in
                // The renderer lives entirely inside this task; program
                // frames leave it only through the continuation's yield.
                let renderer = makeRenderer()
                for await tickTime in clock.tick(every: frameDuration) {
                    guard !Task.isCancelled, let self else { break }
                    let snapshot = self.state.withLock { state -> TickSnapshot in
                        var dissolve: TickSnapshot.Dissolve?
                        if var pending = state.pendingTransition {
                            pending.elapsedTicks += 1
                            let progress = min(1, Double(pending.elapsedTicks) / Double(pending.totalTicks))
                            dissolve = TickSnapshot.Dissolve(outgoing: pending.outgoing, progress: progress)
                            state.pendingTransition = pending.elapsedTicks >= pending.totalTicks ? nil : pending
                        }
                        return TickSnapshot(
                            shot: state.shot,
                            frames: state.slots,
                            continuation: state.programContinuation,
                            dissolve: dissolve
                        )
                    }
                    guard let continuation = snapshot.continuation else { continue }
                    let program: CapturedFrame? =
                        if let dissolve = snapshot.dissolve {
                            renderer.renderDissolve(
                                from: dissolve.outgoing,
                                to: snapshot.shot,
                                progress: dissolve.progress,
                                frames: snapshot.frames,
                                format: format,
                                time: tickTime
                            )
                        } else {
                            renderer.render(
                                shot: snapshot.shot, frames: snapshot.frames, format: format, time: tickTime)
                        }
                    if let program {
                        continuation.yield(program)
                    }
                }
            }
        }
        eventBus.event(
            "program.started",
            domain: .composition,
            params: [
                "resolution": .string("\(format.width)x\(format.height)"),
                "fps": .int(format.frameRate),
            ]
        )
    }

    /// Stops the program tick, cancels every fill task, finishes the program
    /// stream, and clears the slots. Safe to call more than once.
    public func stop() {
        let (tickTask, fillTasks, continuation) = state.withLock { state in
            let taken = (state.tickTask, Array(state.fillTasks.values), state.programContinuation)
            state.tickTask = nil
            state.fillTasks.removeAll()
            state.slots.removeAll()
            state.programContinuation = nil
            state.pendingTransition = nil
            return taken
        }
        tickTask?.cancel()
        for task in fillTasks {
            task.cancel()
        }
        continuation?.finish()
        eventBus.event("program.stopped", domain: .composition)
    }

    /// Stores one input's newest frame into its latest-wins slot.
    private func store(_ frame: CapturedFrame, for id: InputID) {
        state.withLock { $0.slots[id] = frame }
    }
}

/// What one tick needs to render, snapshotted out of ``Compositor/State``
/// under its lock in a single pass — including advancing (and, on
/// completion, clearing) any in-progress dissolve, so the tick task never
/// re-enters the lock mid-render.
private struct TickSnapshot {
    /// A dissolve in progress this tick, or `nil` for a plain render.
    struct Dissolve {
        /// The shot being transitioned away from.
        let outgoing: Shot

        /// How far through the dissolve this tick falls, `0`...`1`.
        let progress: Double
    }

    /// The shot to render — the incoming shot while a dissolve is in
    /// progress, otherwise the shot currently on program.
    let shot: Shot

    /// The latest frame each input has produced, keyed by id.
    let frames: [InputID: CapturedFrame]

    /// The active program-frame consumer, or `nil` if none is attached.
    let continuation: AsyncStream<CapturedFrame>.Continuation?

    /// The dissolve to render this tick, or `nil` for a plain render of
    /// `shot`.
    let dissolve: Dissolve?
}

extension Transition {
    /// The event-bus name for this transition's kind — `"cut"` or
    /// `"dissolve"` — reported on ``Compositor``'s `program.take` event.
    fileprivate var eventName: String {
        switch self {
        case .cut: "cut"
        case .dissolve: "dissolve"
        }
    }
}
