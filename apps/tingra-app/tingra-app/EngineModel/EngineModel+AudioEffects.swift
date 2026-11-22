//
//  EngineModel+AudioEffects.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAudio
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// Audio effect chains on the mixer's channel strips.
extension EngineModel {
    /// Appends an effect to a strip's chain at its neutral settings: an empty
    /// payload, every parameter at its declared default. The chain
    /// re-instantiates into the mixer, the autosave is debounced, and the Add
    /// Effect menu's `tap` carries the observability (EVENTS.md).
    ///
    /// - Parameters:
    ///   - effectID: The effect to append.
    ///   - id: The strip's input id.
    func addEffect(_ effectID: EffectID, toStrip id: InputID) async {
        guard let index = mixerStrips.firstIndex(where: { $0.id == id }) else { return }
        mixerStrips[index].effects.append(EffectConfiguration(effect: effectID))
        await pushEffectChain(forStrip: id)
        scheduleAutosave()
    }

    /// Removes one slot from a strip's chain. An out-of-range slot is a
    /// stale gesture, ignored.
    ///
    /// - Parameters:
    ///   - effectIndex: The slot to remove.
    ///   - id: The strip's input id.
    func removeEffect(at effectIndex: Int, fromStrip id: InputID) async {
        guard
            let index = mixerStrips.firstIndex(where: { $0.id == id }),
            mixerStrips[index].effects.indices.contains(effectIndex)
        else { return }
        mixerStrips[index].effects.remove(at: effectIndex)
        await pushEffectChain(forStrip: id)
        scheduleAutosave()
    }

    /// Moves one slot of a strip's chain. Order is signal order, so a move is
    /// an audible routing change. The destination is clamped; a move to the
    /// same position, or of an unknown slot, does nothing.
    ///
    /// - Parameters:
    ///   - effectIndex: The slot to move.
    ///   - destination: The destination position in the chain.
    ///   - id: The strip's input id.
    func moveEffect(at effectIndex: Int, to destination: Int, onStrip id: InputID) async {
        guard
            let index = mixerStrips.firstIndex(where: { $0.id == id }),
            mixerStrips[index].effects.indices.contains(effectIndex)
        else { return }
        let to = min(max(destination, 0), mixerStrips[index].effects.count - 1)
        guard to != effectIndex else { return }
        let configuration = mixerStrips[index].effects.remove(at: effectIndex)
        mixerStrips[index].effects.insert(configuration, at: to)
        await pushEffectChain(forStrip: id)
        scheduleAutosave()
    }

    /// Sets one parameter of one slot in a strip's chain, applied to the
    /// mixer's live instance in place so it keeps its processing state.
    /// Gesture-rate: it reports nothing itself (the slider's drag-end `tap`
    /// does, EVENTS.md) and the autosave is debounced.
    ///
    /// - Parameters:
    ///   - value: The parameter's new value.
    ///   - key: The parameter's persisted key.
    ///   - effectIndex: The slot whose parameter changes.
    ///   - id: The strip's input id.
    func setEffectParameter(_ value: Double, forKey key: String, ofEffectAt effectIndex: Int, onStrip id: InputID) {
        setEffectParameter(.double(value), forKey: key, ofEffectAt: effectIndex, onStrip: id)
    }

    /// Sets one parameter of one slot in a strip's chain to any payload
    /// value — a color well's color object as well as a slider's number —
    /// on the same in-place, gesture-rate path.
    ///
    /// - Parameters:
    ///   - value: The parameter's new payload value.
    ///   - key: The parameter's persisted key.
    ///   - effectIndex: The slot whose parameter changes.
    ///   - id: The strip's input id.
    func setEffectParameter(_ value: JSONValue, forKey key: String, ofEffectAt effectIndex: Int, onStrip id: InputID) {
        guard
            let index = mixerStrips.firstIndex(where: { $0.id == id }),
            mixerStrips[index].effects.indices.contains(effectIndex)
        else { return }
        let existing = mixerStrips[index].effects[effectIndex]
        var parameters = existing.parameters
        parameters[key] = value
        mixerStrips[index].effects[effectIndex] = EffectConfiguration(effect: existing.effect, parameters: parameters)
        mixer.setEffectParameters(parameters, forEffectAt: effectIndex, forInput: id)
        scheduleAutosave()
    }

    /// The user-facing name of a registered audio effect, for the chain
    /// editor's rows. Falls back to the raw identifier for an effect with no
    /// provider: a document can name effects from a missing plug-in.
    ///
    /// - Parameter id: The effect's stable identifier.
    func effectName(for id: EffectID) -> String {
        audioEffectChoices.first { $0.id == id }?.name ?? id.rawValue
    }

    /// The declared parameters of a registered audio effect, for the chain
    /// editor's sliders — empty for an effect with no provider (its
    /// settings persist but cannot be edited until the provider returns).
    ///
    /// - Parameter id: The effect's stable identifier.
    func effectParameters(for id: EffectID) -> [Parameter] {
        audioEffectChoices.first { $0.id == id }?.parameters ?? []
    }

    /// Instantiates a strip's authored chain through the effect registry, one
    /// instance per slot in signal order. A configuration whose effect has no
    /// registered provider is reported and instantiated as a pass-through,
    /// never dropped: the in-place parameter path addresses slots by index,
    /// and the authored entry keeps its place for the provider's return.
    ///
    /// - Parameter configurations: The strip's authored chain.
    /// - Returns: The live effect instances, in signal order.
    func makeEffectChain(_ configurations: [EffectConfiguration]) async -> [any AudioEffect] {
        var chain: [any AudioEffect] = []
        for configuration in configurations {
            if let provider = await effects.audioProvider(withID: configuration.effect) {
                chain.append(provider.makeEffect(parameters: configuration.parameters))
            } else {
                eventBus.error(
                    "effect.resolve",
                    domain: .audio,
                    params: ["effect": .string(configuration.effect.rawValue)]
                )
                chain.append(PassthroughAudioEffect())
            }
        }
        return chain
    }

    /// Re-instantiates one strip's chain into its mixer channel after a
    /// structural chain edit (add, remove, move). The mixer ignores a strip
    /// whose device is not running; its chain lands on the next audio
    /// reconfigure pass, when the device starts.
    ///
    /// - Parameter id: The strip's input id.
    private func pushEffectChain(forStrip id: InputID) async {
        guard let strip = mixerStrips.first(where: { $0.id == id }) else { return }
        mixer.setEffects(await makeEffectChain(strip.effects), forInput: id)
    }
}

/// The stand-in for a chain slot whose effect has no registered provider:
/// passes the block through unchanged, holding the slot's index (see
/// `EngineModel.makeEffectChain(_:)`).
private struct PassthroughAudioEffect: AudioEffect {
    /// Ignores every payload — there is nothing to configure.
    func setParameters(_ parameters: [String: JSONValue]) {}

    /// Leaves the block unchanged.
    func process(_ channels: inout [[Float]], sampleRate: Double) {}
}
