// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraJSONRPC
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

let package = Package(
    name: "TingraJSONRPC",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraJSONRPC", targets: ["TingraJSONRPC"])
    ],
    dependencies: [
        // For `JSONValue` only: the one JSON model every Tingra package shares.
        .package(path: "../TingraPlugInKit")
    ],
    targets: [
        .target(
            name: "TingraJSONRPC",
            dependencies: [
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit")
            ]
        ),
        .testTarget(name: "TingraJSONRPCTests", dependencies: ["TingraJSONRPC"]),
    ]
)
