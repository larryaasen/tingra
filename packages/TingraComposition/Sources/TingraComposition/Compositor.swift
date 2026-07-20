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
/// It can hold a whole ``Preset`` worth of shots (``loadPreset(_:)`` — which
/// never interrupts what is already playing out; see its contract) and
/// switch which one is on program with ``take(shotID:transition:)`` — the
/// default is a **cut**, the instant transition (GLOSSARY.md, "Transition");
/// passing ``Transition/dissolve`` crossfades between the outgoing and
/// incoming shot over its duration instead, and
/// ``Transition/wipe(edge:duration:)`` reveals the incoming shot across the
/// frame from an edge, and ``Transition/shader(name:duration:)`` reveals it
/// through a built-in custom Metal shader. ``setShot(_:)`` remains
/// the low-level "render exactly this shot" path used by the pre-preset
/// callers and tests (always a hard cut, no blending); the preset path
/// (``loadPreset(_:)`` + ``take(shotID:transition:)``) is what the app drives.
///
/// A loaded shot's layer tree can be edited live with ``updateShot(_:)``:
/// it replaces the preset's shot with the matching id in place, and when
/// that shot is on program the very next tick renders the edited tree — the
/// program is a live canvas (CLOCK.md), so there is no separate "apply"
/// step. The edit persists in the loaded preset, so it survives later
/// ``take(shotID:transition:)`` switches within the session. The pool
/// itself is managed the same granular way: ``addShot(_:at:)`` inserts a
/// shot (adding is not taking — the program is untouched),
/// ``removeShot(shotID:)`` removes one, cutting to the adjacent shot when
/// the removed shot was on program — never a dead program — and
/// ``moveShot(shotID:to:)`` reorders one within the switcher order without
/// ever changing the program (reordering is not taking — ARCHITECTURE.md,
/// "Shot management", "Shot and preset reordering").
///
/// The mutating controls (``setInputs(_:)``, ``setShot(_:)``,
/// ``loadPreset(_:)``, ``take(shotID:)``, ``updateShot(_:)``,
/// ``addShot(_:at:)``, ``removeShot(shotID:)``, ``moveShot(shotID:to:)``,
/// ``start()``, ``stop()``)
/// are meant to be driven from one context (the app's main actor); they are
/// internally locked but not designed for concurrent callers racing each
/// other.
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

        /// A transition in progress — a dissolve's crossfade, a wipe's
        /// directional reveal, or a shader transition — or `nil` when idle (a cut has already
        /// replaced `shot` outright and needs no tick-by-tick blending).
        /// While set, the tick renders a blend from `outgoing` toward
        /// `shot` (the incoming shot) instead of `shot` alone.
        var pendingTransition: PendingTransition?

        /// The single active program-frame consumer, while attached.
        var programContinuation: AsyncStream<CapturedFrame>.Continuation?

        /// The running tick task, while started.
        var tickTask: Task<Void, Never>?
    }

    /// A transition (dissolve or wipe) counted in ticks rather than
    /// wall-clock time, so its progress is exact and deterministic under
    /// both the master clock and a synthetic test clock (CLOCK.md, "The
    /// program tick" — nothing outside the tick stream decides how much
    /// time has passed). Every kind shares this one timing spine; the kind
    /// only decides which ``ShotRenderer`` path blends each tick.
    private struct PendingTransition {
        /// The shot being transitioned away from.
        let outgoing: Shot

        /// The renderer path that blends each tick of this transition.
        let kind: BlendKind

        /// The number of ticks the whole transition spans, at least one so
        /// a zero or negative duration still completes on its first tick
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

    /// Loads a preset's shots as the pool ``take(shotID:transition:)`` cuts
    /// among. Takes effect on the next tick, and — per GLOSSARY.md ("Preset")
    /// — **switching presets never interrupts what is already playing out**:
    ///
    /// - When the shot on program also exists in the incoming preset (matched
    ///   by ``Shot/id``), it stays on program, adopting the incoming preset's
    ///   version of it — the ``updateShot(_:)`` rule applied across a preset
    ///   switch; an in-progress transition continues toward the adopted tree.
    /// - When it does not, the outgoing shot keeps rendering as a **held
    ///   snapshot** — ``activeShotID`` becomes `nil` (no shot of the loaded
    ///   preset is on program; ``programShot`` still names what renders) —
    ///   until the caller takes a shot from the new pool; an in-progress
    ///   transition completes toward the snapshot.
    /// - When no preset shot is on program at all (the first load after boot,
    ///   or after a direct ``setShot(_:)``), it cuts to the preset's first
    ///   shot — or the empty background-only program when the preset has no
    ///   shots — clearing any pending transition.
    ///
    /// The `preset.loaded` event's `activeShot` param reports the outcome:
    /// the on-program shot's id, `"held"` for a held snapshot, or `"none"`
    /// when an empty preset loaded onto an empty program.
    ///
    /// - Parameter preset: The preset whose shots become available on program.
    public func loadPreset(_ preset: Preset) {
        let programOutcome: String = state.withLock { state in
            state.shots = preset.shots
            if let activeID = state.activeShotID {
                guard let match = preset.shots.first(where: { $0.id == activeID }) else {
                    state.activeShotID = nil
                    return "held"
                }
                state.shot = match
                return match.id.rawValue
            }
            let first = preset.shots.first
            state.activeShotID = first?.id
            state.shot = first ?? Shot()
            state.pendingTransition = nil
            return first?.id.rawValue ?? "none"
        }
        eventBus.event(
            "preset.loaded",
            domain: .composition,
            params: [
                "preset": .string(preset.id.rawValue),
                "name": .string(preset.name),
                "shots": .int(preset.shots.count),
                "activeShot": .string(programOutcome),
            ]
        )
    }

    /// Takes the loaded preset's shot with the given id to program, effective
    /// on the next tick. `transition` defaults to a **cut** (the instant
    /// switch, unchanged from before this shot ever accepted a transition);
    /// passing ``Transition/dissolve`` crossfades from the outgoing shot to
    /// the incoming one over its duration instead, and
    /// ``Transition/wipe(edge:duration:)`` reveals the incoming shot across
    /// the frame from the given edge, and ``Transition/shader(name:duration:)``
    /// reveals it through the named built-in shader — in each case the tick
    /// renders the blend every tick until the transition completes, then
    /// settles on the incoming shot alone. Taking an id that is not in the loaded preset
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
                state.pendingTransition = PendingTransition(
                    outgoing: outgoing,
                    kind: .dissolve,
                    totalTicks: Self.tickCount(for: duration, frameRate: frameRate)
                )
            case .wipe(let edge, let duration):
                state.pendingTransition = PendingTransition(
                    outgoing: outgoing,
                    kind: .wipe(edge: edge),
                    totalTicks: Self.tickCount(for: duration, frameRate: frameRate)
                )
            case .shader(let name, let duration):
                state.pendingTransition = PendingTransition(
                    outgoing: outgoing,
                    kind: .shader(name: name),
                    totalTicks: Self.tickCount(for: duration, frameRate: frameRate)
                )
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

    /// Replaces the loaded preset's shot with the same id, in place — the
    /// live edit path a layer-tree editor drives. When the edited shot is
    /// the one on program, the very next tick renders the edited layer tree
    /// (no separate "apply" step — the program is a live canvas, CLOCK.md);
    /// while a transition is in progress toward it, the transition continues
    /// toward the edited tree. The edit persists in the loaded preset, so
    /// the shot keeps it across later ``take(shotID:transition:)`` switches
    /// within the session. ``activeShotID`` is untouched — editing a shot is
    /// not taking it.
    ///
    /// Updating an id that is not in the loaded preset leaves everything
    /// unchanged and reports a `shot.update` error event (recoverable, never
    /// a crash). A successful update deliberately reports **no** event: a
    /// live editor drives this at gesture rate (a slider drag calls it many
    /// times a second), which would flood the control-plane bus (EVENTS.md);
    /// user-action observability comes from the app's `tap` events instead.
    ///
    /// - Parameter shot: The edited shot, matched to the loaded preset's
    ///   shot by ``Shot/id``.
    public func updateShot(_ shot: Shot) {
        let updated = state.withLock { state -> Bool in
            guard let index = state.shots.firstIndex(where: { $0.id == shot.id }) else { return false }
            state.shots[index] = shot
            if state.activeShotID == shot.id {
                state.shot = shot
            }
            return true
        }
        guard updated else {
            eventBus.error(
                "shot.update",
                domain: .composition,
                params: [
                    "shot": .string(shot.id.rawValue),
                    "reason": .string("unknownShot"),
                ]
            )
            return
        }
    }

    /// Inserts a shot into the loaded preset's pool, making it available to
    /// ``take(shotID:transition:)`` — the shot-management add/duplicate path
    /// (ARCHITECTURE.md, "Shot management"). Adding a shot is **not** taking
    /// it: the program, ``activeShotID``, and any in-progress transition are
    /// untouched, matching ``updateShot(_:)``'s contract that editing the
    /// pool never changes what is on air.
    ///
    /// Adding an id already in the loaded preset is recoverable — it reports
    /// a `shot.add` error event and leaves the pool unchanged, never a
    /// crash. A successful add reports a `shot.added` control-plane event:
    /// unlike a gesture-rate ``updateShot(_:)``, adding is a discrete user
    /// action, so the event cannot flood the bus (EVENTS.md).
    ///
    /// - Parameters:
    ///   - shot: The shot to add; its ``Shot/id`` must not already be in the
    ///     loaded preset.
    ///   - index: The switcher position to insert at, clamped to the pool's
    ///     bounds; `nil` (the default) appends at the end.
    public func addShot(_ shot: Shot, at index: Int? = nil) {
        let insertedAt: Int? = state.withLock { state in
            guard !state.shots.contains(where: { $0.id == shot.id }) else { return nil }
            let position = min(max(index ?? state.shots.count, 0), state.shots.count)
            state.shots.insert(shot, at: position)
            return position
        }
        guard let insertedAt else {
            eventBus.error(
                "shot.add",
                domain: .composition,
                params: [
                    "shot": .string(shot.id.rawValue),
                    "reason": .string("duplicateShot"),
                ]
            )
            return
        }
        eventBus.event(
            "shot.added",
            domain: .composition,
            params: [
                "shot": .string(shot.id.rawValue),
                "name": .string(shot.name),
                "index": .int(insertedAt),
            ]
        )
    }

    /// Removes a shot from the loaded preset's pool. When the removed shot
    /// is on program, the compositor **cuts to the adjacent shot** — the
    /// shot now occupying the removed shot's switcher position, or the new
    /// last shot when the removed one was last — clearing any in-progress
    /// transition; removing the last remaining shot leaves the pool empty and
    /// the program on the background-only canvas with no active shot (still
    /// a live canvas, never a dead program — ARCHITECTURE.md, "Shot
    /// management"). Removing a shot that is only the *outgoing* side of an
    /// in-progress transition lets the transition finish from its snapshot — the
    /// outgoing shot is on its way off program, the same rule
    /// ``updateShot(_:)`` follows.
    ///
    /// Removing an id that is not in the loaded preset is recoverable — a
    /// `shot.remove` error event, the pool untouched, never a crash. A
    /// successful removal reports a `shot.removed` control-plane event whose
    /// `cutTo` param, present only when the removed shot was on program,
    /// names the shot the program cut to (or `"none"` when the pool
    /// emptied).
    ///
    /// - Parameter shotID: The id of the shot to remove.
    public func removeShot(shotID: ShotID) {
        let outcome: (removed: Shot, wasOnProgram: Bool, cutTo: Shot?)? = state.withLock { state in
            guard let index = state.shots.firstIndex(where: { $0.id == shotID }) else { return nil }
            let removed = state.shots.remove(at: index)
            guard state.activeShotID == shotID else { return (removed, false, nil) }
            state.pendingTransition = nil
            let adjacentIndex = min(index, state.shots.count - 1)
            guard adjacentIndex >= 0 else {
                state.activeShotID = nil
                state.shot = Shot()
                return (removed, true, nil)
            }
            let adjacent = state.shots[adjacentIndex]
            state.activeShotID = adjacent.id
            state.shot = adjacent
            return (removed, true, adjacent)
        }
        guard let outcome else {
            eventBus.error(
                "shot.remove",
                domain: .composition,
                params: [
                    "shot": .string(shotID.rawValue),
                    "reason": .string("unknownShot"),
                ]
            )
            return
        }
        var params: [String: EventValue] = [
            "shot": .string(outcome.removed.id.rawValue),
            "name": .string(outcome.removed.name),
        ]
        if outcome.wasOnProgram {
            params["cutTo"] = .string(outcome.cutTo?.id.rawValue ?? "none")
        }
        eventBus.event("shot.removed", domain: .composition, params: params)
    }

    /// Moves a shot to a new position in the loaded preset's switcher order —
    /// the shot-management reorder path (ARCHITECTURE.md, "Shot and preset
    /// reordering"). **Reordering never changes the program:** ``activeShotID``,
    /// the shot the tick renders, and any in-progress transition are all untouched
    /// — the on-program shot keeps its identity and simply sits at a different
    /// index, so a reorder survives a live take and a live transition by
    /// construction, the same guarantee ``updateShot(_:)`` and ``addShot(_:at:)``
    /// give. Reordering *does* change which shot ``removeShot(shotID:)`` would
    /// cut to (its adjacency rule reads the switcher order), which is the point.
    ///
    /// The destination index is clamped to the pool's bounds; moving a shot to
    /// the position it already holds is a no-op that reports nothing. Moving an
    /// id that is not in the loaded preset is recoverable — a `shot.move` error
    /// event, the pool untouched, never a crash. An actual move reports a
    /// `shot.moved` control-plane event (with the `from` and `to` indices):
    /// like ``addShot(_:at:)``/``removeShot(shotID:)`` and unlike a gesture-rate
    /// ``updateShot(_:)``, a reorder is a discrete, menu-command-driven action,
    /// so the event cannot flood the bus (EVENTS.md).
    ///
    /// - Parameters:
    ///   - shotID: The id of the shot to move.
    ///   - index: The destination position in the switcher order, clamped to
    ///     the pool's bounds.
    public func moveShot(shotID: ShotID, to index: Int) {
        let outcome: (shot: Shot, from: Int, to: Int)? = state.withLock { state in
            guard let from = state.shots.firstIndex(where: { $0.id == shotID }) else { return nil }
            let to = min(max(index, 0), state.shots.count - 1)
            guard to != from else { return (state.shots[from], from, from) }
            let shot = state.shots.remove(at: from)
            state.shots.insert(shot, at: to)
            return (shot, from, to)
        }
        guard let outcome else {
            eventBus.error(
                "shot.move",
                domain: .composition,
                params: [
                    "shot": .string(shotID.rawValue),
                    "reason": .string("unknownShot"),
                ]
            )
            return
        }
        guard outcome.from != outcome.to else { return }
        eventBus.event(
            "shot.moved",
            domain: .composition,
            params: [
                "shot": .string(outcome.shot.id.rawValue),
                "name": .string(outcome.shot.name),
                "from": .int(outcome.from),
                "to": .int(outcome.to),
            ]
        )
    }

    /// The shots of the loaded preset, in switcher order (empty before a
    /// preset is loaded).
    public var shots: [Shot] {
        state.withLock { $0.shots }
    }

    /// The id of the shot currently on program when it came from the loaded
    /// preset, or `nil` before a preset is loaded, after a direct
    /// ``setShot(_:)``, or while a preset switch holds the outgoing shot as a
    /// snapshot (see ``loadPreset(_:)``).
    public var activeShotID: ShotID? {
        state.withLock { $0.activeShotID }
    }

    /// The shot the tick is currently rendering: the active shot, a shot set
    /// directly with ``setShot(_:)``, or the held snapshot a preset switch
    /// left on program (see ``loadPreset(_:)``). Callers use it to keep the
    /// on-program shot's inputs running even when that shot is not in the
    /// loaded preset's pool.
    public var programShot: Shot {
        state.withLock { $0.shot }
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
                        var blend: TickSnapshot.Blend?
                        if var pending = state.pendingTransition {
                            pending.elapsedTicks += 1
                            let progress = min(1, Double(pending.elapsedTicks) / Double(pending.totalTicks))
                            blend = TickSnapshot.Blend(
                                outgoing: pending.outgoing, kind: pending.kind, progress: progress)
                            state.pendingTransition = pending.elapsedTicks >= pending.totalTicks ? nil : pending
                        }
                        return TickSnapshot(
                            shot: state.shot,
                            frames: state.slots,
                            continuation: state.programContinuation,
                            blend: blend
                        )
                    }
                    guard let continuation = snapshot.continuation else { continue }
                    let program: CapturedFrame? =
                        if let blend = snapshot.blend {
                            switch blend.kind {
                            case .dissolve:
                                renderer.renderDissolve(
                                    from: blend.outgoing,
                                    to: snapshot.shot,
                                    progress: blend.progress,
                                    frames: snapshot.frames,
                                    format: format,
                                    time: tickTime
                                )
                            case .wipe(let edge):
                                renderer.renderWipe(
                                    from: blend.outgoing,
                                    to: snapshot.shot,
                                    edge: edge,
                                    progress: blend.progress,
                                    frames: snapshot.frames,
                                    format: format,
                                    time: tickTime
                                )
                            case .shader(let name):
                                renderer.renderShader(
                                    from: blend.outgoing,
                                    to: snapshot.shot,
                                    shader: name,
                                    progress: blend.progress,
                                    frames: snapshot.frames,
                                    format: format,
                                    time: tickTime
                                )
                            }
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

    /// Converts a transition duration in seconds to the whole number of
    /// program ticks it spans — at least one, so a zero or negative duration
    /// still completes on its first tick rather than never finishing.
    private static func tickCount(for duration: TimeInterval, frameRate: Int) -> Int {
        max(1, Int((duration * Double(frameRate)).rounded()))
    }
}

/// The renderer path an in-progress transition blends each tick with — how
/// a ``PendingTransition``'s tick-counted progress turns into pixels. Every
/// kind shares the same timing spine; only the ``ShotRenderer`` call
/// differs.
private enum BlendKind {
    /// A crossfade —
    /// ``ShotRenderer/renderDissolve(from:to:progress:frames:format:time:)``.
    case dissolve

    /// A directional reveal from the given edge —
    /// ``ShotRenderer/renderWipe(from:to:edge:progress:frames:format:time:)``.
    case wipe(edge: WipeEdge)

    /// A custom-shader reveal drawn by the named built-in shader —
    /// ``ShotRenderer/renderShader(from:to:shader:progress:frames:format:time:)``.
    case shader(name: TransitionShader)
}

/// What one tick needs to render, snapshotted out of ``Compositor/State``
/// under its lock in a single pass — including advancing (and, on
/// completion, clearing) any in-progress transition, so the tick task never
/// re-enters the lock mid-render.
private struct TickSnapshot {
    /// A transition blend in progress this tick, or `nil` for a plain
    /// render.
    struct Blend {
        /// The shot being transitioned away from.
        let outgoing: Shot

        /// The renderer path that blends this tick.
        let kind: BlendKind

        /// How far through the transition this tick falls, `0`...`1`.
        let progress: Double
    }

    /// The shot to render — the incoming shot while a transition is in
    /// progress, otherwise the shot currently on program.
    let shot: Shot

    /// The latest frame each input has produced, keyed by id.
    let frames: [InputID: CapturedFrame]

    /// The active program-frame consumer, or `nil` if none is attached.
    let continuation: AsyncStream<CapturedFrame>.Continuation?

    /// The blend to render this tick, or `nil` for a plain render of
    /// `shot`.
    let blend: Blend?
}

extension Transition {
    /// The event-bus name for this transition's kind — `"cut"`,
    /// `"dissolve"`, `"wipe"`, or `"shader"` — reported on ``Compositor``'s
    /// `program.take` event.
    fileprivate var eventName: String {
        switch self {
        case .cut: "cut"
        case .dissolve: "dissolve"
        case .wipe: "wipe"
        case .shader: "shader"
        }
    }
}
