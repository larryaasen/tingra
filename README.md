# Tingra — Native Live Streaming for macOS

Tingra is a free, open-source live streaming and production application built exclusively for macOS. It bets on being Mac-first and Swift-native end to end — a real SwiftUI/AppKit app built directly on Apple's media stack, not a cross-platform tool ported to the Mac.

Under the hood, Tingra is written entirely in Swift. It captures displays, windows, and applications through ScreenCaptureKit, and cameras and microphones through AVFoundation. Shot compositing, transitions, and visual effects run on Metal, Apple's modern GPU framework, with Core Image for filters. Compression is handled by VideoToolbox for hardware-accelerated H.264 and HEVC, and audio mixing runs through AVAudioEngine. Captured frames stay GPU-resident from capture through compositing to compression, avoiding costly CPU round-trips. Tingra's real differentiation is combining a genuinely native Swift/SwiftUI codebase with being fully open source, a combination nothing else currently offers.

Tingra offers the essentials creators expect: presets and shots, layered inputs, audio mixing, real-time preview, recording, and streaming to any RTMP or SRT destination, including YouTube, Twitch, and custom servers. The interface is built in SwiftUI and AppKit, so it looks and behaves like a real Mac app rather than a transplanted one.

The project targets a narrow but real gap. Native-feeling streaming apps for the Mac exist (e.g. Ecamm Live), but they are commercial and closed-source. Full-featured open-source tools exist, but none are Swift-native, Metal-based, or built with a native Mac UI framework. Tingra aims to be the missing piece: an open-source, transparent, genuinely Mac-native broadcaster — not necessarily a faster one.

Tingra is for streamers, educators, podcasters, and developers who want a fast, focused, native tool — and who believe the best Mac software is built with the platform, not around it.

## Packages and apps

The monorepo splits into `packages/` (the engine libraries) and `apps/` (the runnable products). Every package and app is listed here with its public types; this listing is kept current as code lands (see [ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design behind each piece).

### `packages/TingraEventBus`

The zero-dependency event bus: the structured event spine every part of the engine and every plug-in reports through (see [EVENTS.md](docs/EVENTS.md)).

- `EventBus` — publishes structured events to subscribing sinks, redacting sensitive param values before any sink sees them; includes per-group conveniences (`app`, `error`, `event`, `network`, `tap`, `trace`).
- `EventBusEvent` — one structured event: date, group, domain, name, params, and the emitting call site.
- `EventGroup` — the closed routing axis: what kind of event it is (`app`, `error`, `event`, `network`, `tap`, `trace`).
- `EventDomain` — the open attribution axis: which engine service or plug-in emitted the event.
- `EventValue` — a small `Sendable`, `Codable` param value (string, int, double, bool) that serializes as a bare JSON value and renders as bare text in human formats.
- `EventSink` — the subscriber protocol every sink conforms to; `EventBus.attach(_:)` runs a sink over its own stream, and `EventBus.shutdown()` drains all sinks at orderly teardown.

### `packages/TingraPlugInKit`

The plug-in protocol package: the stability contract first- and third-party plug-ins build against, importable without the engine (see [ARCHITECTURE.md](docs/ARCHITECTURE.md), "Plug-in API stability and versioning").

- `Input` — the protocol for anything producing video or audio frames: cameras, displays, microphones, media, generators; carries the stable identifier, user-facing name, and kind that discovery lists, with `frames()` and `audio()` streams (each defaulting to an already-finished stream for the media the input does not produce).
- `InputID` — the stable identifier for an input, as surfaced by input discovery.
- `InputKind` — the kind of input (camera, microphone, generator), driving discovery grouping and selector resolution.
- `InputRegistering` — the registration seam where input plug-ins attach (register on connect, unregister on disconnect); the host's `InputRegistry` conforms.
- `CapturedFrame` — one GPU-resident video frame plus its presentation time on the master clock; `@unchecked Sendable` under the frame ownership rule (ARCHITECTURE.md, "Frame ownership across the `Input` seam").
- `CapturedAudio` — one captured audio buffer whose PTS is the actual host time of capture; the audio half of the frame ownership rule.
- `ErrorIdentifier` — the stable, machine-readable failure identifiers error events carry (`inputNotFound`, `authorizationDenied`, …); the registry lives in CLI.md, and identifiers are append-only, never renamed.
- `StreamingService` — the output seam: connects, appends program media on the shared session timeline, reports connection events, and stops (HaishinKit lives behind this protocol).
- `StreamingServiceProvider` — what an output plug-in registers: a factory keyed by destination URL scheme that creates a configured `StreamingService` per stream.
- `StreamingServiceEvent` — a connection event reported after a successful start (`connectionLost`); the session drives reconnect policy from it.
- `StreamingServiceError` — the error currency of `StreamingService.start(to:)` (`unsupportedDestination`, `connectionRejected`), each mapped to its stable error identifier.
- `StreamingStatistics` — a point-in-time snapshot of a service's delivery counters, feeding the periodic `stream.stats` events.
- `StreamConfiguration` — the compression and program settings a stream session runs with (resolution, frame rate, codecs, bitrates); contains no secrets.
- `OutputID` — the stable identifier for a registered output.
- `OutputRegistering` — the registration seam where output plug-ins attach; the host's `OutputRegistry` conforms.
- `Destination` — a configured streaming target: URL plus optional stream key (deliberately not `Codable` — the key is a secret).
- `IdentifiedError` — the protocol the engine's error enums (`StreamingServiceError`, `CaptureInputError`, `InputSelectorError`) conform to, so a front end maps any of them to its stable `ErrorIdentifier` without knowing the concrete type.
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
- `OutputRegistry` — the actor where output plug-ins register their streaming service providers and the engine resolves a destination's URL scheme to a provider; the host's concrete `OutputRegistering`.
- `OutputRegistryError` — errors thrown by the output registry (a scheme already served by another provider).
- `ProgramPacer` — the tick-paced latest-wins video pacing for the CLI era: one frame per program tick, restamped with the tick's time, re-sending the held frame across an input stall (see CLOCK.md, "The tick before composition exists").
- `StreamSession` — one live stream: owns the shared timeline (`T0`), pumps paced video and pass-through audio into the streaming service, emits the `stream.*` status events, and drives the reconnect policy (attempts, delay, and the stability window that keeps a flapping connection from reconnecting forever).
- `ToolRegistry` — the actor where tool plug-ins register the MCP tools they contribute and the MCP/Control service lists and resolves them from; the host's concrete `ToolRegistering`.
- `ToolRegistryError` — errors thrown by the tool registry (a tool name already registered).
- `StatusSink` — the status sink: retains the latest control-plane status events for point reads (`stream_status`) and re-broadcasts them to subscribers (the MCP notifications), so status is reported without polling (see EVENTS.md, "Sinks").

### `packages/TingraCapturePlugIns`

The first party capture plug-ins: camera and microphone discovery and capture, and the device connection/disconnection events on the bus. AVFoundation and Core Audio are imported only inside this package, behind the `Input` seam.

- `AVFoundationCapturePlugIn` — contributes the Mac's cameras and microphones as inputs with stable identifiers (`AVCaptureDevice.uniqueID`), backed by `AVCaptureSession` (camera; IOSurface 32BGRA, BT.709 tagged at the seam) and an `AVAudioEngine` input tap (microphone; PTS from `AVAudioTime` host time), and keeps the registry current from the framework's device notifications, reporting each change as a `device.connected`/`device.disconnected` event — never polling.
- `SystemDefaultInputs` — the system default camera and microphone as input identifiers, for resolving the `stream` defaults without importing AVFoundation elsewhere.

### `packages/TingraGeneratorPlugIns`

The first party generator plug-ins — inputs that synthesize their content from the injected clock, so they run anywhere with no camera, microphone, or TCC: the permanent CI test surface.

- `GeneratorPlugIn` — contributes the built-in generators as inputs through the same registration seam as capture.
- `BarsGenerator` — SMPTE color bars with burned in timecode (`--video-generator bars`): one IOSurface-backed 32BGRA, BT.709-tagged frame per clock tick.
- `AlignmentGenerator` — industry-standard-style alignment pattern (`--video-generator alignment`): a cached crosshatch/alignment frame generated once at runtime and copied into fresh buffers thereafter.
- `PlugeGenerator` — PLUGE black-level calibration pattern (`--video-generator pluge`): reference-black background with below-black, near-black, and shadow-detail patches for monitor setup.
- `PlugeStrictGenerator` — stricter broadcast-style PLUGE pattern (`--video-generator pluge-strict`): a sparse reference-black field with the classic below-black / reference-black / above-black trio.
- `ToneGenerator` — the 440 Hz test tone (`--audio-generator tone`): mono float32 buffers with phase continuity, one per clock tick.

### `packages/TingraOutputPlugIns`

The first party streaming output plug-in: the HaishinKit-backed `StreamingService` for RTMP/RTMPS destinations. HaishinKit (and its Logboard logging façade, rerouted to OSLog) is imported only inside this package, behind the `StreamingService` seam.

- `HaishinKitOutputPlugIn` — contributes the RTMP/RTMPS provider through the output registration seam.
- `RTMPStreamingServiceProvider` — the provider serving `rtmp://` and `rtmps://` destinations; creates a fresh service per stream.
- `HaishinKitStreamingService` — the concrete service: connects and publishes, compresses internally (VideoToolbox via HaishinKit), appends program video as uncompressed sample buffers and audio as PCM buffers carrying the session-timeline PTS, watches for connection loss, and reports delivery counters.

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
- `JSONRPCID`, `JSONRPCError`, `JSONRPCErrorCode`, `JSONRPCResponse`, `JSONRPCNotification`, `JSONRPCIncoming` — the documented JSON-RPC 2.0 wire types, so direct socket clients can script the engine without the proxy.
- `MCPProtocol` — the MCP method names, notification names, and the protocol version the daemon speaks.

### `apps/tingra-cli`

The headless front end over the engine (see [CLI.md](docs/CLI.md)): one invocation selects inputs, configures compression, and streams. An executable, so it exposes no public types; its surface is its subcommands — `devices` (input discovery: human table and stable `--json`; `--watch` streams live device connect/disconnect events), `stream` (live streaming with `--reconnect`, `--duration`, clean Ctrl-C/SIGTERM stop, the `stream.*` status events, and `--dry-run` plan reporting), `probe` (validate a destination URL/key without going live), `serve` (the persistent engine daemon behind a Unix domain socket, manual mode), `mcp` (the transparent stdio↔socket proxy agents point at), and `version`.

### `apps/ingest-simulator`

The local RTMP/SRT ingest server used for integration testing (see [SIMULATOR.md](docs/SIMULATOR.md)): a pinned MediaMTX binary wrapped in `sim.sh` (`start | stop | status | verify`) with key-validating paths (`mediamtx.yml`, `keys.env`). Test-only — never linked into the product. The streaming integration scenarios run against it via `scripts/integration-test.sh`.

## License

Tingra is released under the [MIT License](LICENSE).
