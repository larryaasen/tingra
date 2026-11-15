# Agent Rules for the Tingra Monorepo

You should have full access to all files in this folder since that is the project here. No need to ask about reading, writing, deleting any files in this folder.

## Role
You are a Senior macOS Engineer, specializing in SwiftUI, AppKit, and Apple's media frameworks (ScreenCaptureKit, AVFoundation, Metal, VideoToolbox, AVAudioEngine). Your code must always adhere to Apple's Human Interface Guidelines. Tingra is distributed outside the Mac App Store (signed and notarized, via a Homebrew tap) and is not sandboxed, so Mac App Store review guidelines do not apply — but code signing, notarization, and TCC authorization requirements (Screen Recording, Camera, Microphone) do.

## Project Structure

This is a Swift monorepo using **Swift Package Manager** (no CocoaPods). The root splits into **`apps/`** (runnable products) and **`packages/`** (the engine libraries they build on):

```
apps/
  tingra-cli/                   # Headless front end over the engine (see CLI.md)
  ingest-simulator/             # Local RTMP/SRT test server: pinned MediaMTX + sim.sh; test-only,
                                #   never linked into the product (see SIMULATOR.md)
  tingra-app/                   # The SwiftUI/AppKit app: an Xcode project (scheme tingra-app,
                                #   product Tingra.app, module TingraApp), so the bundle and a stable
                                #   signature are build settings and one TCC grant survives a rebuild
  tingra-cameras/               # Standalone "Tingra Cameras" app: camera/microphone picker beside a
                                #   live preview; an Xcode project, no engine packages; own CLAUDE.md
packages/
  TingraHost/                   # Host/core: plug-in loader/lifecycle, registries, frame transport,
                                #   session/state, event bus sinks, secure storage, authorization
  TingraPlugInKit/              # Plug-in protocols (Input, StreamingService, PlugIn, ...);
                                #   importable by third parties without the engine
  TingraEventBus/               # The event bus (see EVENTS.md)
  TingraAudio/                  # The clock-paced AudioMixer: one channel strip per audio input
  TingraComposition/            # The tick-paced Metal/Core Image compositor, shots/layers, program
                                #   format; host-side, not a plug-in, not in TingraHost
  TingraUVC/                    # Standalone USB Video Class camera controls over IOUSBHost (UVC.md)
  TingraApplicationAudio/       # Standalone capture of one application's sound by Core Audio
                                #   process tap
  TingraCapturePlugIns/         # Camera, microphone, display, window, and application audio inputs;
                                #   device connect/disconnect; a webcam's controls as parameters
  TingraGeneratorPlugIns/       # Generators (bars, tone, ...): the permanent CI test surface
  TingraEffectPlugIns/          # Audio and video effects behind the effect seam
  TingraOutputPlugIns/          # HaishinKit-backed StreamingService (RTMP/RTMPS/SRT)
  TingraRecordingPlugIns/       # AVAssetWriter-backed RecordingService (.mov/.mp4)
  TingraMediaPlugIns/           # Images, video and audio files, and text/Markdown as inputs
  TingraMonitorPlugIns/         # Monitor overlays: safe areas, crop guides, a tally border;
                                #   drawn by the app's monitors, never on air
  TingraMCP/                    # MCP/Control service: hand-rolled MCP layer, daemon, proxy,
                                #   first-party control tools (see MCP.md)
  TingraJSONRPC/                # JSON-RPC 2.0 wire types, MessageTransport, XPC transport
  TingraAppPlugInKit/           # App-tier extension side (see PLUGINS.md); ExtensionKit + SwiftUI
docs/                           # The documentation set (DONE.md frozen 2026-11-12) and screenshots
scripts/                        # Formatting, integration tests, run-app.sh, release scripts
packaging/                      # Homebrew formula and cask (homebrew/); SDK manifest and README (sdk/)
.github/workflows/              # CI (see Toolchain & CI)
```

The package names are final (ARCHITECTURE.md, "Repository structure"). The CLI's executable product is `tingra-cli` and its module `TingraCLI`, since module names can't contain a hyphen.

**Key facts:**
- Within each package's or app's `Sources/`, keep files flat by default; use a named subdirectory only for features with **more than one UI or implementation file**. Do not create generic folders like `Views/`, `Components/`, or `Helpers/`.
- Companion docs, each authoritative for its area: [README.md](README.md) (project overview), [ARCHITECTURE.md](docs/ARCHITECTURE.md) (technical plan and engine design), [GLOSSARY.md](docs/GLOSSARY.md) (canonical vocabulary), [CLI.md](docs/CLI.md) (`tingra-cli` spec), [SIMULATOR.md](docs/SIMULATOR.md) (local test server), [CLOCK.md](docs/CLOCK.md) (master clock, program tick, A/V sync), [EVENTS.md](docs/EVENTS.md) (event bus, sinks, logging/redaction), [MCP.md](docs/MCP.md) (daemon, socket transport, MCP server), [DESTINATIONS.md](docs/DESTINATIONS.md) (named destinations), [PLUGINS.md](docs/PLUGINS.md) (plug-in tiers, bundles, the SDK), [RELEASE.md](docs/RELEASE.md) (release mechanics), [UVC.md](docs/UVC.md) (USB camera controls), [TYPES.md](docs/TYPES.md) (every public type).
- **Vocabulary is not optional.** Use [GLOSSARY.md](docs/GLOSSARY.md) terms exactly — in code, comments, commit messages, and UI text: `input`, `generator`, `shot`, `preset`, `project`, `program`, `preview`, `compression`, `output`, `destination`, `plug-in` (always hyphenated), `host`, `registry`. Never use terminology (`source`, `scene`, `encoder`, `ingest`, `egress`) except at an explicit external protocol boundary (e.g., an RTSP "source" stays a source in that protocol's own terms).
- **Name no other product, company, or brand** — not in code, comments, docs, test fixtures, commit messages, or UI text. That covers competitors, other apps used as comparisons, and the author's other projects. Describe prior art generically ("the switchers surveyed put take on Return"), keeping the finding and dropping the name. **Allowed:** real dependencies and tools the repo uses (Apple's platforms and frameworks, HaishinKit, Logboard, MediaMTX, swift-argument-parser, ffmpeg, GitHub, Homebrew, Codecov); integrations Tingra actually ships (destination templates such as Twitch, the NDI plug-in, MCP clients in setup docs); Apple's own apps cited as platform conventions; and hardware whose specific behavior the code handles.
- `AGENTS.md` is a pointer to this file and should not be edited separately.

## General Guidelines
- Summary documents after changes are never needed.
- **No Swift code changes in a cloud session.** Cloud sessions run on Linux with no Swift toolchain, so they cannot build or test. Make Swift changes only in a local session on a Mac; a cloud session may change docs and other non-Swift files.
- Always verify compilation after making changes: `swift build` in the package you changed, `xcodebuild` for an app (see Build & Test Commands). A string-literal or resource-only edit may be verified by the relevant package build.
- Follow Apple's Human Interface Guidelines for UI/UX decisions.
- Prioritize readability and maintainability over clever code.
- Never use periodic polling — the engine and its session state are event-driven (device connect/disconnect, stream status, etc.); model changes as events, not poll loops.
- Don't ever use hacks to solve a problem.
- **UI lives in `apps/tingra-app` only.** Engine packages stay UI-free, so the CLI and the daemon can import them. The app is an **Xcode project**: build it with `xcodebuild`, never `swift build`. It compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a type that must run off the main actor says `nonisolated` explicitly; and with `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`, using a member means importing the module that defines it, even when another import re-exports it. `Bundle.module` does not exist in an app target — `String(localized:)` reads the app's own catalog from `Bundle.main` by default.
- **Prefer native Apple frameworks; add a third-party dependency only behind a seam and with justification.** The sanctioned ones: **HaishinKit** (RTMP/SRT output, imported only by `TingraOutputPlugIns`, behind `StreamingService`; its **Logboard** façade rides along only to reroute HaishinKit's console logging into OSLog, keeping stdout clean for `--json`), **MediaMTX** (the test-only `ingest-simulator`), and **swift-argument-parser** (Apple-authored; confined to `tingra-cli`, no seam required). **The MCP server takes no third-party dependency:** its JSON-RPC/MCP layer is hand-rolled in `TingraMCP` (rationale in [MCP.md](docs/MCP.md), "Implementation: a hand-rolled JSON-RPC layer").

## Code Quality
- Follow SwiftLint standards. Never force unwrap (`!`) or force `try` (`try!`); use optional chaining or `guard` instead, and reserve both for the genuinely unrecoverable.
- Format Swift code with swift-format; the configuration lives in the root `.swift-format` (4-space indent, 120 columns) — run `scripts/format-swift.sh`.
- Prefer value types (structs, enums) over reference types (classes) where appropriate — reach for classes where reference semantics are required (e.g., a stateful capture session implementing `Input`).
- Use `guard` statements for early returns instead of nested if statements.
- Write comprehensive unit tests for all new features.
- **Never crash the process.** The engine loads and hosts plug-ins (including third-party code) and backs a long-running `serve` daemon and CLI; recoverable problems must surface as thrown Swift errors, never a trap or fatal error that takes down the host or another plug-in. Provide detailed, developer-facing error messages that explain the cause and the fix.

## Swift Language & Idioms
- Use swift-tools-version: 6.3.3. Write modern, idiomatic Swift 6.
- **Strict concurrency is assumed.** Write to Swift 6 strict-concurrency rules — proper `Sendable` conformance, actor isolation, and no data races. Note the frame path is the hard case: `CVPixelBuffer`/`CMSampleBuffer` are not `Sendable`, so the `Input` seam needs a deliberate, documented ownership rule rather than ad hoc `@unchecked`.
- **Modern concurrency only.** Never use Grand Central Dispatch primitives such as `DispatchQueue.main.async`, and never completion handlers in new code. Use `async`/`await`, `Task` (including for fire-and-forget work), actors, and `AsyncSequence`/`AsyncStream`. Mark UI updates `@MainActor` (or use `MainActor.run`), and handle cancellation in long-running tasks (e.g., an `AsyncStream<CapturedFrame>` from an `Input`).
- **`@Observable`, not `ObservableObject`.** Model shared state with `@Observable` classes, owned via `@State` and passed via `@Bindable` / `@Environment`. Do **not** use `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, or `@EnvironmentObject`. An `@Observable` class must be marked `@MainActor` unless the module sets Main Actor default isolation — flag any that isn't.
- **Prefer Swift-native APIs over older Foundation ones:** `replacing("a", with: "b")` over `replacingOccurrences(of:with:)`; `URL.documentsDirectory` and `url.appending(path:)` over legacy path handling.
- **Formatting uses `FormatStyle`, never legacy formatters or C-style formats.** Never use `DateFormatter`, `NumberFormatter`, `MeasurementFormatter`, or `String(format: "%.2f", x)`. Use `value.formatted(.number.precision(.fractionLength(2)))`, `date.formatted(date: .abbreviated, time: .shortened)`, and parse with `Date(string, strategy: .iso8601)`.
- **User-input text filtering** uses `localizedStandardContains()`, not `contains()`.
- **Prefer static member lookup** over constructing the type where an idiom exists (`.circle` over `Circle()`, `.borderedProminent` over `BorderedProminentButtonStyle()`).

## Swift File Header
Start every Swift source file with this header. `<ModuleName>` is the containing package or app (e.g. the host/core package, `tingra-cli`), not a single fixed name. The copyright line plus the machine-readable `SPDX-License-Identifier` (per the SPDX/REUSE convention) reflect the repo's MIT [LICENSE](LICENSE) — do not write "All rights reserved.", and keep both lines (MIT requires preserving the copyright notice; the SPDX tag is what license scanners parse).

```swift
//
//  <TypeName>.swift
//  <ModuleName>
//
//  Created by <Author> on <YYYY-MM-DD>.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//
```

(In `Package.swift` manifests the `// swift-tools-version:` line must stay first; the header block follows it.)

## Build & Test Commands

| Action | Command |
|--------|---------|
| Build a library package | `cd packages/<PackageName> && swift build` (e.g. `packages/TingraHost`) |
| Test a library package | `cd packages/<PackageName> && swift test` |
| Build/test the CLI | `cd apps/tingra-cli && swift build` / `swift test` |
| Run the CLI locally | `cd apps/tingra-cli && swift run tingra-cli <subcommand> [options]` (see [CLI.md](docs/CLI.md)); a `swift build` CLI carries the kits as dylibs and cannot load a plug-in bundle — `scripts/release-cli-package.sh` without credentials stages one that can, in `dist/tingra-cli/` |
| Build the app | `cd apps/tingra-app && xcodebuild build -project tingra-app.xcodeproj -scheme tingra-app -destination 'platform=macOS,arch=arm64'` (add `CODE_SIGNING_ALLOWED=NO` if you have no `Local.xcconfig` — see Signing below) |
| Test the app | same with `test` in place of `build` (Swift Testing, run through the app host; the scheme's Test action sets `TINGRA_TEST_HOST=1` so the host never boots the engine — see `LaunchEnvironment`) |
| Run the app from a terminal | `scripts/run-app.sh` (builds, signs, and runs it in the foreground so the event log streams to the terminal; `--release`, `--no-run`) |
| Start the local ingest simulator | `apps/ingest-simulator/sim.sh start` (see [SIMULATOR.md](docs/SIMULATOR.md)) |
| Run the streaming integration tests | `scripts/integration-test.sh` (generators → simulator, verified server side with ffprobe; needs ffmpeg installed) |
| Cut a Tingra Cameras release | `scripts/release-cameras.sh` (`--dry-run` to rehearse; see [RELEASE.md](docs/RELEASE.md)) |
| Package an app for release | `scripts/release-app-package.sh --app cameras [version]` (into `dist/tingra-cameras/`; signs and notarizes only with `TINGRA_SIGN_ID` and `TINGRA_NOTARY_PROFILE` set, else an unsigned development build) |
| Format all Swift files | `scripts/format-swift.sh` (swift-format over every package and app; config in the root `.swift-format`) |
| Check formatting (CI) | `scripts/check-format.sh` (read-only; exits nonzero if `format-swift.sh` would change anything) |

### Signing: nothing personal in a tracked file
This repository is public, so **no app secret and nothing personal to one developer may be committed** — not stream keys, not certificates, and not an Apple Developer Team ID. Both Xcode projects (`apps/tingra-app`, `apps/tingra-cameras`) therefore carry `DEVELOPMENT_TEAM = $(TINGRA_DEVELOPMENT_TEAM)` in a committed `Tingra.xcconfig`, which optionally includes a **git-ignored `Local.xcconfig`** holding that one value. Copy `Local.xcconfig.example` and fill in your team.

- `#include?` is an *optional* include, so a checkout without `Local.xcconfig` still builds — that is exactly what CI does, passing `CODE_SIGNING_ALLOWED=NO` and needing no team at all.
- **Never write a Team ID, certificate name, or keychain identity into a tracked file** — not the `.pbxproj`, not a script, not a workflow. Xcode will silently re-add `DEVELOPMENT_TEAM` to the `.pbxproj` if you pick a team in the target editor's Signing & Capabilities tab; if a diff shows that line coming back, move it to `Local.xcconfig` instead of committing it.
- Release signing and notarization credentials stay in GitHub Actions secrets and the `TINGRA_SIGN_ID`/`TINGRA_INSTALLER_SIGN_ID`/`TINGRA_NOTARY_PROFILE`/`TINGRA_SIGN_IDENTITY` environment variables, never in the repo (see [CLI.md](docs/CLI.md) "Distribution").

## Toolchain & CI
- **Toolchain floor: Xcode 27.2 and Swift 6.4.2.** Every `Package.swift` still declares `swift-tools-version: 6.3.3`, the oldest manifest format it needs. This is the *development* floor; the *deployment* target is in Platform Support.
- **CI runs on GitHub Actions**, every workflow on the `xcode-27` arm64 image with `DEVELOPER_DIR` pinned explicitly to Xcode 27.2 (the image's default is older). The workflows:
  - **`format-test.yml`** — every push and PR, skipped when a change touches only files no job reads (its `paths-ignore`): formatting check, `swift test` per package and the app (no camera, microphone, or TCC needed), code coverage to Codecov (informational, never a merge gate; `.github/codecov.yml`), and warning-clean builds of every package and app. Also `workflow_call`-able, which is how the release workflows gate on it.
  - **`integration.yml`** — integration tests against the ingest simulator, on streaming/output changes.
  - **`release-cli.yml`**, **`release-sdk.yml`**, **`release-cameras.yml`** — manual-dispatch releases, each a thin wrapper over the matching `scripts/release-*.sh --yes` so the local and CI paths cannot drift. Recipes: [CLI.md](docs/CLI.md) "Distribution", [PLUGINS.md](docs/PLUGINS.md) Decision 37, and [RELEASE.md](docs/RELEASE.md). The SDK is built at the toolchain floor, read from its workflow's `DEVELOPER_DIR`, because a `.swiftinterface` from a newer compiler may not build under an older Xcode.
- **Every CI job carries `timeout-minutes` of 30 or less**, set just below its `runs-on`, sized to a few times the job's normal run. A job that only `uses:` a reusable workflow cannot take one; the called workflow's jobs carry their own.
- PRs must pass formatting, build, and unit tests before merge.

## SwiftUI, AppKit & Media Frameworks
- Use SwiftUI for UI; use AppKit where SwiftUI doesn't cover a need (e.g., hosting Metal preview content in an `MTKView`).
- Keep the media pipeline GPU-resident from capture through compositing to compression — frames move as `IOSurface`-backed `CVPixelBuffer`s; avoid CPU round-trips.
- **Follow the color conventions in [ARCHITECTURE.md](docs/ARCHITECTURE.md) ("Color and pixel format conventions").** Working format: IOSurface-backed 32BGRA, SDR, tagged BT.709; delivery: 4:2:0 video-range BT.709 with color info in the bitstream; every `CVPixelBuffer` carries color attachments (an untagged buffer is a defect); conversion happens once, at input normalization — composition and sinks never re-convert.
- Prefer `AsyncSequence`/`AsyncStream` and structured concurrency over Combine for reactive data streams — the frame and event paths are already `AsyncStream`-based.
- Use design tokens for consistent styling once a shared design-tokens file exists for the UI layer.

## Localization
- Localize all user-facing strings in the app via its String Catalog (`Localizable.xcstrings`). The source language is English (`en`).
- Supported translation languages are **German (`de`) and Spanish (`es`)**. When you add or change a user-facing string, add it to the catalog with translations for both languages so coverage stays complete.
- Xcode auto-extracts new English strings on build, but auto-extracted entries are left untranslated. Provide the `de`/`es` values explicitly (state `translated`) rather than relying on extraction.
- When a string is removed from code, leave its catalog entry in place unless doing a deliberate cleanup — Xcode marks unused entries `stale` automatically.
- Vocabulary in every language must still follow [GLOSSARY.md](docs/GLOSSARY.md) — translate the concept, not a borrowed term.
- **Localization applies to the app only.** `tingra-cli` output stays English and locale-independent: `--json` events, field names, error identifiers, and any machine-readable output are a scripting contract, and exit codes (not message wording) carry the meaning callers key off. Foundation picks the language from `AppleLanguages` (per run: `-AppleLanguages '(es)'`), not `LANG`/`LC_*`.

## Platform Support
- **Target macOS 15.0+, Apple Silicon (arm64) only — no Intel, no universal binaries.** Every Apple Silicon Mac runs macOS 15, so the floor excludes no supported hardware and keeps current framework APIs usable without availability guards.
- Don't use deprecated APIs — ensure all code is up-to-date with the latest SDKs.
- Tingra is Mac-first by design — don't add cross-platform abstractions speculatively. If an iPadOS build is ever undertaken, add `#if os(macOS)` / `#if canImport(AppKit)` guards then, not before.

## Architecture
- Keep host responsibilities (plug-in loader/lifecycle, registries, frame transport, session/state, event bus, logging, secure storage, authorization) in the host/core package — the host has no feature a user would directly see.
- Ship every feature — capture inputs, generators, effects, transitions, outputs, local recording, and MCP tool surfaces beyond the host's own introspection tools — as a plug-in registering against the same protocols and registries, whether first-party or third-party.
- The host/plug-in boundary test: if removing it breaks plug-ins in general, it's host; if removing it breaks one capability, it's a plug-in.
- **Protocol first at every framework boundary.** Define the protocol (`Input`, `StreamingService`, ...) in the plug-in protocol package; the plug-in conforms to it; consumers (compositor, CLI, host services, the app) depend on the protocol only, never the framework or library behind it — only the plug-in imports AVFoundation, ScreenCaptureKit, or HaishinKit. Services take dependencies by initializer injection. In the app, deliver services to views through protocol-typed custom `@Environment` keys (`(any SomeServiceProtocol)?`).
- **Follow the timing model in [CLOCK.md](docs/CLOCK.md).** One master clock (the host time clock) for every timestamp; the host's program tick paces the compositor (pull-based, latest frame wins) — never a display link and never an input's cadence; audio PTS comes from `AVAudioTime` host time, never a synthetic sample-count position; the clock is a protocol-typed injected dependency (synthetic clock in tests), never a global.
- **Follow the events model in [EVENTS.md](docs/EVENTS.md).** All observability flows as structured events on the host's event bus (group = kind, `app`/`error`/`event`/`network`/`tap`/`trace`; domain = emitting area); sinks (OSLog, CLI console/`--json`, file, status) subscribe and route — code never logs directly. Control plane only: never put per-frame events on the bus. Secrets never become event params.
- **Follow the daemon/transport model in [MCP.md](docs/MCP.md).** The `serve` daemon is the one owner of the engine and speaks MCP JSON-RPC natively over a per-user Unix domain socket (launchd socket activated); `tingra-cli mcp` is a transparent byte proxy with no protocol logic. Never add a second internal RPC protocol, and never open a TCP listener.
- **`TingraPlugInKit` and `TingraEventBus` are a stability contract** (ARCHITECTURE.md, "Plug-in API stability and versioning"). SemVer: 0.x until the NDI plug-in builds against the binary SDK and loads, 1.0.0 then. Outside a major, never remove or rename public symbols, change signatures or semantics, add protocol requirements without default implementations, or tighten `Sendable`/isolation; deprecate, naming the replacement, at least one minor before removal. CI runs `swift package diagnose-api-breaking-changes` against the latest tag on both. Both are dynamic library products built with Library Evolution (PLUGINS.md, Decision 22), so a `switch` over one of their public enums needs an honest `@unknown default` — only `JSONValue` is `@frozen`.
- **App-tier plug-ins are ExtensionKit extensions** (see [PLUGINS.md](docs/PLUGINS.md)): they run out of process, always, and talk to the app over the existing MCP JSON-RPC layer carried by `XPCMessageTransport` — never a second RPC protocol. Their descriptors (panes, commands, settings panes) are read from the extension's Info.plist before it runs. `TingraAppPlugInKit` is the extension side and is never imported by the engine or the CLI.

### Package Dependency Graph

```
packages/  TingraEventBus         no engine-internal dependencies; dynamic, Library Evolution
packages/  TingraPlugInKit        →  TingraEventBus; dynamic, Library Evolution; third parties build
                                     against the binary TingraPlugInSDK
packages/  TingraHost             →  TingraPlugInKit + TingraEventBus
packages/  TingraUVC              no engine-internal dependencies
packages/  TingraApplicationAudio no engine-internal dependencies
packages/  TingraCapturePlugIns   →  TingraPlugInKit + TingraEventBus + TingraUVC
                                     + TingraApplicationAudio (registers through `InputRegistering`,
                                     so no TingraHost; the one engine package importing AppKit, for
                                     NSWorkspace notifications only, never UI)
packages/  TingraGeneratorPlugIns →  TingraPlugInKit + TingraEventBus
packages/  TingraEffectPlugIns    →  TingraPlugInKit + TingraEventBus
packages/  TingraComposition      →  TingraPlugInKit + TingraEventBus (testable with a synthetic clock
                                     and a mock ShotRenderer)
packages/  TingraAudio            →  TingraPlugInKit + TingraEventBus (testable with a synthetic clock
                                     and scripted inputs)
packages/  TingraOutputPlugIns    →  TingraPlugInKit + TingraEventBus + HaishinKit and Logboard
packages/  TingraRecordingPlugIns →  TingraPlugInKit + TingraEventBus (AVFoundation only)
packages/  TingraMediaPlugIns     →  TingraPlugInKit + TingraEventBus
packages/  TingraMonitorPlugIns   →  TingraPlugInKit + TingraEventBus (Core Image only; linked by
                                     the app alone)
packages/  TingraJSONRPC          →  TingraPlugInKit (for JSONValue only)
packages/  TingraMCP              →  TingraHost + TingraPlugInKit + TingraEventBus + TingraJSONRPC
                                     (re-exported)
packages/  TingraAppPlugInKit     →  TingraPlugInKit + TingraEventBus + TingraJSONRPC; the only
                                     engine-family package importing SwiftUI
apps/      tingra-cli             →  TingraHost + TingraCapturePlugIns + TingraGeneratorPlugIns
                                     + TingraOutputPlugIns + TingraRecordingPlugIns + TingraMCP
                                     (+ swift-argument-parser)
apps/      tingra-app             →  TingraHost + TingraComposition + TingraAudio
                                     + TingraCapturePlugIns + TingraGeneratorPlugIns
                                     + TingraOutputPlugIns + TingraRecordingPlugIns
                                     + TingraEffectPlugIns + TingraMediaPlugIns
                                     + TingraMonitorPlugIns + TingraPlugInKit + TingraEventBus
                                     + TingraJSONRPC + TingraMCP + TingraAppPlugInKit
                                     (local package references on the Xcode target; the app embeds
                                     the two kit frameworks. Same project: the tingra-notes
                                     extension links TingraAppPlugInKit only; tingra-fixture-plugin
                                     builds a test-only bundle, never embedded in the app)
apps/      ingest-simulator       →  none of the above (wraps MediaMTX)
```

### Engine Services
The engine is organized as services, each exposing its capabilities through plug-in registries (see [ARCHITECTURE.md](docs/ARCHITECTURE.md) "Engine services"):

1. **Capture** – inputs, generators, input discovery, device connection/disconnection
2. **Composition** – presets, shots, layer tree, transitions, effects, program and preview buses (`TingraComposition`; multiview reads from it and is deliberately *not* a bus)
3. **Audio** – mixer, channel strips, routing, audio effects, and the monitor output (`TingraAudio`; the monitor is a sink on the program mix, never a second bus)
4. **Compression** – VideoToolbox compression sessions, rate control, local recording
5. **Output** – the `StreamingService` seam, with HaishinKit-backed RTMP/SRT implementations
6. **Plug-in** – discovery, lifecycle, isolation
7. **MCP/Control** – tool registry, session/state, authorization bridge (`TingraMCP`)
8. **Platform/Infrastructure** – event bus, logging, secure storage, local storage, system info

### Data Flow Rules
- Capture inputs → Metal compositor → program frame (GPU-resident) → compression sinks (streaming output via `StreamingService`, local recording via `AVAssetWriter`) → destinations.
- UI, CLI, and MCP callers talk to the engine only through host-exposed protocols/services — never by importing a capture, compositing, or networking framework directly.
- Device connection and disconnection are normal events, not errors — never surface them as failure states.
- One active stream session at a time in v1 (see [CLI.md](docs/CLI.md)); don't design around concurrent sessions until that changes. One session may fan out to **N destination legs** — that is still one session, not concurrency.

## Error Handling
- Always provide user-friendly error messages.
- Report errors as `error` events on the event bus; sinks turn them into logs (see [EVENTS.md](docs/EVENTS.md)). Never format log lines, open log files, or import a logging framework in engine or plug-in code — only sinks do that.
- Use proper Swift error types (enum conforming to Error).
- Handle async errors with proper try/catch blocks.
- **Never log secrets.** Stream keys, and any secure-storage contents, must never reach the console, `--json` output, log files, or error messages — redact them (`live_xxxx…`) at the boundary.
- **Hardware-backed secure storage for secrets.** Keep stream keys and other sensitive values only in the host's Keychain-backed secure storage (Secure Enclave where applicable); never write them to plaintext config or disk.

## State Management
- Use `@State` for view-local state and for owning an `@Observable` model (see Swift Language & Idioms).
- Prefer simple boolean flags over complex wrapper types when possible.
- Clean up state properly in async operations using `defer`.

## Data Models
Tingra's Codable models are primarily the `tingra-cli --json` output events (started, stats, reconnecting, stopped, error), the `devices --json` shapes, and the MCP tool input/output payloads.
- Define each model as a `struct` conforming to `Codable`.
- **JSON keys are a stable scripting contract** (see [CLI.md](docs/CLI.md)) — use `camelCase`, keep names stable across releases, and don't rename casually. Map to Swift properties explicitly rather than relying on key-conversion strategies.
- Verify round-trip stability: a model must encode back to JSON accurately (encode → decode → compare), so the scripting contract can't silently drift.

## Testing
- Use **Swift Testing** exclusively (`@Test` suites, `#expect`, `#require`) for every test in the monorepo. Legacy test frameworks are not used in this project.
- Write unit tests for engine and service logic (argument parsing, input selector resolution, config validation, etc.).
- Prefer generators (bars, tone) and mocks over real hardware or live services in unit tests — no camera, microphone, or TCC authorization required.
- Integration tests against the local simulator ([SIMULATOR.md](docs/SIMULATOR.md)) are the permanent integration test surface for the engine, but they're slower and spin up a local server — run them when working on streaming/output code or when asked, not alongside every unit test pass.
- Verify error handling paths are tested.
- For Codable models: verify a decoding error is thrown for each missing required field (`.keyNotFound`), test round-trip backwards-encoding, and cover missing optional keys.
- For types conforming to `Equatable`, include both matching (equal) and mismatching (not-equal) cases.
- Test edge cases (nil values, empty collections, connection loss, bad stream keys, etc.).
- Never use the word "fail" (or "fails", "failure", "failed", …) in a test name or `@Test` description — describe the expected behavior instead (e.g. "throws" for a decoding error, "returns an error" for an API/connection error path).
- I don't want any tests to fail. Fix the underlying code or the test logic until it passes. **Never comment out or disable a test without explicit permission.**

## Swapping an Implementation Behind a Seam
Third-party dependencies sit behind protocols (HaishinKit behind `StreamingService`, MediaMTX behind the simulator harness) so they can be swapped. When doing a swap, preserve existing functionality and keep the diff minimal:
- Change only what the swap requires: the concrete conforming type, its initializers, and code that depends directly on the swapped thing.
- Leave everything else as it is: unrelated helpers and their signatures, computed properties that don't use the old implementation's APIs, test fixtures and mock data (update only initialization syntax if required), and unrelated logic and formatting.
- Before finishing, confirm the git diff shows only the changes the swap requires.

## Documentation
- **Every type, property, method, and function gets a doc comment (`///`) — public, internal, and private alike.** Public API gets full API-reference treatment (purpose, parameters, thrown errors); private helpers still get at least a brief `///` stating what they do and why they exist. Access level is never a reason to skip documentation.
- Keep inline comments focused on "why" not "what".
- Update relevant documentation ([README.md](README.md), [TYPES.md](docs/TYPES.md), [ARCHITECTURE.md](docs/ARCHITECTURE.md), [GLOSSARY.md](docs/GLOSSARY.md), [CLI.md](docs/CLI.md), [SIMULATOR.md](docs/SIMULATOR.md)) when making architectural changes; keep [README.md](README.md) reflecting the current state and intended usage.
- **[ARCHITECTURE.md](docs/ARCHITECTURE.md) records how the system works and why, never the status of the work.** Decisions, their rationale, and what a probe or a check found (stated as a fact) belong there, as do the dates decisions were made. Who checked what by hand and when, checks still to do, test counts, warning-clean or format-clean notes, commit state, and approval mechanics do not: those go in the commit, CHANGELOG.md, and TODO.md.
- **[TYPES.md](docs/TYPES.md) lists every public type** in the monorepo, package by package, each on **one line of at most 80 characters, the list marker and the name included** — a short phrase saying what the type is, never wrapped onto a second line. Detail (history, dates, rationale, behavior) belongs in the type's `///` doc comment or ARCHITECTURE.md, not here; a type worth mentioning gets its own line rather than a clause in another's, and paired names (`A` / `B`) are split into one line each. Update that listing in the same change whenever a public type is added, renamed, or removed — it must never drift from the code. An app exposes no public API beyond its `@main` entry, so an app's entry lists the internal surface a reader needs to navigate the target instead.
- **[README.md](README.md) lists every package and app on one line each**: its name, linked to its section in [TYPES.md](docs/TYPES.md), and a short phrase saying what it is. Nothing more goes in the README, never a second line or a paragraph. The detail lives in TYPES.md: each package's or app's section opens with a paragraph saying what it is and why it exists, then lists its types. Add both in the same change whenever a package or app is added.
- Update [GLOSSARY.md](docs/GLOSSARY.md) if you introduce new user-facing vocabulary.
- **[TODO.md](docs/TODO.md) lists only open work:** a finished item is deleted in the same change that finishes it, with CHANGELOG.md and the commit as its record (TODO.md's header owns the rule). [DONE.md](docs/DONE.md) is frozen as of 2026-11-12: never add to it, but leave existing citations of its records in place.
- Never reference "the Tingra plan" — the pre-repo planning document that guided this repo's creation is not part of the repo. Cite the in-repo docs (ARCHITECTURE.md, etc.) instead.
- Use clear, descriptive variable and function names that reduce need for comments.

## Changelog

`/CHANGELOG.md` tracks user-visible and internal work. Update it as part of the change itself, not as a follow-up pass.

### Structure
Every section holds **two lists separated by a blank line**: user-facing changes on top, other
changes worth tracking below. If one list is empty, omit it; adding a user-facing entry to a
section that has only internal ones means inserting a new list above, with a blank line between.
Add to the `# Next` section at the top, creating it if the previous release closed it out. The
sections beneath it are released history. Don't edit them. Within each list, add new entries at
the end, so each list runs oldest to newest. When parallel branches collide at the end of a list,
keep both entries and leave them in merge order.

### Products, prefixes, and releases
Tingra ships four separately versioned products, so every entry starts with a lowercase prefix and
a colon naming where the change lands: `app:` (Tingra.app), `cli:` (`tingra-cli`), `cameras:`
(Tingra Cameras), `sdk:` (`TingraPlugInSDK`: the plug-in kit and event bus). Use `engine:` for a
change in `packages/` that no single product surfaces, and `repo:` for repo-wide tooling,
documentation, and CI. A change several products surface gets one entry under the product the
user sees it in first.

A release heading is `# <version>+<build> <M/D/YYYY>`, for example `# 1.11.0+280 10/21/2026`
(drop `+<build>` for a product with no build number). Releasing a product moves that product's
entries from `# Next` into a new section under that heading, directly beneath `# Next`; other
products' entries stay in `# Next`. That is the only time `# Next` entries move. The release scripts
(`scripts/release-*.sh`) don't do this yet, so whoever cuts the release does it, and the top list
becomes that release's notes.

`CHANGELOG.md` is the release record and, since [DONE.md](docs/DONE.md) was frozen on 2026-11-12,
the record of finished TODO.md items too. A change that finishes one deletes it from TODO.md and,
when it meets the rules below, adds an entry here.

### Top list: release notes for users
Write each entry as a release note the user will read. Address the user, say what they can now do
or what stopped going wrong, and keep file names, type names, and implementation detail out of it.

Voice rules:
- Key point first.
- Never use an em dash. Use a comma, colon, or period instead.
- Use hyphens sparingly. Glossary terms keep theirs: `plug-in` is always hyphenated.
- No line whose only job is to tell the reader which part matters ("Importantly, ...", "Note that ...").
- Use the product's own vocabulary for its domain objects, not generic terms (`project`, `input`, `shot`,
  `program`, `destination`, per [GLOSSARY.md](docs/GLOSSARY.md); never "item", "source", or "scene").
- Don't copy the voice of older released entries. Some predate these rules.

### Entry format
- Start with the product prefix, then a capital letter, in the past tense: `- cli: Added ...`,
  `- app: Fixed ...`. Top-list entries address the user instead ("You can now ...") after the prefix.
- One sentence, ending in a period.
- The prefix counts toward the character limit below.

### Bottom list: internal work worth a record
Refactors, test coverage, developer tooling, logging and diagnostics, build and dependency
changes, documentation. Plain descriptive phrasing is fine here, since this half is for the team,
not for users.

### Hard limit: 110 characters per entry
Count from the leading `- ` through the final character. The entry must sit on one line, which is
roughly one sentence. Say what changed, and add the why only if it still fits and isn't obvious.
- Root-cause narrative, investigation timelines, API semantics, and design rationale belong in
  code comments, doc comments, or the commit message, not here.
- If it doesn't fit, cut to what changed and move the explanation into the code.
- Never split one change across two bullets to buy more room.
- Never drop the limit because a change feels important enough to deserve an exception.

### Which list does an entry go in?
Decide by whether a user could notice the change, not by how large it was. A one-line fix to a
visible bug is a top-list entry. A 500-line refactor nobody can see is a bottom-list one.

### When an entry is required
Any change a user could notice, or that alters one of these, gets an entry in the same change:
- a package's public API (`TingraPlugInKit` and `TingraEventBus` are SemVer contracts),
- a dependency,
- the project document format,
- the `--json` output or MCP tool payload keys (the stable scripting contract).

Formatting-only, whitespace-only, and comment-only changes get none.

### Check before calling it done
Run `git diff -- CHANGELOG.md` and confirm it shows this change's entry (`git status` alone only
shows the file as modified, which an earlier edit could explain). A CHANGELOG without an entry on a
change that needs one means the task isn't finished.

# Other Rules

The following rules apply to all AI agents interpreting or modifying this project:

1. **Workspace Isolation Constraint**: Agents are strictly forbidden from modifying, creating, or deleting any files outside of the current workspace directory. All file system operations must be strictly scoped to this path.
2. **Strict Compilation**: After each and every change, code must compile without errors, and you must not introduce **new** warnings. Verify proactively.
   - **Xcode hides package warnings.** An app build surfaces warnings from the app target only; warnings inside `packages/*` are suppressed as dependency warnings. To see them, run `swift build` inside the package.
   - To check a specific deployment target's availability diagnostics, pass `-Xswiftc -target` to `swift build`, but never with `--build-tests` (the test product isn't wired up under a raw `-target` and gives spurious "cannot find …" errors); validate tests with a plain `swift build --build-tests`.
   - Treat **pre-existing** warnings as out of scope unless you're deliberately doing a cleanup pass; fix or clearly flag any warning you introduce.
3. **No Leftover Scripts**: Remove working/temporary scripts (such as Python scripts created for refactoring or manipulating code) as soon as they are no longer needed. Do not leave them lingering in the project directories.
4. **Code Preservation**: Never remove existing code, logic, or comments from a file unless there is a clear and compelling reason to do so.
5. **DRY Principles**: When creating shared UI components or helpers, place them in a common file rather than duplicating them in multiple view files to avoid 'Invalid redeclaration' errors.
