//
//  SessionPreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition

/// Where the operator was standing when the app last ran: the active preset,
/// the shot on program, the shot staged on preview, and the transition armed
/// on the switcher — its kind, the wipe edge, the shader, and the duration.
///
/// A value rather than loose ids because the pieces are restored
/// **together** — a staged shot is only meaningful within the preset it was
/// staged in — and validated together against the presets a launch actually
/// loaded (``launchPreset(in:)``, ``shots(validIn:)``): an id that no longer
/// exists is dropped, never guessed at, and the launch falls back to the
/// established rule for that piece alone. The armed transition needs no
/// pool to validate against: a value the app no longer knows reads nil and
/// leaves the picker on its default.
struct SessionPosition: Equatable, Sendable {
    /// The active preset, or nil when none was recorded.
    var presetID: PresetID?

    /// The shot on program, or nil when none was recorded (or program held a
    /// snapshot from outside the pool).
    var activeShotID: ShotID?

    /// The shot staged on preview, or nil when nothing was staged.
    var previewShotID: ShotID?

    /// The transition kind armed on the switcher, or nil when none was
    /// recorded (2026-09-07, Larry: "the transition setting from the dropdown
    /// is not retained after app restart").
    var transitionKind: TakeTransitionKind?

    /// The wipe edge armed on the switcher, or nil when none was recorded.
    var wipeEdge: WipeEdge?

    /// The shader armed on the switcher, or nil when none was recorded.
    var shaderName: TransitionShader?

    /// The take duration set on the switcher, in seconds, or nil when none
    /// was recorded (2026-09-13, with the panel's duration field). Clamped
    /// on restore like any typed value, so an out-of-range number read back
    /// is kept within the panel's range rather than trusted.
    var transitionDuration: TimeInterval?

    /// A position with nothing recorded — a fresh install, or a removal.
    static let none = SessionPosition()

    /// The preset a launch adopts: the recorded one when the document still
    /// holds it, otherwise the document's first — the load rule that stood
    /// before positions were recorded (ARCHITECTURE.md, "Restoring the
    /// operator's position").
    ///
    /// - Parameter presets: The document's presets, in switcher order.
    /// - Returns: The preset to adopt, or nil when the document has none.
    func launchPreset(in presets: [Preset]) -> Preset? {
        presets.first { $0.id == presetID } ?? presets.first
    }

    /// The recorded program and preview shots that exist in a preset's pool
    /// — each checked on its own, so a deleted staged shot does not cost the
    /// program shot its place, and vice versa.
    ///
    /// - Parameter preset: The preset the launch adopted.
    /// - Returns: The program shot to take and the shot to stage, each nil
    ///   when not recorded or no longer in the pool.
    func shots(validIn preset: Preset) -> (program: ShotID?, preview: ShotID?) {
        let pool = Set(preset.shots.map(\.id))
        return (
            program: activeShotID.flatMap { pool.contains($0) ? $0 : nil },
            preview: previewShotID.flatMap { pool.contains($0) ? $0 : nil }
        )
    }
}

/// Where the operator's position persists between launches: **machine-local
/// preferences**, not the project document and not session-only.
///
/// The document would be wrong for the reason ARCHITECTURE.md records three
/// times over: the project file is a pure description of the show, and where
/// the operator is standing in it — which preset, which shot on air, which
/// staged — is not part of the show. Session-only was the rule until
/// 2026-09-07, and it had a cost Larry named: every cold start put the first
/// preset's first shot on program and lit its second shot on preview,
/// whatever had been staged at quit. A desk remembers where its buttons
/// were; so the position lives beside the monitor device and the appearance,
/// in `UserDefaults`, on the ``MonitorPreferences`` pattern.
///
/// Written as the position changes (``EngineModel`` records it from the
/// properties' own observers) and read once at launch, before the first
/// assignment can overwrite it. Ids only — a deleted preset or shot is
/// simply not found at the next launch (``SessionPosition``).
///
/// **Scoped per project since 2026-09-13** (ARCHITECTURE.md, "Projects as
/// documents"): the preset and shot ids belong to one show, so a store is
/// made for a ``ProjectID`` and keeps that show's position under keys of
/// its own — switching projects and back finds each where it was left. The
/// armed transition is the switcher's setting rather than any show's, and
/// stays global, as does ``lastProjectURL``. A store with no project scope
/// reads and writes the flat keys of the one-project era, which is how a
/// document written before projects had ids keeps its position across the
/// launch that assigns it one.
struct SessionPreferences {
    /// The defaults database the values live in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The project whose position this store keeps, or nil for the flat
    /// keys of the one-project era.
    let projectID: ProjectID?

    /// The active preset's id key.
    private var presetKey: String { scoped("activePresetID") }

    /// The program shot's id key.
    private var activeShotKey: String { scoped("activeShotID") }

    /// The staged shot's id key.
    private var previewShotKey: String { scoped("previewShotID") }

    /// The last opened project's path key — global, since it names the
    /// scope rather than living in one.
    private static let projectPathKey = "session.projectPath"

    /// A bus-position key under this store's project scope
    /// (`session.projects.<id>.<name>`), or the flat `session.<name>` key
    /// when the store has none.
    ///
    /// - Parameter name: The key's own name.
    /// - Returns: The full key.
    private func scoped(_ name: String) -> String {
        guard let projectID else { return "session.\(name)" }
        return "session.projects.\(projectID.rawValue).\(name)"
    }

    /// The armed transition kind's key.
    private static let transitionKindKey = "session.transitionKind"

    /// The armed wipe edge's key.
    private static let wipeEdgeKey = "session.wipeEdge"

    /// The armed shader's key.
    private static let shaderNameKey = "session.shaderName"

    /// The take duration's key.
    private static let transitionDurationKey = "session.transitionDuration"

    /// Creates a store over a defaults database, for one project's position.
    ///
    /// - Parameters:
    ///   - defaults: The database to read and write (the standard one by
    ///     default).
    ///   - projectID: The project whose position the store keeps, or nil
    ///     (the default) for the flat keys of the one-project era.
    init(defaults: UserDefaults = .standard, projectID: ProjectID? = nil) {
        self.defaults = defaults
        self.projectID = projectID
    }

    /// The same store scoped to another project — the position keys move,
    /// the transition keys and the last project do not.
    ///
    /// - Parameter projectID: The project to scope to.
    /// - Returns: A store over the same defaults for that project.
    func scoped(to projectID: ProjectID?) -> SessionPreferences {
        SessionPreferences(defaults: defaults, projectID: projectID)
    }

    /// The project the app had open when it last ran, or nil when none was
    /// recorded — a fresh install, a removal, or every launch before
    /// projects became documents, all of which open the default project.
    /// Stored as a path: the app is not sandboxed, so no bookmark is needed,
    /// and a path reads plainly in the defaults. Setting nil removes the key.
    var lastProjectURL: URL? {
        get {
            defaults.string(forKey: Self.projectPathKey).map { URL(filePath: $0) }
        }
        nonmutating set {
            defaults.set(newValue?.path(percentEncoded: false), forKey: Self.projectPathKey)
        }
    }

    /// The recorded position; ``SessionPosition/none`` on a fresh install.
    /// Setting a nil id removes its key, so a cleared program (a held
    /// snapshot) or an empty preview reads back as nil rather than as a
    /// stale id. A transition value the app no longer knows reads nil
    /// rather than trapping, and a duration that is not a number reads nil
    /// rather than zero.
    var position: SessionPosition {
        get {
            SessionPosition(
                presetID: defaults.string(forKey: presetKey).map(PresetID.init(rawValue:)),
                activeShotID: defaults.string(forKey: activeShotKey).map(ShotID.init(rawValue:)),
                previewShotID: defaults.string(forKey: previewShotKey).map(ShotID.init(rawValue:)),
                transitionKind: defaults.string(forKey: Self.transitionKindKey).flatMap(
                    TakeTransitionKind.init(rawValue:)),
                wipeEdge: defaults.string(forKey: Self.wipeEdgeKey).flatMap(WipeEdge.init(rawValue:)),
                shaderName: defaults.string(forKey: Self.shaderNameKey).flatMap(TransitionShader.init(rawValue:)),
                transitionDuration: defaults.object(forKey: Self.transitionDurationKey) as? TimeInterval
            )
        }
        nonmutating set {
            defaults.set(newValue.presetID?.rawValue, forKey: presetKey)
            defaults.set(newValue.activeShotID?.rawValue, forKey: activeShotKey)
            defaults.set(newValue.previewShotID?.rawValue, forKey: previewShotKey)
            defaults.set(newValue.transitionKind?.rawValue, forKey: Self.transitionKindKey)
            defaults.set(newValue.wipeEdge?.rawValue, forKey: Self.wipeEdgeKey)
            defaults.set(newValue.shaderName?.rawValue, forKey: Self.shaderNameKey)
            defaults.set(newValue.transitionDuration, forKey: Self.transitionDurationKey)
        }
    }
}
