// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The plug-in protocol package: the stability contract third parties build
// against (see ARCHITECTURE.md, "Plug-in API stability and versioning").
// Its only dependency is the zero dependency event bus package, which is
// re-exposed to every plug-in.
let package = Package(
    name: "TingraPlugInKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraPlugInKit", targets: ["TingraPlugInKit"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus")
    ],
    targets: [
        .target(
            name: "TingraPlugInKit",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus")
            ]
        ),
        .testTarget(name: "TingraPlugInKitTests", dependencies: ["TingraPlugInKit"]),
    ]
)
