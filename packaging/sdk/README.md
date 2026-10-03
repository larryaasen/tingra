# TingraPlugInSDK

The SDK for building **host-tier plug-ins** for [Tingra](https://github.com/larryaasen/tingra),
the live streaming and production app for macOS. A host-tier plug-in is a bundle Tingra loads
into its engine at launch, in the app and in `tingra-cli` alike. It can add
inputs, generators, effects, outputs, and MCP tools through the same protocols
Tingra's own plug-ins use.

The SDK is two binary frameworks, `TingraPlugInKit` (the plug-in protocols) and
`TingraEventBus` (the event bus every plug-in reports through). Both are built
with Library Evolution, so a bundle built against one release keeps loading in
later Tingra releases with the same major version.

**Requirements:** Xcode 27.0 or later, macOS 15 or later, Apple silicon (arm64).

## Adding the SDK

In Xcode, add the package to your project:

```
https://github.com/@SDK_REPO@
```

Or, in a manifest:

```swift
.package(url: "https://github.com/@SDK_REPO@", from: "@VERSION@")
```

Then link the `TingraPlugInSDK` product into your bundle target.

## The copy Xcode embeds

Tingra has already loaded one copy of each kit before it loads your bundle, and
your bundle binds to that copy by its install name,
`@rpath/TingraPlugInKit.framework/Versions/A/TingraPlugInKit`. That shared copy
is what lets your types cross into Tingra: one `BundledPlugIn`, one `Input`, on
both sides.

Xcode also copies both frameworks into your bundle's `Contents/Frameworks`, as
it does for every package of binary frameworks, and offers no setting to stop
it. **Leave the copy alone.** Tingra never loads it, Xcode signs it with the
rest of the bundle, and Tingra does not report it. Do not add a runpath to
your bundle's own `Frameworks` folder for the kits, and do not build the kits
from source: a bundle works only when it is bound to Tingra's copy.

## The bundle

A plug-in is a macOS **Bundle** target (`CFBundlePackageType` `BNDL`) with the
wrapper extension `tingraplugin`: set **Wrapper Extension**
(`WRAPPER_EXTENSION`) to `tingraplugin`, so the product is
`MyPlugIn.tingraplugin`. Build it for arm64 with a macOS 15.0 deployment target.
**One bundle is one plug-in.**

Its entry point is the **principal class**: a class conforming to
`BundledPlugIn`, which Tingra creates once with `init()` and activates through
`activate(in:)`, exactly as it does a plug-in compiled into Tingra.

```swift
import TingraEventBus
import TingraPlugInKit

final class MyPlugIn: BundledPlugIn {
    let id = PlugInID(rawValue: "com.example.my-plug-in")
    let name = "My Plug-in"

    init() {}

    func activate(in context: PlugInContext) async throws {
        try await context.inputs.register(MyInput())
    }
}
```

### Info.plist

Tingra reads three keys before it runs any of the bundle's code:

| Key | Value |
|-----|-------|
| `NSPrincipalClass` | The principal class, qualified by its module: `MyPlugIn.MyPlugIn` |
| `com.moonwink.tingra.plug-in.id` | The plug-in's id. It must equal the principal class's `id` |
| `com.moonwink.tingra.plug-in.kit-version` | The kit version you built against: `@VERSION@` for this SDK, which is also `PlugInKitVersion.current` |

```xml
<key>NSPrincipalClass</key>
<string>MyPlugIn.MyPlugIn</string>
<key>com.moonwink.tingra.plug-in.id</key>
<string>com.example.my-plug-in</string>
<key>com.moonwink.tingra.plug-in.kit-version</key>
<string>@VERSION@</string>
```

Tingra refuses a bundle whose kit version it cannot load, with a message naming
both versions, instead of letting it fail inside dyld. From 1.0.0 on, a bundle
loads in any Tingra whose kit has the same major version and a minor at least
as new. Before 1.0.0 a minor version may break, so the major and minor must both
match. Update the key whenever you update the SDK.

## Installing

Tingra scans two folders once, at launch:

| Folder | For |
|--------|-----|
| `~/Library/Application Support/Tingra/Plug-ins/` | One account |
| `/Library/Application Support/Tingra/Plug-ins/` | Every account on the Mac (an installer `.pkg` puts bundles here) |

A new or changed bundle takes effect the next time Tingra opens, and the next
time each `tingra-cli` command runs. Symbolic links are followed, so you can link
your build product into the folder while you develop.

## Signing

Tingra checks a bundle's code signature before loading it.

- **Your own builds:** an ad-hoc signature is enough (`codesign --sign - MyPlugIn.tingraplugin`,
  or Xcode's **Sign to Run Locally**).
- **To distribute:** sign with your Developer ID Application identity and
  notarize. A bundle that arrived by download carries the quarantine attribute,
  and Tingra loads a quarantined bundle only if it is notarized.

## When a bundle does not load

`tingra-cli plug-ins` lists every plug-in Tingra loads, and for each bundle that
did not load, the reason and the fix (`unsigned`, `notNotarized`, `kitVersion`,
`duplicateID`, `idMismatch`, `noPrincipalClass`, `loadFailed`). In the app,
**Settings > Plug-ins** shows the same. Hold Shift while opening Tingra to open it
without the plug-ins you installed.

## License

MIT. See [LICENSE](LICENSE).
