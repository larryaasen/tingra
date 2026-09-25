// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// A dynamic product compiled with Library Evolution, for the same reason as
// TingraPlugInKit (PLUGINS.md, Decision 22): the kit re-exposes these types to
// every plug-in, so a host-tier bundle must share the engine's one copy.
let package = Package(
    name: "TingraEventBus",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraEventBus", type: .dynamic, targets: ["TingraEventBus"])
    ],
    targets: [
        .target(name: "TingraEventBus", swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]),
        .testTarget(name: "TingraEventBusTests", dependencies: ["TingraEventBus"]),
    ]
)
