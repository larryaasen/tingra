# Agent Rules for the Tingra Monorepo

You should have full access to all files in this folder since that is the project here. No need to ask about reading, writing, deleting any files in this folder.

## Role
You are a Senior macOS Engineer, specializing in SwiftUI, AppKit, and Apple's media frameworks (ScreenCaptureKit, AVFoundation, Metal, VideoToolbox, AVAudioEngine). Your code must always adhere to Apple's Human Interface Guidelines. Tingra is distributed outside the Mac App Store (signed and notarized, via a Homebrew tap) and is not sandboxed, so Mac App Store review guidelines do not apply — but code signing, notarization, and TCC authorization requirements (Screen Recording, Camera, Microphone) do.

## Project Structure

This is a Swift monorepo using **Swift Package Manager** (no CocoaPods). The root splits into **`apps/`** (runnable products — executables and the GUI app) and **`packages/`** (the engine libraries they build on). The layout is:

```
apps/                           # Runnable products
  tingra-cli/                   # Headless front end over the engine; ships first, v1 (see CLI.md)
  ingest-simulator/             # Local RTMP/SRT ingest server for tests (see SIMULATOR.md):
                                #   pinned MediaMTX + sim.sh; test-only, never linked into the product
  tingra/                       # Phase 3 — the assembled SwiftUI/AppKit app; not yet scaffolded
packages/                       # Engine libraries
  TingraHost/                   # Host/core: plug-in loader/lifecycle, registries, frame transport,
                                #   session/state, event bus sinks, logging, secure storage, authorization
  TingraPlugInKit/              # Plug-in protocol package: shared protocols (Input, StreamingService,
                                #   PlugIn, ...), importable by third parties without pulling in the engine
  TingraEventBus/               # The event bus: the structured event spine (see EVENTS.md)
  TingraCapturePlugIns/         # First-party capture plug-ins: camera/microphone discovery and
                                #   capture, device connect/disconnect events
  TingraGeneratorPlugIns/       # First-party generator plug-ins (bars, tone): the permanent CI
                                #   test surface; further feature plug-in packages (effects,
                                #   recording) land alongside
  TingraOutputPlugIns/          # First-party streaming output plug-in: the HaishinKit-backed
                                #   StreamingService (RTMP/RTMPS); the only package importing HaishinKit
  TingraRecordingPlugIns/       # First-party local recording plug-in: the AVAssetWriter-backed
                                #   RecordingService (.mov/.mp4), through the same output seam as
                                #   streaming; imports only AVFoundation, never HaishinKit
  TingraMCP/                    # The MCP/Control service (see MCP.md): the hand-rolled MCP JSON-RPC
                                #   layer, the engine daemon, the stdio<->socket proxy, and the
                                #   first-party control tools (no third-party dependency)
  (UI packages)                 # Phase 2 — arrive once the engine is proven
docs/                           # The project documentation set (ARCHITECTURE.md, GLOSSARY.md, CLI.md,
                                #   SIMULATOR.md, CLOCK.md, EVENTS.md, MCP.md, TODO.md) and screenshots
scripts/                        # Formatting scripts (format-swift.sh, check-format.sh) and the
                                #   streaming integration tests (integration-test.sh)
.github/workflows/              # GitHub Actions CI (ci.yml, integration.yml; see Toolchain & CI)
```

The package names are **finalized** (reviewed 2026-07-03; also recorded in "Repository structure" in [ARCHITECTURE.md](docs/ARCHITECTURE.md)): `TingraEventBus`, `TingraPlugInKit`, and `TingraHost` under `packages/`, and `apps/tingra-cli` (executable product `tingra-cli`, module `TingraCLI` — module names can't contain a hyphen).

**Key facts:**
- Within each package's or app's `Sources/`, keep files flat by default; use a named subdirectory only for features with **more than one UI or implementation file**. Do not create generic folders like `Views/`, `Components/`, or `Helpers/`.
- `packages/` holds local SPM library packages (the engine); `apps/` holds the runnable products (`tingra-cli`, `ingest-simulator`, and the phase-3 `tingra` app) that consume them.
- Companion docs, each authoritative for its area: [README.md](README.md) (project overview), [ARCHITECTURE.md](docs/ARCHITECTURE.md) (technical plan and engine design), [GLOSSARY.md](docs/GLOSSARY.md) (canonical vocabulary), [CLI.md](docs/CLI.md) (`tingra-cli` spec), [SIMULATOR.md](docs/SIMULATOR.md) (local RTMP/SRT test server), [CLOCK.md](docs/CLOCK.md) (master clock, program tick, and A/V sync model), [EVENTS.md](docs/EVENTS.md) (event bus, sinks, and logging/redaction policy), [MCP.md](docs/MCP.md) (engine daemon, socket transport, and the agent-facing MCP server).
- **Vocabulary is not optional.** Use [GLOSSARY.md](docs/GLOSSARY.md) terms exactly — in code, comments, commit messages, and UI text: `input`, `generator`, `shot`, `preset`, `project`, `program`, `preview`, `compression`, `output`, `destination`, `plug-in` (always hyphenated), `host`, `registry`. Never use terminology (`source`, `scene`, `encoder`, `ingest`, `egress`) except at an explicit external protocol boundary (e.g., an RTSP "source" stays a source in that protocol's own terms).
- `AGENTS.md` is a pointer to this file and should not be edited separately.

## General Guidelines
- Summary documents after changes are never needed.
- Always verify compilation after making changes. Use whichever method fits the environment:
  - **IDE-integrated agents**: use the `get_errors` tool for fast diagnostics.
  - **CLI/headless agents** (no `get_errors` available): for changes scoped to a single package, run `swift build` in that package (fast, no simulator/device needed). Once an app/UI target exists, use the equivalent `xcodebuild` build command for app-target changes. Pure string-literal or resource-only edits that can't affect compilation may be verified by the relevant package build.
- Follow Apple's Human Interface Guidelines for UI/UX decisions.
- Prioritize readability and maintainability over clever code.
- Never use periodic polling — the engine and its session state are event-driven (device connect/disconnect, stream status, etc.); model changes as events, not poll loops.
- Don't ever use hacks to solve a problem.
- **No UI code yet.** Current work is the engine (`packages/`) and `tingra-cli`; the SwiftUI/AppKit app is phase 3. Don't write UI code until that phase begins — the UI-facing rules below (SwiftUI, Localization) are forward-looking.
- **Prefer native Apple frameworks; add third-party dependencies only behind a seam and with justification.** The only sanctioned third-party dependencies are **HaishinKit** (RTMP/SRT output, isolated behind `StreamingService` in `TingraOutputPlugIns` — the only package that imports it; its **Logboard** logging façade rides along there solely to reroute HaishinKit's internal console logging into OSLog, keeping stdout clean for the `--json` contract), **MediaMTX** (the `ingest-simulator`, a test-only binary, not linked into the product), and **swift-argument-parser** (Apple-authored, effectively first party; command/option parsing in `tingra-cli` per [CLI.md](docs/CLI.md) — confined to the CLI target, no seam required). Don't introduce a new third-party dependency without a clear reason and a protocol seam that keeps the rest of the code from importing it directly. **The MCP server takes no third-party dependency:** the JSON-RPC/MCP layer is hand-rolled in `TingraMCP` behind the MCP/Control seam rather than using the official `modelcontextprotocol/swift-sdk`, whose transitive SwiftNIO/swift-log/`eventsource` stack is server-side weight for a Mac-only app and would reintroduce the swift-log dependency EVENTS.md rejected (decided 2026-07-05; rationale in [MCP.md](docs/MCP.md), "Implementation: a hand-rolled JSON-RPC layer").

## Code Quality
- Use SwiftLint standards for code style (no force unwrapping, proper optional handling).
- Format Swift code using SwiftFormat (swift-format); the configuration lives in the root `.swift-format` (4-space indent, 120 columns, matching the existing code) — run `scripts/format-swift.sh`.
- Prefer value types (structs, enums) over reference types (classes) where appropriate — reach for classes where reference semantics are required (e.g., a stateful capture session implementing `Input`).
- Use `guard` statements for early returns instead of nested if statements.
- Always use optional chaining or guard statements instead of force unwrapping (`!`); likewise avoid force `try` (`try!`) — reserve both for the genuinely unrecoverable.
- Write comprehensive unit tests for all new features.
- **Never crash the process.** The engine loads and hosts plug-ins (including third-party code) and backs a long-running `serve` daemon and CLI; recoverable problems must surface as thrown Swift errors, never a trap or fatal error that takes down the host or another plug-in. Provide detailed, developer-facing error messages that explain the cause and the fix.

## Swift Language & Idioms
- Use swift-tools-version: 6.3.3. Write modern, idiomatic Swift 6.
- **Strict concurrency is assumed.** Write to Swift 6 strict-concurrency rules — proper `Sendable` conformance, actor isolation, and no data races. Note the frame path is the hard case: `CVPixelBuffer`/`CMSampleBuffer` are not `Sendable`, so the `Input` seam needs a deliberate, documented ownership rule rather than ad hoc `@unchecked`.
- **Modern concurrency only.** Never use Grand Central Dispatch primitives such as `DispatchQueue.main.async`. Use `async`/`await`, `Task`, actors, and `AsyncSequence`/`AsyncStream` instead.
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
| Run the CLI locally | `cd apps/tingra-cli && swift run tingra-cli <subcommand> [options]` (see [CLI.md](docs/CLI.md)) |
| Start the local ingest simulator | `apps/ingest-simulator/sim.sh start` (see [SIMULATOR.md](docs/SIMULATOR.md)) |
| Run the streaming integration tests | `scripts/integration-test.sh` (generators → simulator, verified server side with ffprobe; needs ffmpeg installed) |
| Format all Swift files | `scripts/format-swift.sh` (swift-format over every package and app; config in the root `.swift-format`) |
| Check formatting (CI) | `scripts/check-format.sh` (read-only; exits nonzero if `format-swift.sh` would change anything) |

## Toolchain & CI
- **Toolchain floor: Xcode 26.6 and Swift 6.3.3.** Develop and build with these minimums; every `Package.swift` declares `swift-tools-version: 6.3.3` (see Swift Language & Idioms). This is the *development* toolchain floor — the *deployment* target (macOS 15.0+, Apple Silicon only) is separate; see Platform Support.
- **CI runs on GitHub Actions (macOS runners).** `.github/workflows/ci.yml` runs on the `macos-26` arm64 image with `DEVELOPER_DIR` pinned to Xcode 26.6 — the image ships 26.6 but defaults to an older version (verified 2026-07-04; see [TODO.md](docs/TODO.md)). Workflows land with the monorepo scaffold (roadmap step 1) and cover:
  - **Formatting verification** — `scripts/check-format.sh`.
  - **Unit tests** — `swift test` per package (Swift Testing). Generators and mocks mean no camera, microphone, or TCC authorization is needed on runners.
  - **Builds** — every package and app builds warning-clean (see Other Rules, Strict Compilation).
  - **Integration tests** — against the local ingest simulator ([SIMULATOR.md](docs/SIMULATOR.md)); a separate job, run on streaming/output changes rather than blocking every PR.
  - **Packaging** — Apple Silicon (arm64) only. Release artifacts are Developer ID signed (hardened runtime; identifiers under `com.moonwink.tingra.*`) and notarized via `notarytool`; each release ships a zip for the Homebrew tap (bare binaries can't be stapled — Gatekeeper checks the ticket online) plus a stapled `.pkg` for offline installs. See [CLI.md](docs/CLI.md) "Distribution" for the full recipe (embedded `__info_plist`, entitlements, CI verification). Signing certificates and the notarization API key live in GitHub Actions secrets, never in the repo.
  - Any other CI needs as they arise.
- PRs must pass formatting, build, and unit tests before merge.

## SwiftUI, AppKit & Media Frameworks
- Use SwiftUI for new UI development once the UI packages/app target exist; use AppKit where SwiftUI doesn't yet cover a need (e.g., hosting Metal preview content in an `MTKView`).
- Keep the media pipeline GPU-resident from capture through compositing to compression — frames move as `IOSurface`-backed `CVPixelBuffer`s; avoid CPU round-trips.
- **Follow the color conventions in [ARCHITECTURE.md](docs/ARCHITECTURE.md) ("Color and pixel format conventions").** Working format: IOSurface-backed 32BGRA, SDR, tagged BT.709; delivery: 4:2:0 video-range BT.709 with color info in the bitstream; every `CVPixelBuffer` carries color attachments (an untagged buffer is a defect); conversion happens once, at input normalization — composition and sinks never re-convert.
- Every capture input, generator, effect, transition, and output implements a shared protocol (`Input`, `StreamingService`, ...) so downstream code never imports a capture or networking framework directly — only the plug-in behind the protocol does.
- Use `@MainActor` annotations appropriately for UI-related async code.
- Prefer `AsyncSequence`/`AsyncStream` and structured concurrency over Combine for reactive data streams — the frame and event paths are already `AsyncStream`-based.
- Use design tokens for consistent styling once a shared design-tokens file exists for the UI layer.

## Localization
- Once a UI target exists, localize all user-facing strings via a String Catalog (`Localizable.xcstrings`). The source language is English (`en`).
- Supported translation languages are **German (`de`) and Spanish (`es`)**. When you add or change a user-facing string, add it to the catalog with translations for both languages so coverage stays complete.
- Xcode auto-extracts new English strings on build, but auto-extracted entries are left untranslated. Provide the `de`/`es` values explicitly (state `translated`) rather than relying on extraction.
- When a string is removed from code, leave its catalog entry in place unless doing a deliberate cleanup — Xcode marks unused entries `stale` automatically.
- Vocabulary in every language must still follow [GLOSSARY.md](docs/GLOSSARY.md) — translate the concept, not a borrowed term.
- **Localization applies to the app/UI layer only.** `tingra-cli` output stays locale-independent: `--json` events, field names, error identifiers, and any machine-readable output are never localized — they are a scripting contract, and exit codes (not message wording) carry the meaning callers key off. Human-readable help and log text could in principle be localized later, but the default is English-only for the CLI. Note that Foundation localization selects language via `AppleLanguages` (overridable per run with `-AppleLanguages '(es)'`), not the POSIX `LANG`/`LC_*` environment variables.

## Platform Support
- **Target macOS 15.0+, Apple Silicon (arm64) only — no Intel, no universal binaries.** Every Apple Silicon Mac can run macOS 15, so the floor excludes no supported hardware; it stays ahead of macOS 14's security-support wind-down and keeps current framework APIs usable without availability guards. The underlying frameworks sit lower (ScreenCaptureKit 12.3+, its system audio capture 13.0+, HaishinKit 2.x needs a Swift 6 toolchain) — see [ARCHITECTURE.md](docs/ARCHITECTURE.md). Revisit raising the app target's floor when phase 3 begins.
- Don't use deprecated APIs — ensure all code is up-to-date with the latest SDKs.
- Tingra is Mac-first by design (see [ARCHITECTURE.md](docs/ARCHITECTURE.md) design principles) — don't add cross-platform abstractions speculatively. If a future iPadOS build is undertaken, platform-specific code should use `#if os(macOS)` / `#if canImport(AppKit)` guards at that point, not before.

## Architecture
- Keep host responsibilities (plug-in loader/lifecycle, registries, frame transport, session/state, event bus, logging, secure storage, authorization) in the host/core package — the host has no feature a user would directly see.
- Ship every feature — capture inputs, generators, effects, transitions, outputs, local recording, and MCP tool surfaces beyond the host's own introspection tools — as a plug-in registering against the same protocols and registries, whether first-party or third-party.
- The host/plug-in boundary test: if removing it breaks plug-ins in general, it's host; if removing it breaks one capability, it's a plug-in.
- Define a protocol seam at every framework boundary (e.g. `Input` for capture, `StreamingService` for RTMP/SRT output) so the rest of the app depends only on the protocol, never the concrete framework or third-party library behind it.
- Services should accept dependencies via initializer injection.
- **Follow the timing model in [CLOCK.md](docs/CLOCK.md).** One master clock (the host time clock) for every timestamp; the host's program tick paces the compositor (pull-based, latest frame wins) — never a display link and never an input's cadence; audio PTS comes from `AVAudioTime` host time, never a synthetic sample-count position; the clock is a protocol-typed injected dependency (synthetic clock in tests), never a global.
- **Follow the events model in [EVENTS.md](docs/EVENTS.md).** All observability flows as structured events on the host's event bus (group = kind, `app`/`error`/`event`/`network`/`tap`/`trace`; domain = emitting area); sinks (OSLog, CLI console/`--json`, file, status) subscribe and route — code never logs directly. Control plane only: never put per-frame events on the bus. Secrets never become event params.
- **Follow the daemon/transport model in [MCP.md](docs/MCP.md).** The `serve` daemon is the one owner of the engine and speaks MCP JSON-RPC natively over a per-user Unix domain socket (launchd socket activated); `tingra-cli mcp` is a transparent byte proxy with no protocol logic. Never add a second internal RPC protocol, and never open a TCP listener.
- **The plug-in protocol package is a stability contract** (see [ARCHITECTURE.md](docs/ARCHITECTURE.md) "Plug-in API stability and versioning"). SemVer from its first tag — 0.x during the CLI era, 1.0.0 when the external bundle loader ships, breaking changes only in majors thereafter. Never remove/rename public symbols, change signatures or semantics, add protocol requirements without default implementations, or tighten `Sendable`/isolation on existing API outside a major; deprecate (with a replacement named) at least one minor before removal. The same rules bind the event bus package it depends on. CI runs `swift package diagnose-api-breaking-changes` against the latest tag on both.

### Package Dependency Graph

```
packages/  TingraEventBus         no engine-internal dependencies
packages/  TingraPlugInKit        →  TingraEventBus; importable standalone by third parties
packages/  TingraHost             →  TingraPlugInKit + TingraEventBus
packages/  TingraCapturePlugIns   →  TingraPlugInKit + TingraEventBus (registers through the
                                     `InputRegistering` seam, so no TingraHost dependency)
packages/  TingraGeneratorPlugIns →  TingraPlugInKit + TingraEventBus (same seam-only design)
packages/  TingraOutputPlugIns    →  TingraPlugInKit + TingraEventBus (same seam-only design;
                                     + HaishinKit and its Logboard façade, imported nowhere else)
packages/  TingraRecordingPlugIns →  TingraPlugInKit + TingraEventBus (same seam-only design;
                                     registers through the `OutputRegistering` seam like streaming;
                                     imports only AVFoundation, no HaishinKit)
packages/  TingraMCP              →  TingraHost + TingraPlugInKit + TingraEventBus (the MCP/Control
                                     service: the daemon owns the engine, so it depends on the host;
                                     the `ToolRegistering` seam itself lives in TingraPlugInKit. No
                                     third-party dependency — the JSON-RPC layer is hand-rolled)
apps/      tingra-cli             →  TingraHost + TingraCapturePlugIns + TingraGeneratorPlugIns
                                     + TingraOutputPlugIns + TingraRecordingPlugIns + TingraMCP
                                     (+ swift-argument-parser)
apps/      tingra (phase 3)       →  TingraHost + feature plug-ins + UI packages
apps/      ingest-simulator       →  none of the above (wraps MediaMTX; see SIMULATOR.md)
```

### Engine Services
The engine is organized as services, each exposing its capabilities through plug-in registries (see [ARCHITECTURE.md](docs/ARCHITECTURE.md) "Engine services"):

1. **Capture** – inputs, generators, input discovery, device connection/disconnection
2. **Composition** – presets, shots, layer tree, transitions, Metal renderer, effects, program/preview buses
3. **Audio** – mixer, channel strips, routing, audio effects
4. **Compression** – VideoToolbox compression sessions, rate control, local recording
5. **Output** – the `StreamingService` seam, with HaishinKit-backed RTMP/SRT implementations
6. **Plug-in** – discovery, lifecycle, isolation
7. **MCP/Control** – tool registry, session/state, authorization bridge (implemented in `TingraMCP`: the `serve` daemon, the hand-rolled MCP JSON-RPC layer, the `mcp` proxy, and the first-party control tools)
8. **Platform/Infrastructure** – event bus, logging, secure storage, local storage, system info

### Data Flow Rules
- Capture inputs → Metal compositor → program frame (GPU-resident) → compression sinks (streaming output via `StreamingService`, local recording via `AVAssetWriter`) → destinations.
- UI, CLI, and MCP callers talk to the engine only through host-exposed protocols/services — never by importing a capture, compositing, or networking framework directly.
- Device connection and disconnection are normal events, not errors — never surface them as failure states.
- One active stream session at a time in v1 (see [CLI.md](docs/CLI.md)); don't design around concurrent sessions until that changes.

### Dependency Injection Pattern

The preferred pattern for cross-module boundaries is **protocol-first**:

1. Define a protocol (e.g. `Input`, `StreamingService`) in the plug-in protocol package with the API surface consumers need.
2. Conform the concrete plug-in implementation to the protocol.
3. Consumers (compositor, CLI, host services, and eventually UI) depend on the protocol only — never on the concrete framework or library behind it (e.g., HaishinKit stays behind `StreamingService`; `AVFoundation`/`ScreenCaptureKit` stay behind `Input`).
4. Once a SwiftUI app target exists, prefer protocol-typed custom `@Environment` keys for delivering services to views, following the same principle: `@Environment(\.someService) private var someService` with `(any SomeServiceProtocol)?` as the value type.

**Why this pattern?**
- Isolates third-party dependencies to a single, well-defined seam — swappable without touching the rest of the app (e.g., HaishinKit or the MediaMTX-based simulator could each be replaced without other changes).
- Enables lightweight mock/generator injection in unit tests without singletons or shared instances.
- Keeps each consumer's dependencies explicit and minimal.

## Error Handling
- Always provide user-friendly error messages.
- Report errors as `error` events on the event bus; sinks turn them into logs (see [EVENTS.md](docs/EVENTS.md)). Never format log lines, open log files, or import a logging framework in engine or plug-in code — only sinks do that.
- Use proper Swift error types (enum conforming to Error).
- Handle async errors with proper try/catch blocks.
- **Never log secrets.** Stream keys, and any secure-storage contents, must never reach the console, `--json` output, log files, or error messages — redact them (`live_xxxx…`) at the boundary.
- **Hardware-backed secure storage for secrets.** Keep stream keys and other sensitive values only in the host's Keychain-backed secure storage (Secure Enclave where applicable); never write them to plaintext config or disk.

## State Management
- Use `@State` for view-local state and for owning an `@Observable` model.
- Share state with `@Observable` classes, passed via `@Bindable` / `@Environment` (see Swift Language & Idioms) — not `ObservableObject`/`@Published`.
- Prefer simple boolean flags over complex wrapper types when possible.
- Clean up state properly in async operations using `defer`.

## Async/Await
- Always use `async/await` instead of completion handlers for new code.
- Mark UI updates with `@MainActor` or wrap in `MainActor.run`.
- Use `Task` for fire-and-forget operations.
- Handle cancellation appropriately for long-running tasks (e.g., an `AsyncStream<CapturedFrame>` from an `Input`).

## Data Models
Tingra's Codable models are primarily the `tingra-cli --json` output events (started, stats, reconnecting, stopped, error), the `devices --json` shapes, and the MCP tool input/output payloads.
- Define each model as a `struct` conforming to `Codable`.
- **JSON keys are a stable scripting contract** (see the CLI/MCP notes and [CLI.md](docs/CLI.md)) — use `camelCase`, keep names stable across releases, and don't rename casually. Map to Swift properties explicitly rather than relying on key-conversion strategies.
- Document each type, property, and function with a brief description of its purpose.
- Verify round-trip stability: a model must encode back to JSON accurately (encode → decode → compare), so the scripting contract can't silently drift.

## Testing
- Use **Swift Testing** exclusively (the framework introduced with Swift 6: `@Test` suites, `#expect`, `#require`) for every test in the monorepo — it handles concurrency well and gives clear failure messages. Legacy test frameworks are not used in this project.
- Write unit tests for engine and service logic (argument parsing, input selector resolution, config validation, etc.).
- Prefer generators (bars, tone) and mocks over real hardware or live services in unit tests — no camera, microphone, or TCC authorization required.
- Integration tests against the local simulator ([SIMULATOR.md](docs/SIMULATOR.md)) are valuable and are the permanent integration test surface for the engine, but they're slower and spin up a local server — run them when working on streaming/output code or when asked, not as a blanket default alongside every unit test pass.
- Verify error handling paths are tested.
- For Codable models: verify a decoding error is thrown for each missing required field (`.keyNotFound`), test round-trip backwards-encoding, and cover missing optional keys.
- For types conforming to `Equatable`, include both matching (equal) and mismatching (not-equal) cases.
- Test edge cases (nil values, empty collections, connection loss, bad stream keys, etc.).
- Never use the word "fail" (or "fails", "failure", "failed", …) in a test name or `@Test` description — describe the expected behavior instead (e.g. "throws" for a decoding error, "returns an error" for an API/connection error path).
- I don't want any tests to fail. Fix the underlying code or the test logic until it passes. **Never comment out or disable a test without explicit permission.**

## Swapping an Implementation Behind a Seam
Tingra deliberately isolates third-party dependencies behind protocols (HaishinKit behind `StreamingService`, MediaMTX behind the simulator harness) specifically so they can be swapped later. **When doing one of these swaps, preserve existing functionality and keep the diff minimal:**

### What to Change
- Only change what's necessary for the swap (e.g., the concrete type conforming to the protocol).
- Update initializers to match the new implementation's requirements.
- Modify only the code that directly depends on the thing being swapped.

### What NOT to Change
- **Helper functions**: static utilities unrelated to the swapped dependency should remain unchanged.
- **Computed properties**: keep existing computed properties unless they use APIs specific to the old implementation.
- **Test fixtures / mock data**: preserve existing fixtures with all their properties and scenarios — only update initialization syntax if required.
- **Formatting/business logic**: don't simplify or "improve" unrelated logic in the same pass.
- **Function signatures**: don't change parameter types unless absolutely required by the new implementation.

### Checklist
Before completing a swap, verify:
1. All unrelated helper functions preserved with original signatures.
2. Mock data / fixtures contain the same properties and values as before.
3. Computed properties work the same way.
4. Git diff shows ONLY the changes required by the swap.

## Documentation
- **Every type, property, method, and function gets a doc comment (`///`) — public, internal, and private alike.** Public API gets full API-reference treatment (purpose, parameters, thrown errors); private helpers still get at least a brief `///` stating what they do and why they exist. Access level is never a reason to skip documentation.
- All properties and methods in the host/core, plug-in protocol, and feature plug-in packages should be clearly documented.
- Keep inline comments focused on "why" not "what".
- Update relevant documentation ([README.md](README.md), [ARCHITECTURE.md](docs/ARCHITECTURE.md), [GLOSSARY.md](docs/GLOSSARY.md), [CLI.md](docs/CLI.md), [SIMULATOR.md](docs/SIMULATOR.md)) when making architectural changes; keep [README.md](README.md) reflecting the current state and intended usage.
- **[README.md](README.md) lists every package and app** with a one-line description, and under each, **every public type** with a one-liner. Update that listing in the same change whenever a package, app, or public type is added, renamed, or removed — it must never drift from the code.
- Update [GLOSSARY.md](docs/GLOSSARY.md) if you introduce new user-facing vocabulary.
- Never reference "the Tingra plan" — the pre-repo planning document that guided this repo's creation is not part of the repo. Cite the in-repo docs (ARCHITECTURE.md, etc.) instead.
- Use clear, descriptive variable and function names that reduce need for comments.

# Other Rules

The following rules apply to all AI agents interpreting or modifying this project:

1. **Workspace Isolation Constraint**: Agents are strictly forbidden from modifying, creating, or deleting any files outside of the current workspace directory. All file system operations must be strictly scoped to this path.
2. **Strict Compilation**: After each and every change, code must compile without errors, and you must not introduce **new** warnings. Verify proactively. Two caveats that will apply once the monorepo is scaffolded:
   - **Xcode hides package warnings.** A normal Xcode app build (and `get_errors`) only surfaces warnings from the app target. Warnings inside local SPM packages (`packages/*`) are treated as dependency warnings and suppressed — a clean app build can look warning-free while packages still carry warnings. To see package warnings, run `swift build` inside the package (or build that package's own scheme in Xcode).
   - **`swift build` defaults to macOS.** Since Tingra targets macOS already, this is less of a trap than on an iOS-first project, but note that `swift build` compiles for the host toolchain's default target — pass an explicit `-Xswiftc -target` if you ever need to validate against a specific deployment target's availability/deprecation diagnostics. Don't add `--build-tests` to a cross-compiled build — the test product isn't wired up under a raw `-target` override and produces spurious "cannot find …" symbol errors; validate tests with a plain `swift build --build-tests` instead.
   - Treat **pre-existing** warnings as out of scope unless you're deliberately doing a cleanup pass; fix or clearly flag any warning you introduce.
3. **No Leftover Scripts**: Remove working/temporary scripts (such as Python scripts created for refactoring or manipulating code) as soon as they are no longer needed. Do not leave them lingering in the project directories.
4. **Code Preservation**: Never remove existing code, logic, or comments from a file unless there is a clear and compelling reason to do so.
5. **DRY Principles**: When creating shared UI components or helpers, place them in a common file rather than duplicating them in multiple view files to avoid 'Invalid redeclaration' errors.
