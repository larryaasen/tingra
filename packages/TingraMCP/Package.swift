// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The MCP/Control service: the hand-rolled MCP JSON-RPC layer, the engine
// daemon (`tingra-cli serve`), the transparent stdio↔socket proxy
// (`tingra-cli mcp`), and the first-party control tools that mirror the CLI
// surface. Speaks MCP verbatim on the wire but takes no third-party
// dependency — the JSON-RPC framing is a few hundred lines behind this seam
// rather than the official swift-sdk's SwiftNIO/swift-log/eventsource stack
// (see MCP.md, "Implementation: a hand-rolled JSON-RPC layer"). Depends on
// the host because the daemon owns the engine (registries, sessions); the
// tool seam itself lives in the plug-in protocol package.
let package = Package(
    name: "TingraMCP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraMCP", targets: ["TingraMCP"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
        .package(path: "../TingraHost"),
    ],
    targets: [
        // A tiny C shim exposing launchd's `launch_activate_socket`, which the
        // Swift Darwin overlay does not surface (see MCP.md, "Lifecycle").
        .target(name: "CTingraLaunchd"),
        .target(
            name: "TingraMCP",
            dependencies: [
                "CTingraLaunchd",
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
                .product(name: "TingraHost", package: "TingraHost"),
            ]
        ),
        .testTarget(name: "TingraMCPTests", dependencies: ["TingraMCP"]),
    ]
)
