//
//  InputClaimsTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-21.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraPlugInKit

@testable import TingraApp

/// Each test records what a claim or release told the caller to do — start
/// the input, stop it, or neither — before checking it, since a mutating call
/// cannot sit inside `#expect`.
@Suite("InputClaims")
struct InputClaimsTests {
    /// A video file with sound: the input both passes need.
    private let movie = InputID(rawValue: "movie")

    @Test("muting a movie's strip leaves running the input a layer still shows")
    func mutingAStripKeepsThePicture() {
        var claims = InputClaims()
        let layerStarts = claims.claim(movie, by: .picture)
        // The strip is unmuted: the input is already running for the layer,
        // so the audio pass must not start it a second time.
        let stripStarts = claims.claim(movie, by: .sound)
        // The strip is muted: the layer still needs the input, so it must not
        // stop. Before the shared rule, this is where the picture froze.
        let muteStops = claims.release(movie, by: .sound)

        #expect(layerStarts)
        #expect(stripStarts == false)
        #expect(muteStops == false)
        #expect(claims.isClaimed(movie, by: .picture))
        #expect(claims.isClaimed(movie, by: .sound) == false)
    }

    @Test("removing a movie's last layer leaves running the input an unmuted strip hears")
    func removingTheLayerKeepsTheSound() {
        var claims = InputClaims()
        let stripStarts = claims.claim(movie, by: .sound)
        let layerStarts = claims.claim(movie, by: .picture)
        let removalStops = claims.release(movie, by: .picture)

        #expect(stripStarts)
        #expect(layerStarts == false)
        #expect(removalStops == false)
        #expect(claims.isClaimed(movie, by: .sound))
    }

    @Test("the input stops when the last pass lets go, and starts again on the next claim")
    func lastReleaseStops() {
        var claims = InputClaims()
        _ = claims.claim(movie, by: .picture)
        _ = claims.claim(movie, by: .sound)
        let firstReleaseStops = claims.release(movie, by: .sound)
        let lastReleaseStops = claims.release(movie, by: .picture)
        let nextClaimStarts = claims.claim(movie, by: .sound)

        #expect(firstReleaseStops == false)
        #expect(lastReleaseStops)
        #expect(nextClaimStarts)
    }

    @Test("an input one pass alone needs starts and stops with that pass, as before")
    func singleClaimant() {
        var claims = InputClaims()
        let microphone = InputID(rawValue: "mic")
        let unmuteStarts = claims.claim(microphone, by: .sound)
        let muteStops = claims.release(microphone, by: .sound)

        #expect(unmuteStarts)
        #expect(muteStops)
        #expect(claims.isClaimed(microphone, by: .sound) == false)
    }

    @Test("claiming twice starts once, and releasing an unheld claim stops nothing")
    func repeatsAreHarmless() {
        var claims = InputClaims()
        let firstClaimStarts = claims.claim(movie, by: .picture)
        let secondClaimStarts = claims.claim(movie, by: .picture)
        let unheldReleaseStops = claims.release(movie, by: .sound)
        let unknownReleaseStops = claims.release(InputID(rawValue: "never"), by: .picture)

        #expect(firstClaimStarts)
        #expect(secondClaimStarts == false)
        #expect(unheldReleaseStops == false)
        #expect(unknownReleaseStops == false)
        #expect(claims.isClaimed(movie, by: .picture))
    }

    @Test("forgetting an input that died drops every claim, so the next claim starts it")
    func forgetting() {
        var claims = InputClaims()
        _ = claims.claim(movie, by: .picture)
        _ = claims.claim(movie, by: .sound)
        claims.forget(movie)

        #expect(claims.isClaimed(movie, by: .picture) == false)
        #expect(claims.isClaimed(movie, by: .sound) == false)
        let nextClaimStarts = claims.claim(movie, by: .sound)
        #expect(nextClaimStarts)
    }

    @Test("claim sets compare equal only when every claim matches")
    func equality() {
        var first = InputClaims()
        var second = InputClaims()
        _ = first.claim(movie, by: .picture)
        _ = second.claim(movie, by: .picture)
        #expect(first == second)
        _ = second.claim(movie, by: .sound)
        #expect(first != second)
    }
}
