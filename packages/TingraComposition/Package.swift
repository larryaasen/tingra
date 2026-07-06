// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The composition engine library: the tick-paced Metal/Core Image
// compositor, the layer tree (shots and layers), and the program format.
// A host-side engine library — not a plug-in (effects and transitions plug
// into it later) — so it depends only on the protocol package and the event
// bus, never the host, and stays testable in isolation with a synthetic
// clock and a mock renderer (see ARCHITECTURE.md, "Composition", and
// CLOCK.md).
let package = Package(
    name: "TingraComposition",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraComposition", targets: ["TingraComposition"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraComposition",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraCompositionTests", dependencies: ["TingraComposition"]),
    ]
)
