// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// No default main-actor isolation, unlike the app target: XPC calls exported
// objects and handlers on the connection's own queue, and the Phase 0 spike
// showed an inferred main-actor requirement trapping on delivery
// (PLUGINS.md, "Spike findings", row 3). The UI-facing types say
// `@MainActor` explicitly instead.
let package = Package(
    name: "TingraAppPlugInKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraAppPlugInKit", targets: ["TingraAppPlugInKit"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
        .package(path: "../TingraJSONRPC"),
    ],
    targets: [
        .target(
            name: "TingraAppPlugInKit",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
                .product(name: "TingraJSONRPC", package: "TingraJSONRPC"),
            ]
        ),
        .testTarget(name: "TingraAppPlugInKitTests", dependencies: ["TingraAppPlugInKit"]),
    ]
)
