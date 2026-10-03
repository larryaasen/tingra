// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraPlugInSDK
//
//  Created by Larry Aasen on 2026-09-30.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The binary SDK for Tingra host-tier plug-in bundles (see README.md): the two
// plug-in kits as arm64 XCFrameworks, built with Library Evolution so a bundle
// keeps loading in newer Tingra releases.
//
// This file is rendered by scripts/release-sdk.sh in larryaasen/tingra from
// packaging/sdk/Package.swift, which carries @-delimited placeholders in place
// of the version and the checksums. Change the template there, never this copy.
//
// Link the product, never embed it: Tingra already loaded the one copy of each
// kit that every plug-in shares.
let package = Package(
    name: "TingraPlugInSDK",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraPlugInSDK", targets: ["TingraPlugInKit", "TingraEventBus"])
    ],
    targets: [
        .binaryTarget(
            name: "TingraPlugInKit",
            url: "https://github.com/@SDK_REPO@/releases/download/@VERSION@/TingraPlugInKit-@VERSION@.xcframework.zip",
            checksum: "@TINGRA_PLUG_IN_KIT_CHECKSUM@"
        ),
        .binaryTarget(
            name: "TingraEventBus",
            url: "https://github.com/@SDK_REPO@/releases/download/@VERSION@/TingraEventBus-@VERSION@.xcframework.zip",
            checksum: "@TINGRA_EVENT_BUS_CHECKSUM@"
        ),
    ]
)
