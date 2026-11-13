// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// A general-purpose library for capturing one running application's sound on
// the Mac through Core Audio process taps (macOS 14.2+): lists the
// applications that have an audio process, taps the processes that belong to
// one of them — optionally muting the application on its own output device
// while the tap is held — and hands back copies of its audio stamped with
// host time. Standalone on purpose, like TingraUVC: it depends on no other
// Tingra package, so any Mac app can import it (ARCHITECTURE.md,
// "Application audio", A11).
let package = Package(
    name: "TingraApplicationAudio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraApplicationAudio", targets: ["TingraApplicationAudio"])
    ],
    targets: [
        .target(name: "TingraApplicationAudio"),
        .testTarget(name: "TingraApplicationAudioTests", dependencies: ["TingraApplicationAudio"]),
    ]
)
