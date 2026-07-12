// swift-tools-version: 6.3.3
//
//  Package.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The assembled SwiftUI/AppKit app (phase 3). Scaffolded at roadmap step 6:
// it takes shape around the proven engine — camera and display inputs
// composited by the Metal/Core Image compositor and shown live in an
// on-screen MTKView. Further production features (presets, shots,
// transitions, the audio mixer) arrive at step 7.
//
// Bundling into a signed, notarized `.app` with an embedded Info.plist
// (Camera/Microphone usage descriptions, Screen Recording) is a later
// packaging step, tracked alongside the CLI's distribution recipe — the
// scaffold here is an SPM executable that builds warning-clean.
//
// Because that unbundled executable is ad-hoc signed, macOS TCC pins its
// Screen Recording / Camera / Microphone grants to the build's cdhash and
// re-prompts on every rebuild. `scripts/sign-app.sh` re-signs with a stable
// code-signing identity so a single grant persists across rebuilds — the
// `tingra` Xcode scheme runs it as a build post-action, and
// `scripts/run-app.sh` builds, bundles (a minimal `tingra.app` with the
// Camera/Microphone Info.plist usage descriptions), signs, and launches the
// app for command-line runs. Both are dev conveniences, distinct from the
// release signing/notarization pipeline.
let package = Package(
    name: "tingra",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "tingra", targets: ["Tingra"])
    ],
    dependencies: [
        .package(path: "../../packages/TingraCapturePlugIns"),
        .package(path: "../../packages/TingraComposition"),
        .package(path: "../../packages/TingraEventBus"),
        .package(path: "../../packages/TingraGeneratorPlugIns"),
        .package(path: "../../packages/TingraHost"),
        .package(path: "../../packages/TingraOutputPlugIns"),
        .package(path: "../../packages/TingraPlugInKit"),
    ],
    targets: [
        .executableTarget(
            name: "Tingra",
            dependencies: [
                .product(name: "TingraCapturePlugIns", package: "TingraCapturePlugIns"),
                .product(name: "TingraComposition", package: "TingraComposition"),
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraGeneratorPlugIns", package: "TingraGeneratorPlugIns"),
                .product(name: "TingraHost", package: "TingraHost"),
                .product(name: "TingraOutputPlugIns", package: "TingraOutputPlugIns"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ],
            resources: [
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(name: "TingraTests", dependencies: ["Tingra"]),
    ]
)
