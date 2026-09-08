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
/// on the switcher — its kind, the wipe edge, and the shader.
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
struct SessionPreferences {
    /// The defaults database the values live in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The active preset's id key.
    private static let presetKey = "session.activePresetID"

    /// The program shot's id key.
    private static let activeShotKey = "session.activeShotID"

    /// The staged shot's id key.
    private static let previewShotKey = "session.previewShotID"

    /// The armed transition kind's key.
    private static let transitionKindKey = "session.transitionKind"

    /// The armed wipe edge's key.
    private static let wipeEdgeKey = "session.wipeEdge"

    /// The armed shader's key.
    private static let shaderNameKey = "session.shaderName"

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard
    ///   one by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The recorded position; ``SessionPosition/none`` on a fresh install.
    /// Setting a nil id removes its key, so a cleared program (a held
    /// snapshot) or an empty preview reads back as nil rather than as a
    /// stale id. A transition value the app no longer knows reads nil
    /// rather than trapping.
    var position: SessionPosition {
        get {
            SessionPosition(
                presetID: defaults.string(forKey: Self.presetKey).map(PresetID.init(rawValue:)),
                activeShotID: defaults.string(forKey: Self.activeShotKey).map(ShotID.init(rawValue:)),
                previewShotID: defaults.string(forKey: Self.previewShotKey).map(ShotID.init(rawValue:)),
                transitionKind: defaults.string(forKey: Self.transitionKindKey).flatMap(
                    TakeTransitionKind.init(rawValue:)),
                wipeEdge: defaults.string(forKey: Self.wipeEdgeKey).flatMap(WipeEdge.init(rawValue:)),
                shaderName: defaults.string(forKey: Self.shaderNameKey).flatMap(TransitionShader.init(rawValue:))
            )
        }
        nonmutating set {
            defaults.set(newValue.presetID?.rawValue, forKey: Self.presetKey)
            defaults.set(newValue.activeShotID?.rawValue, forKey: Self.activeShotKey)
            defaults.set(newValue.previewShotID?.rawValue, forKey: Self.previewShotKey)
            defaults.set(newValue.transitionKind?.rawValue, forKey: Self.transitionKindKey)
            defaults.set(newValue.wipeEdge?.rawValue, forKey: Self.wipeEdgeKey)
            defaults.set(newValue.shaderName?.rawValue, forKey: Self.shaderNameKey)
        }
    }
}
