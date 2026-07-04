# Tingra: Architecture and Technical Plan

Tingra is a native macOS live streaming and production application, written entirely in Swift and built on Apple's modern media stack. This document describes the technical architecture and the role each component plays, including where the HaishinKit library fits in.

## Design principles

1. **Mac first, not cross platform.** Every choice favors deep integration with macOS over portability. No Qt, no OpenGL, no ported abstractions.
2. **GPU resident pipeline.** Frames stay on the GPU as `IOSurface` backed buffers from capture through composition to compression, avoiding expensive CPU round trips.
3. **Modern Apple frameworks over reinvention.** ScreenCaptureKit, AVFoundation, Metal, VideoToolbox, and AVAudioEngine do the heavy lifting.
4. **Build the distinctive parts; adopt the thankless parts.** Capture and composition are what make Tingra native and distinctive, so we own them. RTMP/SRT networking and muxing are hard, standardized, and undifferentiated, so we adopt a proven library (HaishinKit) rather than rebuild them.
5. **Plug-in first.** All core functionality ships as first party plug-ins built on the same protocol third parties use. The host, the only code that is not a plug-in, is the smallest thing that can run plug-ins and move frames.

## Vocabulary

Tingra uses Apple Pro app and broadcast terminology. GLOSSARY.md is the canonical reference for every term. The ones this document leans on hardest: **input** (anything producing frames, including **generators** that synthesize them), the **project > preset > shot > layers** hierarchy, **program** (what viewers see and hear), **compression** and **output** (the delivery components), **destination** (a streaming target), and **plug-in** / **host** / **registry** (the extensibility model; always spelled "plug-in"). Tingra does not say source, scene, egress, ingest, or encoder; see the glossary for the full list and the protocol boundary exception.

## Pipeline overview

```
┌─────────────────────┐     ┌─────────────────────┐
│  ScreenCaptureKit   │     │    AVFoundation     │
│  (display, window,  │     │  (camera input)     │
│   app inputs)       │     │                     │
└──────────┬──────────┘     └──────────┬──────────┘
           │  IOSurface-backed          │  IOSurface-backed
           │  CVPixelBuffers            │  CVPixelBuffers
           └────────────┬───────────────┘
                        ▼
             ┌─────────────────────┐
             │   Metal compositor  │  ◄── Core Image effects,
             │  (shots, layers,    │      transitions
             │   transforms)       │
             └──────────┬──────────┘
                        │  program frame
                        │  (IOSurface/CVPixelBuffer, GPU-resident)
             ┌──────────┴───────────────┐
             ▼                          ▼
  ┌───────────────────────┐   ┌─────────────────────┐
  │      HaishinKit       │   │   Local recording   │
  │ (VideoToolbox         │   │  (AVAssetWriter,    │
  │  compression inside   │   │   hardware encode → │
  │  the stream + RTMP/   │   │   .mov / .mp4)      │
  │  SRT output)          │   └─────────────────────┘
  └───────────┬───────────┘
              ▼
     YouTube / Twitch / custom
     RTMP or SRT destinations

  Audio runs in parallel:
  AVFoundation / Core Audio inputs → AVAudioEngine mixing →
  mixed audio → compressed and muxed by each sink (recording + HaishinKit output)
```

Generators (bars, solids, test tones) enter the pipeline as inputs alongside the capture boxes above.

## Color and pixel format conventions

One canonical working format and one delivery standard, decided up front — mismatched or untagged color is the classic source of "slightly washed out" streams. Tingra uses the normal broadcast conventions:

- **Working format (capture → composition):** IOSurface backed `kCVPixelFormatType_32BGRA` (Metal `bgra8Unorm`), SDR, tagged BT.709. This is the "common GPU resident frame type" every input normalizes to. Normalization at the input seam is the one place pixel format and color conversion happen — YCbCr camera frames ('420v'/'420f') to RGB, wide gamut sources (Display P3 screens and cameras) down to BT.709. The program frame the compositor emits is this same format.
- **Delivery standard (compression sinks):** H.264/HEVC, 4:2:0 chroma subsampling, video (limited) range, BT.709 — with the color description written into the bitstream (VUI `colour_primaries`/`transfer_characteristics`/`matrix_coeffs` all BT.709) and matching format-description/track tags on recordings. Program resolutions stay even in both dimensions (4:2:0 requires it).
- **Every buffer is tagged.** Every `CVPixelBuffer` in the pipeline carries `CVImageBuffer` color attachments (primaries, transfer function, YCbCr matrix). Untagged buffers are a defect: untagged means the next stage guesses, and guessing is where color bugs live.
- **One conversion point.** Composition and the sinks never re-convert; they trust the tags set at input normalization. Core Image manages its own (linear) working space; hand written Metal shaders that blend or sample must be deliberate about sRGB vs. linear texture views rather than relying on defaults.
- **SDR only for now.** Wide gamut and HDR program output (P3, HLG/PQ) are out of scope until well after the app era; if they come, they enter at the same input normalization seam and become a program-wide setting, not a per-input one.

## Frame ownership across the `Input` seam

`CVPixelBuffer` and `CMSampleBuffer` are not `Sendable`, yet frames and audio buffers must cross isolation boundaries from an input's capture callback to the compositor and the sinks. Tingra resolves this with one deliberate, documented ownership rule instead of scattered ad hoc `@unchecked Sendable` (decided 2026-07-04; the rule CLAUDE.md's strict-concurrency note calls for). Every producer and consumer of media buffers observes it:

1. **Transfer at yield.** The producer (an `Input`) hands the buffer off when it yields to its `frames()`/`audio()` stream and never touches it again — no reuse, no late writes, no retained references.
2. **One holder at a time.** Exactly one consumer owns the buffer at any moment. The compositor's latest-wins slot releases its previous frame when a newer one replaces it; a sink that needs the buffer beyond its call must be handed ownership explicitly, never share it.
3. **Immutable after transfer.** Nothing writes to the buffer after the yield. Downstream stages read, composite, and encode from it only; any stage that needs modified pixels renders into a new buffer.

Under this rule a buffer is only ever read after the unique transfer point, which is exactly the guarantee `Sendable` encodes — so the wrapper types `CapturedFrame` and `CapturedAudio` in the plug-in protocol package carry `@unchecked Sendable` soundly. **Those two types are the only sanctioned `@unchecked Sendable` in the codebase.** They are the single choke point every media buffer crosses; any new `@unchecked Sendable` anywhere else needs its own documented rule and review, and "the frame path needed it" is not a reason — the frame path already has its rule here.

The rule is enforced by convention and review, not the compiler — which is why it lives in this document, is restated on the two wrapper types, and is deliberately short enough to hold in your head while writing an input.

## Engine model: host and plug-ins

The engine splits into two kinds of code.

**The host** owns the plug-in loader and lifecycle, the registries every plug-in registers into, frame transport (the GPU resident pipeline, its master clock, and the program tick that paces the compositor — see CLOCK.md), the session and state manager, the event bus and its logging sinks (see EVENTS.md), secure storage (Keychain backed, for stream keys), and authorization (Screen Recording, Camera, Microphone). The host has no features a viewer would ever see. The test for what belongs in the host: if removing it breaks plug-ins in general, it is host; if removing it breaks one capability, it is a plug-in.

**Feature plug-ins**, first party and third party alike: every capture input, every generator, every effect and transition, local recording, every streaming output, and every MCP tool surface beyond the host's own introspection tools. First party plug-ins ship inside the product and load through the same discovery path, protocol, and registries as anything a third party writes.

Each input is an implementation of an `Input` protocol; the compositor and everything downstream consume the protocol and never import a capture framework directly, mirroring the `StreamingService` seam on the output side.

```swift
// Sketch of the boundary — not final API.
protocol Input {
    var id: InputID { get }
    func start() async throws
    func frames() -> AsyncStream<CapturedFrame>   // GPU-resident CVPixelBuffers
    func stop() async
}

final class CameraInput: Input { /* AVFoundation, all Apple platforms */ }
final class DisplayInput: Input { /* ScreenCaptureKit, macOS only     */ }
final class BarsGenerator: Input { /* generator, runs everywhere      */ }
```

**Delivery and isolation on macOS:** plug-ins are separately compiled bundles. Third party plug-ins install into a known folder (e.g. `~/Library/Application Support/Tingra/Plug-ins`); first party plug-ins ship in `Contents/PlugIns/`. The shared plug-in protocol lives in its own framework built with Library Evolution for a stable module interface; the entry point is the bundle's principal class via `Bundle.principalClass`. Tingra carries the Disable Library Validation entitlement (decided; feasible since Tingra is not Mac App Store sandboxed) because third party plug-ins will not share Tingra's Team ID. Isolation policy: bundled first party plug-ins run in process; third party plug-ins are candidates for XPC isolation where the path tolerates it (outputs, automation), while capture plug-ins stay in process because the per frame IOSurface path and TCC attribution both favor it.

**Delivery on iPadOS (if an iPad build ever happens):** runtime loading of separately distributed binaries is not possible. All executable code must be embedded in the signed app bundle at build time; loading code from outside the bundle is blocked by code signing enforcement and App Store policy (guideline 2.5.2), and ExtensionKit's third party extension point hosting is macOS only. The same `Input` protocol still works, but implementations are statically linked and chosen at compile time. An iPad build would keep camera inputs and generators, lose display/window inputs (ReplayKit could become a limited replacement input later), and use pure SwiftUI in place of the AppKit half of the UI. The seam buys portability of the core, not feature parity.

**In the CLI era**, bundled plug-ins are compiled in but register through the same code path the external bundle loader will use; the loader itself can ship after the first release.

### Plug-in API stability and versioning

The plug-in protocol package is the one API Tingra can never break casually: a shipped third party plug-in must keep loading and working across Tingra updates. The policy, in force from the package's first tag:

- **SemVer, strictly, versioned independently of the product.** During the CLI era (roadmap steps 1–4, before the external bundle loader ships) the package stays at 0.x, where minor bumps may break per SemVer convention. It tags **1.0.0 when the external bundle loader ships** — the moment third parties can actually build against it. From 1.0.0 on, breaking changes land only in major versions.
- **What counts as breaking:** removing or renaming any public symbol; changing a signature or the documented semantics of existing API; adding a protocol requirement without a default implementation; tightening concurrency requirements (`Sendable`, actor isolation) on existing API. All of these wait for a major.
- **Additive evolution first.** New protocol requirements ship with default implementations so existing conformances keep compiling. When a capability changes shape, prefer a new protocol (or protocol inheritance) over mutating a shipped one.
- **Deprecate before removing.** Mark with `@available(*, deprecated, message:)` naming the replacement, keep the symbol for at least one minor release, and remove only in the next major.
- **Library Evolution stays on** (decided above) so the module interface is stable: a plug-in built against an older minor keeps loading against a newer one without recompilation.
- **Version negotiation at load, never a crash.** Each plug-in bundle declares the protocol major it was built against (an Info.plist key under `com.moonwink.tingra.*`); the host refuses an incompatible plug-in with an `error` event naming both versions and the fix (EVENTS.md), and the remaining plug-ins load normally — per the never-crash rule.
- **CI enforcement.** The protocol package's CI job runs `swift package diagnose-api-breaking-changes` against the latest release tag, so an accidental break fails the pull request instead of a third party's build.
- **The policy travels with the dependency surface.** The protocol package's only dependency is the zero dependency event bus package (EVENTS.md), which is re-exposed to every plug-in — so the same SemVer and evolution rules bind the event bus package too.

## Engine services

The engine is organized as services, each exposing its capabilities through plug-in registries: Capture (inputs, generators, input discovery, device connection and disconnection), Composition (presets, shots, layer tree, transitions, Metal renderer, effects, program/preview buses), Audio (mixer, channel strips, routing, audio effects), Compression (VideoToolbox compression sessions, rate control, local recording), Output (the `StreamingService` seam with HaishinKit backed RTMP/SRT implementations, later multiple destinations), Plug-in (discovery, lifecycle, isolation), MCP/Control (tool registry, session/state, authorization bridge), and Platform/Infrastructure (event bus, logging, secure storage, local storage, system info).

### Capture
- **ScreenCaptureKit (macOS 12.3+)** for display, window, and per application inputs. It delivers frames as `CMSampleBuffer` wrapping `IOSurface` backed `CVPixelBuffer`s, which stay on the GPU.
- **AVFoundation** (`AVCaptureSession`) for camera and microphone inputs.
- Every input normalizes to a common GPU resident frame type that the compositor consumes.

### Composition
- **Metal** renders the layer tree of the current shot: positioning, scaling, cropping, and layering inputs, plus transitions between shots.
- **Core Image** (Metal backed) supplies effects without hand writing every shader; drop to raw Metal shaders where custom work or performance demands it.
- The result is a single program frame per tick, still GPU resident. This buffer is the **clean seam** described below.

### Compression
- Compression happens at the sinks; Tingra does not own a standalone compression stage. For streaming, HaishinKit compresses internally (hardware H.264/HEVC via VideoToolbox) as part of output, with settings (bitrate, keyframe interval, profile) driven by the selected destination through the stream configuration. For recording, `AVAssetWriter` performs its own hardware encode.
- Both sinks accept GPU backed pixel buffers directly, so the program frame feeds in without a CPU copy.

### Audio
- **AVAudioEngine / Core Audio** for capturing, mixing, and processing multiple audio inputs (microphones, application audio, media). The mixing graph is host transport; audio effects and taps are plug-ins. Produces the mixed program audio fed to both recording and streaming output.

### Output
- **HaishinKit** (BSD 3-Clause) handles RTMP and SRT output: the connection handling, retry logic, and muxing that Apple provides no framework for. WHIP/WHEP ships as alpha in `RTCHaishinKit`, giving a path to WebRTC output later.
- **Local recording** uses `AVAssetWriter` to write `.mov`/`.mp4` directly, independent of streaming output.

## How HaishinKit is incorporated (minimal adoption approach)

HaishinKit is capable of doing capture, video mixing, and output on its own. Tingra deliberately uses **only its output layer**, for three reasons: it preserves Tingra's distinctive native capture/composition story, it avoids inheriting HaishinKit's architecture across the whole app, and it isolates the dependency to a single, well defined boundary.

**The clean seam:** Tingra's Metal compositor produces the program frame; from that point, HaishinKit's stream objects (`RTMPStream` / `SRTStream` in HaishinKit 2.x) are responsible for compression and output to RTMP/SRT. In practice this means appending Tingra's program video and mixed audio to the stream directly, rather than attaching HaishinKit's own `MediaMixer` capture to the camera or screen.

Concretely:
- Tingra owns `AVCaptureSession` / `SCStream` and the Metal compositor.
- Tingra appends program video and mixed audio buffers to HaishinKit streams; HaishinKit's `MediaMixer` and device capture are not used.
- All compression for streaming, RTMP/SRT connection setup, reconnection, and muxing is delegated to HaishinKit.
- A thin `StreamingService` protocol wraps HaishinKit so the rest of Tingra never imports it directly. This keeps the dependency swappable and the seam explicit; the HaishinKit backed implementation is itself an output plug-in.

```swift
// Sketch of the boundary — not final API.
protocol StreamingService {
    func start(to destination: Destination) async throws
    func send(video frame: CVPixelBuffer, at time: CMTime)
    func send(audio buffer: CMSampleBuffer)
    func stop() async
}

// HaishinKit-backed implementation lives behind this protocol,
// so no other module in Tingra depends on HaishinKit directly.
struct HaishinKitStreamingService: StreamingService { /* ... */ }
```

### Dependency notes / caveats
- **Project home:** the library lives at the HaishinKit GitHub org (`HaishinKit/HaishinKit.swift`, formerly under shogo4405). Latest release at review time: 2.2.5 (March 2026), Swift 6, strict concurrency compliant.
- **License:** HaishinKit is BSD 3-Clause (verified), permissive and compatible with Tingra's MIT license.
- **Modules (2.x):** core `HaishinKit` plus `RTMPHaishinKit`, `SRTHaishinKit`, `RTCHaishinKit` (WHIP/WHEP, alpha), and `MoQTHaishinKit`. Pull in only what Tingra ships: core + RTMP first, SRT when added.
- **Binary targets (resolved):** the only prebuilt piece is the libsrt xcframework (1.5.4) inside `SRTHaishinKit`; all Swift code is source. An RTMP only build is fully source. Adopting SRT means shipping the prebuilt libsrt, or building libsrt from source ourselves. If that ever becomes unacceptable, the `StreamingService` seam lets us swap implementations without touching the rest of the app.
- **Integration:** Swift Package Manager.
- **Platform floor:** ScreenCaptureKit needs macOS 12.3+, ScreenCaptureKit system audio capture needs 13.0+, and HaishinKit 2.x needs macOS 12.0+ and a Swift 6 toolchain. Deployment target for Tingra: **macOS 15, Apple Silicon (arm64) only** — every Apple Silicon Mac runs macOS 15, so the floor excludes no hardware. Development toolchain floor: Xcode 26.6 / Swift 6.3.3, enforced by CI on GitHub Actions (see CLAUDE.md, "Toolchain & CI").

## Repository structure

The repo is a monorepo (multi package workspace) with two top-level folders. **`apps/`** holds the runnable products: `tingra-cli` (see CLI.md), `ingest-simulator` (the local RTMP/SRT test server, see SIMULATOR.md), and the assembled `tingra` app (phase 3). **`packages/`** holds the engine libraries the apps build on. The package names are finalized (reviewed 2026-07-03): **`TingraHost`** (the host/core package), **`TingraPlugInKit`** (the plug-in protocol package, importable by third parties without the engine), and **`TingraEventBus`** (the event bus both build on, see EVENTS.md); first party feature plug-ins land as their own packages alongside them, starting with **`TingraCapturePlugIns`** (camera and microphone). UI packages arrive under `packages/` in phase 2.

## UI layer
- **SwiftUI + AppKit**, with Metal preview content hosted in an `MTKView` (or a `CAMetalLayer` bridged into the view hierarchy).
- The interface exposes presets and shots, inputs, the audio mixer, program/preview monitoring, recording controls, and destination configuration.

## Roadmap sequencing (suggested)

1. **Monorepo scaffold + `tingra-cli devices`.** The `apps/` and `packages/` split, the host/core and plug-in protocol packages under `packages/`, and the `apps/tingra-cli` executable; argument parsing; input discovery with stable IDs (table and JSON output). First milestone: small, shippable, and the selector foundation every later step resolves against.
2. **Camera and microphone inputs + generators** (bars, test tone) as the first plug-ins, registered through the loader code path; `stream --dry-run` resolves inputs and builds the pipeline.
3. **Streaming.** Simulator harness (see SIMULATOR.md) + HaishinKit output behind the `StreamingService` seam; `stream` to the local simulator, then to real Twitch/YouTube. **`tingra-cli` v1 ships here**, the first shippable milestone and the permanent integration test surface for the engine.
4. **MCP server.** The persistent engine process (`tingra-cli serve`, launchd socket activated) with the MCP tool registry: the primary agent interface (see CLI.md and MCP.md).
5. **Local recording** via `AVAssetWriter` (`--record`), deferred until streaming is solid and the need arises.
6. **Metal composition + preview.** The app takes shape around the proven engine: a camera input + a display input composited to an on screen `MTKView`.
7. **Presets, shots, layers, transitions, audio mixer**: flesh out the production feature set.
8. **SRT, multiple destinations, and later WHIP/WHEP** (`RTCHaishinKit`) as support matures.

## Summary

Tingra owns the parts that make it native and distinctive (capture on ScreenCaptureKit/AVFoundation, composition on Metal, audio on AVAudioEngine) and delegates the standardized, undifferentiated compress and send work to HaishinKit behind a thin `StreamingService` protocol. Everything a user would call a feature is a plug-in against a minimal host, first party and third party on the same protocol. The entire media path stays GPU resident from capture to the compression sinks, and the HaishinKit dependency is isolated to a single swappable seam, keeping the project MIT clean and future proof.

Companion documents: GLOSSARY.md is the canonical vocabulary; CLI.md defines `tingra-cli`, the headless front end over the engine; SIMULATOR.md defines the local RTMP/SRT server used for testing; CLOCK.md defines the master clock, program tick, and A/V sync model; EVENTS.md defines the event bus, sinks, and logging/redaction policy; MCP.md defines the engine daemon, its socket transport, and the agent-facing MCP server.
