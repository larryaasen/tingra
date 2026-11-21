# Agent Rules for `packages/`

These rules add to the monorepo root [AGENTS.md](../AGENTS.md), which still applies in full. `CLAUDE.md` in this folder only imports this file (`@AGENTS.md`) and should not be edited separately.

## The Packages

```
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
```

## Architecture
- Keep host responsibilities (plug-in loader/lifecycle, registries, frame transport, session/state, event bus, logging, secure storage, authorization) in the host/core package — the host has no feature a user would directly see.
- Ship every feature — capture inputs, generators, effects, transitions, outputs, local recording, and MCP tool surfaces beyond the host's own introspection tools — as a plug-in registering against the same protocols and registries, whether first-party or third-party.
- The host/plug-in boundary test: if removing it breaks plug-ins in general, it's host; if removing it breaks one capability, it's a plug-in.
- **Protocol first at every framework boundary.** Define the protocol (`Input`, `StreamingService`, ...) in the plug-in protocol package; the plug-in conforms to it; consumers (compositor, CLI, host services, the app) depend on the protocol only, never the framework or library behind it — only the plug-in imports AVFoundation, ScreenCaptureKit, or HaishinKit. Services take dependencies by initializer injection. In the app, deliver services to views through protocol-typed custom `@Environment` keys (`(any SomeServiceProtocol)?`).
- **Follow the timing model in [CLOCK.md](../docs/CLOCK.md).** One master clock (the host time clock) for every timestamp; the host's program tick paces the compositor (pull-based, latest frame wins) — never a display link and never an input's cadence; audio PTS comes from `AVAudioTime` host time, never a synthetic sample-count position; the clock is a protocol-typed injected dependency (synthetic clock in tests), never a global.
- **Follow the events model in [EVENTS.md](../docs/EVENTS.md).** All observability flows as structured events on the host's event bus (group = kind, `app`/`error`/`event`/`network`/`tap`/`trace`; domain = emitting area); sinks (OSLog, CLI console/`--json`, file, status) subscribe and route — code never logs directly. Control plane only: never put per-frame events on the bus. Secrets never become event params.
- **Follow the daemon/transport model in [MCP.md](../docs/MCP.md).** The `serve` daemon is the one owner of the engine and speaks MCP JSON-RPC natively over a per-user Unix domain socket (launchd socket activated); `tingra-cli mcp` is a transparent byte proxy with no protocol logic. Never add a second internal RPC protocol, and never open a TCP listener.
- **`TingraPlugInKit` and `TingraEventBus` are a stability contract** (ARCHITECTURE.md, "Plug-in API stability and versioning"). SemVer: 0.x until the NDI plug-in builds against the binary SDK and loads, 1.0.0 then. Outside a major, never remove or rename public symbols, change signatures or semantics, add protocol requirements without default implementations, or tighten `Sendable`/isolation; deprecate, naming the replacement, at least one minor before removal. CI runs `swift package diagnose-api-breaking-changes` against the latest tag on both. Both are dynamic library products built with Library Evolution (PLUGINS.md, Decision 22), so a `switch` over one of their public enums needs an honest `@unknown default` — only `JSONValue` is `@frozen`.
- **App-tier plug-ins are ExtensionKit extensions** (see [PLUGINS.md](../docs/PLUGINS.md)): they run out of process, always, and talk to the app over the existing MCP JSON-RPC layer carried by `XPCMessageTransport` — never a second RPC protocol. Their descriptors (panes, commands, settings panes) are read from the extension's Info.plist before it runs. `TingraAppPlugInKit` is the extension side and is never imported by the engine or the CLI.

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
The engine is organized as services, each exposing its capabilities through plug-in registries (see [ARCHITECTURE.md](../docs/ARCHITECTURE.md) "Engine services"):

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
- One active stream session at a time in v1 (see [CLI.md](../docs/CLI.md)); don't design around concurrent sessions until that changes. One session may fan out to **N destination legs** — that is still one session, not concurrency.

## Media Pipeline
- Keep the media pipeline GPU-resident from capture through compositing to compression — frames move as `IOSurface`-backed `CVPixelBuffer`s; avoid CPU round-trips.
- **Follow the color conventions in [ARCHITECTURE.md](../docs/ARCHITECTURE.md) ("Color and pixel format conventions").** Working format: IOSurface-backed 32BGRA, SDR, tagged BT.709; delivery: 4:2:0 video-range BT.709 with color info in the bitstream; every `CVPixelBuffer` carries color attachments (an untagged buffer is a defect); conversion happens once, at input normalization — composition and sinks never re-convert.

## Swapping an Implementation Behind a Seam
Third-party dependencies sit behind protocols (HaishinKit behind `StreamingService`, MediaMTX behind the simulator harness) so they can be swapped. When doing a swap, preserve existing functionality and keep the diff minimal:
- Change only what the swap requires: the concrete conforming type, its initializers, and code that depends directly on the swapped thing.
- Leave everything else as it is: unrelated helpers and their signatures, computed properties that don't use the old implementation's APIs, test fixtures and mock data (update only initialization syntax if required), and unrelated logic and formatting.
- Before finishing, confirm the git diff shows only the changes the swap requires.
