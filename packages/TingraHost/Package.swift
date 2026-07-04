// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The host/core package: plug-in loader and lifecycle, registries, frame
// transport (master clock, program tick), session/state, secure storage,
// and authorization. The host has no feature a user would directly see
// (see ARCHITECTURE.md, "Engine model: host and plug-ins").
let package = Package(
    name: "TingraHost",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraHost", targets: ["TingraHost"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraHost",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraHostTests", dependencies: ["TingraHost"]),
    ]
)
