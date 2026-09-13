//
//  TakeTransitionTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraComposition

@testable import TingraApp

/// Exercises how a take resolves the transition panel's armed kind, the
/// taken shot's default, and the panel's duration into the one transition
/// handed to the compositor.
@MainActor
@Suite("Take transition resolution")
struct TakeTransitionTests {
    /// Resolves with the panel's edge and shader fixed, so a test names
    /// only what it varies.
    private func resolve(
        _ kind: TakeTransitionKind,
        shotDefault: Transition? = nil,
        duration: TimeInterval = 0.5
    ) -> Transition {
        EngineModel.resolvedTransition(
            kind: kind, shotDefault: shotDefault, wipeEdge: .right, shaderName: .blinds, duration: duration)
    }

    @Test("an explicit kind takes at the panel's duration with the armed edge or shader")
    func explicitKindUsesPanelDuration() {
        #expect(resolve(.cut, duration: 2) == .cut)
        #expect(resolve(.dissolve, duration: 2) == .dissolve(duration: 2))
        #expect(resolve(.wipe, duration: 2) == .wipe(edge: .right, duration: 2))
        #expect(resolve(.shader, duration: 2) == .shader(name: .blinds, duration: 2))
    }

    @Test("Default keeps the shot's own kind, edge, and shader and takes at the panel's duration")
    func defaultKeepsShotKindAtPanelDuration() {
        #expect(
            resolve(.default, shotDefault: .wipe(edge: .top, duration: 0.5), duration: 1.5)
                == .wipe(edge: .top, duration: 1.5))
        #expect(
            resolve(.default, shotDefault: .shader(name: .iris, duration: 3), duration: 0.25)
                == .shader(name: .iris, duration: 0.25))
        #expect(resolve(.default, shotDefault: .dissolve(duration: 9), duration: 1) == .dissolve(duration: 1))
    }

    @Test("Default with no shot default is a cut, whatever the duration")
    func defaultWithoutShotDefaultCuts() {
        #expect(resolve(.default, shotDefault: nil, duration: 4) == .cut)
        #expect(resolve(.default, shotDefault: .cut, duration: 4) == .cut)
    }

    @Test("withDuration replaces only the length; a cut is unchanged")
    func withDurationReplacesLength() {
        #expect(Transition.cut.withDuration(3) == .cut)
        #expect(Transition.dissolve(duration: 0.5).withDuration(3) == .dissolve(duration: 3))
        #expect(Transition.wipe(edge: .bottom, duration: 0.5).withDuration(3) == .wipe(edge: .bottom, duration: 3))
        #expect(
            Transition.shader(name: .diagonal, duration: 0.5).withDuration(3)
                == .shader(name: .diagonal, duration: 3))
    }

    @Test("the take duration is clamped to the panel's range and a non-finite value falls back to the default")
    func durationIsClamped() {
        #expect(EngineModel.clampedTakeTransitionDuration(0.75) == 0.75)
        #expect(EngineModel.clampedTakeTransitionDuration(-1) == EngineModel.takeTransitionDurationRange.lowerBound)
        #expect(EngineModel.clampedTakeTransitionDuration(60) == EngineModel.takeTransitionDurationRange.upperBound)
        #expect(EngineModel.clampedTakeTransitionDuration(.infinity) == Transition.defaultDissolveDuration)
        #expect(EngineModel.clampedTakeTransitionDuration(.nan) == Transition.defaultDissolveDuration)
    }
}
