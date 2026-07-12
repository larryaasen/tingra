# Tingra — Native Live Streaming for macOS

Tingra is a free, open-source live streaming and production application built exclusively for macOS. It bets on being Mac-first and Swift-native end to end — a real SwiftUI/AppKit app built directly on Apple's media stack, not a cross-platform tool ported to the Mac.

Under the hood, Tingra is written entirely in Swift. It captures displays, windows, and applications through ScreenCaptureKit, and cameras and microphones through AVFoundation. Shot compositing, transitions, and visual effects run on Metal, Apple's modern GPU framework, with Core Image for filters. Compression is handled by VideoToolbox for hardware-accelerated H.264 and HEVC, and audio mixing runs through AVAudioEngine. Captured frames stay GPU-resident from capture through compositing to compression, avoiding costly CPU round-trips. Tingra's real differentiation is combining a genuinely native Swift/SwiftUI codebase with being fully open source, a combination nothing else currently offers.

Tingra offers the essentials creators expect: presets and shots, layered inputs, audio mixing, real-time preview, recording, and streaming to any RTMP or SRT destination, including YouTube, Twitch, and custom servers. The interface is built in SwiftUI and AppKit, so it looks and behaves like a real Mac app rather than a transplanted one.

The project targets a narrow but real gap. Native-feeling streaming apps for the Mac exist (e.g. Ecamm Live), but they are commercial and closed-source. Full-featured open-source tools exist, but none are Swift-native, Metal-based, or built with a native Mac UI framework. Tingra aims to be the missing piece: an open-source, transparent, genuinely Mac-native broadcaster — not necessarily a faster one.

Tingra is for streamers, educators, podcasters, and developers who want a fast, focused, native tool — and who believe the best Mac software is built with the platform, not around it.

## Getting started: the CLI and MCP server

Tingra ships first as `tingra-cli`, a headless front end over the engine. It can stream on its own, and it exposes the engine to AI agents (Claude and others) as an [MCP](https://modelcontextprotocol.io) server. This section takes a first-time user from install to controlling a stream from Claude.

> **Requirements:** an Apple Silicon Mac (arm64) running macOS 15 (Sequoia) or later. Intel Macs are not supported.

### 1. Install

Tingra is distributed as a signed, notarized binary through a Homebrew tap:

```sh
brew install larryaasen/tingra/tingra-cli
```

The tap downloads the prebuilt binary — it never builds from source, so the signing identity stays stable and macOS keeps your Camera and Microphone permissions across updates.

### 2. Set up the MCP server

The MCP server runs as a launchd **LaunchAgent** so the daemon is its own process. This matters for permissions: camera and microphone prompts are attributed to **Tingra**, not to whichever agent app connected, and a single grant sticks across updates. Register it once:

```sh
tingra-cli serve --install
```

That installs `~/Library/LaunchAgents/com.moonwink.tingra.serve.plist` and loads it. The daemon starts automatically the first time an agent connects and idle-exits when quiet — you never start or stop it by hand. To remove it later:

```sh
tingra-cli serve --uninstall
```

Re-run `tingra-cli serve --install` after a `brew upgrade` so the LaunchAgent points at the new version.

### 3. Verify

Confirm the CLI works — these run in-process and need no daemon:

```sh
tingra-cli version           # prints: tingra-cli 0.1.0
tingra-cli devices           # lists your cameras and microphones
```

The first time you list or stream a camera or microphone, macOS prompts for Camera/Microphone access — grant it in **System Settings › Privacy & Security**. To verify a streaming destination without going live (no media is sent), use `probe`:

```sh
tingra-cli probe --url rtmp://live.twitch.tv/app --key <your-stream-key>
```

To confirm the MCP daemon itself answers, you can run it in the foreground in one terminal (`tingra-cli serve`) and connect the proxy in another (`tingra-cli mcp`), but with the LaunchAgent installed the usual path is simply to point Claude at it (next step).

### 4. Use it from Claude

The agent-facing entry point is `tingra-cli mcp` — a thin stdio proxy that forwards to the daemon. Point your Claude client at it.

**Claude Desktop** — Claude Desktop doesn't yet have a form for adding a local MCP server by command, so this still means editing a config file, but Claude opens it for you:

1. Open **Claude → Settings → Developer**.
2. Click **Edit Config** — this opens `claude_desktop_config.json` in your default editor (creating it if it doesn't exist yet).
3. Add the `tingra` entry below (merge it into the existing `mcpServers` object if there is one; use the absolute path, since the app may not have Homebrew's `bin` on its `PATH`), save, and quit and reopen Claude Desktop:

```json
{
  "mcpServers": {
    "tingra": {
      "command": "/opt/homebrew/bin/tingra-cli",
      "args": ["mcp"]
    }
  }
}
```

Tingra's tools appear once Claude Desktop reopens.

**Claude Code** — register the server from the terminal:

```sh
claude mcp add tingra -- /opt/homebrew/bin/tingra-cli mcp
```

Once connected, ask Claude in plain language — it calls the matching tool:

| Ask Claude… | Tool it calls |
|-------------|---------------|
| "List my cameras and microphones." | `devices_list` |
| "Check whether `rtmp://live.twitch.tv/app` with this key is reachable." | `probe` |
| "Start streaming color bars and a test tone to `rtmp://live.twitch.tv/app` with key `live_…`." | `stream_start` |
| "What's the current stream status?" | `stream_status` |
| "Stop the stream." | `stream_stop` |

For example:

> **You:** Start streaming SMPTE bars and a 440 Hz tone to my Twitch ingest at rtmp://live.twitch.tv/app — the key is `live_1234567890`.
>
> **Claude:** *(calls `stream_start`)* Streaming is live — generators (bars + tone) to `rtmp://live.twitch.tv/app`. I'll leave it running; say "stop the stream" when you're done.

Stream keys are secrets: they go straight into Tingra's Keychain-backed secure storage and are never echoed back — any status or log that references one shows it redacted (`live_12…`). One stream runs at a time in v1; asking to start another while one is live returns a clear error naming the active session.

## Packages and apps

The monorepo splits into `packages/` (the engine libraries) and `apps/` (the runnable products). Every package and app is listed here with its public types; this listing is kept current as code lands (see [ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design behind each piece).

### `packages/TingraEventBus`

The zero-dependency event bus: the structured event spine every part of the engine and every plug-in reports through (see [EVENTS.md](docs/EVENTS.md)).

- `EventBus` — publishes structured events to subscribing sinks; includes per-group conveniences (`app`, `error`, `event`, `network`, `tap`, `trace`).
- `EventBusEvent` — one structured event: date, group, domain, name, params, and the emitting call site.
- `EventGroup` — the closed routing axis: what kind of event it is (`app`, `error`, `event`, `network`, `tap`, `trace`).
- `EventDomain` — the open attribution axis: which engine service or plug-in emitted the event.
- `EventValue` — a small `Sendable`, `Codable` param value (string, int, double, bool) that serializes as a bare JSON value and renders as bare text in human formats.
- `EventSink` — the subscriber protocol every sink conforms to; `EventBus.attach(_:)` runs a sink over its own stream, and `EventBus.shutdown()` drains all sinks at orderly teardown.

### `packages/TingraPlugInKit`

The plug-in protocol package: the stability contract first- and third-party plug-ins build against, importable without the engine (see [ARCHITECTURE.md](docs/ARCHITECTURE.md), "Plug-in API stability and versioning").

- `Input` — the protocol for anything producing video or audio frames: cameras, displays, microphones, media, generators; carries the stable identifier, user-facing name, and kind that discovery lists, with `frames()` and `audio()` streams (each defaulting to an already-finished stream for the media the input does not produce).
- `InputID` — the stable identifier for an input, as surfaced by input discovery.
- `InputKind` — the kind of input (camera, microphone, display, generator), driving discovery grouping and selector resolution.
- `InputRegistering` — the registration seam where input plug-ins attach (register on connect, unregister on disconnect); the host's `InputRegistry` conforms.
- `CapturedFrame` — one GPU-resident video frame plus its presentation time on the master clock; `@unchecked Sendable` under the frame ownership rule (ARCHITECTURE.md, "Frame ownership across the `Input` seam").
- `CapturedAudio` — one captured audio buffer whose PTS is the actual host time of capture; the audio half of the frame ownership rule.
- `ErrorIdentifier` — the stable, machine-readable failure identifiers error events carry (`inputNotFound`, `authorizationDenied`, `recordingFailed`, …); the registry lives in CLI.md, and identifiers are append-only, never renamed.
- `StreamingService` — the output seam: connects, appends program media on the shared session timeline, reports connection events, and stops (HaishinKit lives behind this protocol).
- `StreamingServiceProvider` — what an output plug-in registers: a factory keyed by destination URL scheme that creates a configured `StreamingService` per stream.
- `StreamingServiceEvent` — a connection event reported after a successful start (`connectionLost`); the session drives reconnect policy from it.
- `StreamingServiceError` — the error currency of `StreamingService.start(to:)` (`unsupportedDestination`, `connectionRejected`), each mapped to its stable error identifier.
- `StreamingStatistics` — a point-in-time snapshot of a service's delivery counters, feeding the periodic `stream.stats` events.
- `StreamConfiguration` — the compression and program settings a stream session runs with (resolution, frame rate, codecs, bitrates, and the `includesVideo`/`includesAudio` track topology the recording sink needs up front); contains no secrets. Shared by the streaming and recording sinks.
- `OutputID` — the stable identifier for a registered output (streaming or recording).
- `OutputRegistering` — the registration seam where output plug-ins attach — both streaming (by URL scheme) and recording (by file extension) providers; the host's `OutputRegistry` conforms.
- `Destination` — a configured streaming target: URL plus optional stream key (deliberately not `Codable` — the key is a secret).
- `RecordingService` — the recording seam: opens a local file, appends the same program media the stream gets, reports a terminal write failure, and finalizes (`AVAssetWriter` lives behind this protocol). A narrower sibling of `StreamingService` — no destination, no reconnect.
- `RecordingServiceProvider` — what a recording plug-in registers: a factory keyed by file extension (`mov`/`mp4`) that creates a configured `RecordingService` per recording.
- `RecordingServiceEvent` — a recording event reported after a successful start (`failed`); a file has no reconnect, so a write failure is terminal.
- `RecordingServiceError` — the error currency of `RecordingService.start(to:)` (`unwritableDestination`, `writerNotReady`), each mapped to the `recordingFailed` identifier.
- `RecordingFile` — where a recording is written: a local file URL plus its container format (`mov`/`mp4`); the recording counterpart to `Destination`, carrying no secret.
- `IdentifiedError` — the protocol the engine's error enums (`StreamingServiceError`, `RecordingServiceError`, `CaptureInputError`, `InputSelectorError`) conform to, so a front end maps any of them to its stable `ErrorIdentifier` without knowing the concrete type.
- `Tool` — the MCP tool seam: a control the engine exposes to agents, with a machine name, a JSON-Schema input, and a `call(_:)` returning structured JSON; plug-in contributed like inputs and outputs.
- `ToolError` — a structured, actionable tool failure keyed off the append-only `ErrorIdentifier` registry (never message wording).
- `ToolRegistering` — the registration seam where tool plug-ins attach; the host's `ToolRegistry` conforms.
- `JSONValue` — an arbitrary JSON value (the currency of the tool seam): scalars, arrays, and objects, encoding as natural JSON; more general than the event bus's scalar-only `EventValue`.
- `EngineClock` — the master clock seam: current time and the absolute-deadline tick stream (see [CLOCK.md](docs/CLOCK.md)).
- `PlugIn` — the protocol every plug-in conforms to: identity plus an activation hook for registering capabilities.
- `PlugInID` — the stable reverse-DNS identifier for a plug-in; doubles as its event domain.
- `PlugInContext` — the host infrastructure handed to a plug-in at activation: the event bus, the clock, and the input, output, and tool registration seams.

### `packages/TingraHost`

The host/core package: plug-in loading, registries, frame transport, session/state, secure storage, and authorization — the minimal core that is not a plug-in (see [ARCHITECTURE.md](docs/ARCHITECTURE.md), "Engine model: host and plug-ins").

- `HostClock` — the production `EngineClock`: the host time clock with a `ContinuousClock`-based absolute-deadline tick loop.
- `InputRegistry` — the actor where input plug-ins register the inputs they contribute and the engine resolves them from (by stable ID, listing index, or unique name substring via `resolveInput(selector:ofKind:)`); the host's concrete `InputRegistering`.
- `InputRegistryError` — errors thrown by the registry (e.g. registering a duplicate input identifier).
- `InputSelectorError` — selector resolution failures (`notFound`, `ambiguous`), each mapped to its stable error identifier.
- `PlugInLoader` — the host's plug-in lifecycle: activates plug-ins against a `PlugInContext`, reporting each outcome on the event bus; a throwing plug-in is skipped, never fatal.
- `OSLogSink` — the system-of-record sink: routes every event to OSLog (`subsystem` `com.moonwink.tingra`, `category` = domain), params `.private`. `tingra-cli` skips attaching it when standard error is a terminal — the OS's own terminal mirror already echoes the process's events there (see EVENTS.md, "OSLog sink").
- `LogLineFormatter` — the one shared human log line format (`LEVEL MM-DD-YYYY HH:MM:SS.mmm TZ [SSSS] @ domain name key=value`), reused by every text sink so each front end logs identically — the CLI's console (human mode) and file sinks and the app's console sink (see EVENTS.md, "The human log line format").
- `LogSession` — the four-digit log session id stamped into every log line: incremented once per cold start and persisted in Application Support, a reliable cold-start anchor (distinct from the engine session in GLOSSARY.md).
- `OutputRegistry` — the actor where output plug-ins register their providers — streaming (resolved by destination URL scheme) and recording (resolved by file extension) — in one registry; the host's concrete `OutputRegistering`.
- `OutputRegistryError` — errors thrown by the output registry (a scheme, or a recording file extension, already served by another provider).
- `ProgramPacer` — the tick-paced latest-wins video pacing for the CLI era: one frame per program tick, restamped with the tick's time, re-sending the held frame across an input stall (see CLOCK.md, "The tick before composition exists").
- `StreamSession` — one live stream: owns the shared timeline (`T0`), pumps paced video and pass-through audio into the streaming service — and, when `--record` is set, the same media into a parallel recording sink — emits the `stream.*` (and `recording.*`) status events, drives the reconnect policy (attempts, delay, and the stability window that keeps a flapping connection from reconnecting forever), and finalizes the recording on every teardown path.
- `ToolRegistry` — the actor where tool plug-ins register the MCP tools they contribute and the MCP/Control service lists and resolves them from; the host's concrete `ToolRegistering`.
- `ToolRegistryError` — errors thrown by the tool registry (a tool name already registered).
- `StatusSink` — the status sink: retains the latest control-plane status events for point reads (`stream_status`) and re-broadcasts them to subscribers (the MCP notifications), so status is reported without polling (see EVENTS.md, "Sinks").

### `packages/TingraCapturePlugIns`

The first party capture plug-ins: camera, microphone, and display discovery and capture, and the device connection/disconnection events on the bus. AVFoundation, Core Audio, and ScreenCaptureKit are imported only inside this package, behind the `Input` seam.

- `AVFoundationCapturePlugIn` — contributes the Mac's cameras and microphones as inputs with stable identifiers (`AVCaptureDevice.uniqueID`), backed by `AVCaptureSession` (camera; IOSurface 32BGRA, BT.709 tagged at the seam) and an `AVAudioEngine` input tap (microphone; PTS from `AVAudioTime` host time), and keeps the registry current from the framework's device notifications, reporting each change as a `device.connected`/`device.disconnected` event — never polling.
- `ScreenCaptureKitCapturePlugIn` — contributes the Mac's displays as inputs (`InputKind.display`), discovered through CoreGraphics (no Screen Recording prompt; stable `CGDisplayCreateUUIDFromDisplayID` identifiers that survive reconnection) and captured via an `SCStream` (IOSurface 32BGRA, BT.709 tagged at the seam, host-time PTS, idle frames skipped). A separate plug-in from the AVFoundation one — a different framework and a different TCC permission (Screen Recording, not Camera).
- `SystemDefaultInputs` — the system default camera and microphone as input identifiers, for resolving the `stream` defaults without importing AVFoundation elsewhere.

### `packages/TingraGeneratorPlugIns`

The first party generator plug-ins — inputs that synthesize their content from the injected clock, so they run anywhere with no camera, microphone, or TCC: the permanent CI test surface.

- `GeneratorPlugIn` — contributes the built-in generators as inputs through the same registration seam as capture.
- `BarsGenerator` — SMPTE color bars with burned in timecode (`--video-generator bars`): one IOSurface-backed 32BGRA, BT.709-tagged frame per clock tick.
- `AlignmentGenerator` — industry-standard-style alignment pattern (`--video-generator alignment`): a cached crosshatch/alignment frame generated once at runtime and copied into fresh buffers thereafter.
- `PlugeGenerator` — PLUGE black-level calibration pattern (`--video-generator pluge`): reference-black background with below-black, near-black, and shadow-detail patches for monitor setup.
- `PlugeStrictGenerator` — stricter broadcast-style PLUGE pattern (`--video-generator pluge-strict`): a sparse reference-black field with the classic below-black / reference-black / above-black trio.
- `ToneGenerator` — the 440 Hz test tone (`--audio-generator tone`): mono float32 buffers with phase continuity, one per clock tick.

### `packages/TingraComposition`

The composition engine library (roadmap steps 6–7): the tick-paced Metal/Core Image compositor, the layer tree it renders, and the presets and shots it switches among. A host-side library — not a plug-in, and not folded into the minimal `TingraHost` — depending only on the protocol package and the event bus, so it stays testable with a synthetic clock and a mock renderer (see [ARCHITECTURE.md](docs/ARCHITECTURE.md), "Composition").

- `Compositor` — the tick-paced engine: holds a latest-wins slot per input and, on each program tick, renders the current shot's layer tree over every slot's latest frame, yielding one program frame stamped with the tick's master clock time. Holds a loaded preset's shots, cuts among them with `take(shotID:)` (`loadPreset(_:)`, `setShot(_:)`), edits one live with `updateShot(_:)` — the loaded preset's shot with the matching id is replaced in place and, when it is on program, rendered from the very next tick — and manages the pool with `addShot(_:at:)` (adding is not taking: the program is untouched) and `removeShot(shotID:)` (removing the shot on program cuts to the adjacent shot — never a dead program). The step-6 realization of the model `ProgramPacer` stood in for — same tick, slots, and timestamps, "take the latest frame" replaced by "render the layer tree"; renders a live background canvas from the first tick.
- `Project` — the saved document for a whole show: a versioned, plain `Codable` value type holding the presets (v1 of the document holds presets only; destinations and settings join it in later versions). Decoding a document newer than the build understands throws rather than silently loading it.
- `Preset` — a named, persisted collection of shots you cut among during a live session; a plain `Codable` value type (the project/scripting contract). Active-shot selection is session state on the compositor, not part of the saved preset.
- `PresetID` — a stable, string-backed identifier for a preset (a fresh UUID by default).
- `Shot` — a short-term composition with a stable `id` and user-facing `name`: an ordered layer tree (bottom to top) over a `BackgroundColor`. `Codable` as part of the persisted preset.
- `ShotID` — a stable, string-backed identifier for a shot, used to take it to program (a fresh UUID by default, or a fixed token for a built-in shot).
- `Layer` — one positioned element: an input referenced by `InputID`, placed in a normalized top-left-origin destination `frame` with an `opacity`. `Codable` with the `frame` flattened to `x`/`y`/`width`/`height` keys.
- `BackgroundColor` — a straight RGBA background the layers composite over (defaults to opaque black).
- `ProgramFormat` — the program's output geometry and rate (width, height, frame rate) every frame is rendered at.
- `ShotRenderer` — the internal seam between the compositor's tick-paced control flow and the pixel work; task-confined, so it needs no `Sendable`, and swappable for a mock in tests.
- `CoreImageShotRenderer` — the default renderer: composites the layer tree with a Metal-backed `CIContext`, GPU-resident, into an IOSurface-backed 32BGRA program buffer tagged BT.709 (a software `CIContext` makes the compositing math unit-testable with no GPU).

### `packages/TingraOutputPlugIns`

The first party streaming output plug-in: the HaishinKit-backed `StreamingService` for RTMP/RTMPS destinations. HaishinKit (and its Logboard logging façade, rerouted to OSLog) is imported only inside this package, behind the `StreamingService` seam.

- `HaishinKitOutputPlugIn` — contributes the RTMP/RTMPS provider through the output registration seam.
- `RTMPStreamingServiceProvider` — the provider serving `rtmp://` and `rtmps://` destinations; creates a fresh service per stream.
- `HaishinKitStreamingService` — the concrete service: connects and publishes, compresses internally (VideoToolbox via HaishinKit), appends program video as uncompressed sample buffers and audio as PCM buffers carrying the session-timeline PTS, watches for connection loss, and reports delivery counters.

### `packages/TingraRecordingPlugIns`

The first party local recording plug-in: the `AVAssetWriter`-backed `RecordingService` writing the program to a local `.mov`/`.mp4`, independent of streaming. AVFoundation is imported only inside this package (behind the `RecordingService` seam), and it pulls in neither HaishinKit nor Logboard, so `TingraOutputPlugIns` stays the sole HaishinKit importer.

- `RecordingPlugIn` — contributes the `.mov`/`.mp4` recording provider through the same output registration seam as streaming.
- `AVAssetWriterRecordingServiceProvider` — the provider serving `.mov` and `.mp4` targets; creates a fresh recording service per recording.
- `AVAssetWriterRecordingService` — the concrete service: orchestrates open, append, finalize, and terminal-failure reporting over a writer backend, so its lifecycle is unit-testable without touching disk.

### `packages/TingraMCP`

The MCP/Control service (see [MCP.md](docs/MCP.md)): the hand-rolled MCP JSON-RPC layer, the engine daemon, the transparent stdio↔socket proxy, and the first-party control tools that mirror the CLI surface. Speaks MCP verbatim on the wire but takes no third-party dependency — the JSON-RPC framing is a few hundred lines behind this seam rather than the official swift-sdk's SwiftNIO/swift-log/eventsource stack.

- `Daemon` — the engine daemon (`tingra-cli serve`): accepts connections on a Unix domain socket, verifies each peer's uid, serves each as an independent `MCPSession` against the shared engine, and idle-exits when quiet but never mid-stream. `manual(socketPath:…)` binds its own socket; the launchd socket-activated path uses `init` with a supplied descriptor.
- `MCPSession` — one per-connection MCP session: the `initialize` handshake (carrying the daemon build version), `tools/list`, `tools/call` dispatch, and status-change notifications fed by the status sink.
- `StreamCoordinator` — owns the one active stream in v1 on behalf of the stream tools; reuses the host's `StreamSession`, confirms the stream went live before `stream_start` returns, and keys `stream_status`/`stream_stop` off the session id.
- `StreamDefaults` — the system default input identifiers, injected so the coordinator never imports the capture package.
- `ControlToolsPlugIn` — registers the first-party tools (`devices_list`, `probe`, `stream_start`, `stream_status`, `stream_stop`) through the same `ToolRegistering` seam a third party uses.
- `DaemonInfo` — the daemon identity (name, version) reported in the `initialize` result so a client can detect version skew.
- `StdioSocketProxy` — the transparent byte pipe behind `tingra-cli mcp`: copies bytes between stdin/stdout and the daemon socket with no protocol logic (stdin EOF closes the connection; the connection closing exits).
- `SocketLocation` — the per-user socket path (`~/Library/Application Support/Tingra/tingra.sock`) and its `0700` directory setup.
- `LaunchAgent` — the daemon's launchd LaunchAgent: renders the socket-activation plist and installs/uninstalls it (`serve --install`/`--uninstall`), so the daemon is launchd-parented and TCC prompts name Tingra (MCP.md, "Lifecycle").
- `LaunchAgentError` — a developer-facing failure from installing or removing the LaunchAgent (directory/plist not writable, `launchctl` reported nonzero), each stating what to fix.
- `LaunchdSocket` — adopts the launchd-owned listening socket under socket activation (wrapping the `CTingraLaunchd` C shim over `launch_activate_socket`); returns nil when not launchd-parented, so the daemon falls back to manual mode.
- `JSONRPCID`, `JSONRPCError`, `JSONRPCErrorCode`, `JSONRPCResponse`, `JSONRPCNotification`, `JSONRPCIncoming` — the documented JSON-RPC 2.0 wire types, so direct socket clients can script the engine without the proxy.
- `MCPProtocol` — the MCP method names, notification names, and the protocol version the daemon speaks.

### `apps/tingra-cli`

The headless front end over the engine (see [CLI.md](docs/CLI.md)): one invocation selects inputs, configures compression, and streams. An executable, so it exposes no public types; its surface is its subcommands — `devices` (input discovery: human table and stable `--json`; `--watch` streams live device connect/disconnect events), `stream` (live streaming with `--reconnect`, `--duration`, optional `--record` to a local `.mov`/`.mp4`, clean Ctrl-C/SIGTERM stop, the `stream.*`/`recording.*` status events, and `--dry-run` plan reporting), `probe` (validate a destination URL/key without going live), `serve` (the persistent engine daemon behind a Unix domain socket — manual foreground mode, or launchd socket-activated in the product path; `--install`/`--uninstall` register and remove the LaunchAgent), `mcp` (the transparent stdio↔socket proxy agents point at), and `version`.

### `apps/ingest-simulator`

The local RTMP/SRT ingest server used for integration testing (see [SIMULATOR.md](docs/SIMULATOR.md)): a pinned MediaMTX binary wrapped in `sim.sh` (`start | stop | status | verify`) with key-validating paths (`mediamtx.yml`, `keys.env`). Test-only — never linked into the product. The streaming integration scenarios run against it via `scripts/integration-test.sh`.

### `apps/tingra`

The assembled SwiftUI/AppKit app (phase 3), scaffolded at roadmap step 6: it takes shape around the proven engine — a camera input and a display input composited by `TingraComposition` and shown live in an on-screen `MTKView`. An executable, so it exposes no public API beyond its `@main` entry; its internal surface is `EngineModel` (the `@Observable @MainActor` model that boots the host, activates the capture and generator plug-ins through the same `PlugInContext` the CLI uses, drives the compositor, loads — or seeds, on first launch — the session preset from the autosaved project document, applies layer-tree edits to the active shot, manages the preset's shots — add, duplicate, rename, remove — and rebinds the built-in roles' layers when a picker's selection changes), `ContentView` (camera/display pickers and, over the preview, a shot switcher that also manages shots: an Add Shot button plus a per-shot context menu with Duplicate, Rename…, and Remove Shot), `LayerTreeEditorView` (the layer-tree editor: add a layer bound to any discovered camera or display, remove, reorder, and adjust a layer's frame and opacity with live sliders — every edit on program at the next tick, and autosaved to the project file), `LayerTreeEdit` (the pure, unit-tested edit operations over a `Shot`, including the rebind a picker change applies), `ShotEdit` (the pure, unit-tested shot-management operations: a new empty shot, a duplicate under a fresh id, a rename that ignores empty names), `ProjectStore` (loads and autosaves the `.tingraproject` document under `~/Library/Application Support/Tingra`, setting an unreadable file aside rather than overwriting it), `ProgramPreviewView` (the Core Image `MTKView` that samples the program at display rate), and `ProgramLayout` (the pure, unit-tested arrangement that seeds a fresh project's picture-in-picture, display, and camera shots). User-facing strings are localized (`Localizable.xcstrings`, en/de/es). Bundling into a signed, notarized `.app` is deferred packaging, tracked alongside the CLI's distribution recipe.

## License

Tingra is released under the [MIT License](LICENSE).
