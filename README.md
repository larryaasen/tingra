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

- `Input` — the protocol for anything producing video or audio frames: cameras, displays, microphones, media, generators; carries the stable identifier, user-facing name, and kind that discovery lists.
- `InputID` — the stable identifier for an input, as surfaced by input discovery.
- `InputKind` — the kind of input (camera, microphone), driving discovery grouping and selector resolution.
- `InputRegistering` — the registration seam where input plug-ins attach; the host's `InputRegistry` conforms.
- `CapturedFrame` — one GPU-resident video frame plus its presentation time on the master clock; carries the frame ownership rule.
- `StreamingService` — the output seam: sends program media to a destination (HaishinKit lives behind this protocol).
- `Destination` — a configured streaming target: URL plus optional stream key (deliberately not `Codable` — the key is a secret).
- `EngineClock` — the master clock seam: current time and the absolute-deadline tick stream (see [CLOCK.md](docs/CLOCK.md)).
- `PlugIn` — the protocol every plug-in conforms to: identity plus an activation hook for registering capabilities.
- `PlugInID` — the stable reverse-DNS identifier for a plug-in; doubles as its event domain.
- `PlugInContext` — the host infrastructure handed to a plug-in at activation: the event bus, the clock, and the input registration seam.

### `packages/TingraHost`

The host/core package: plug-in loading, registries, frame transport, session/state, secure storage, and authorization — the minimal core that is not a plug-in (see [ARCHITECTURE.md](docs/ARCHITECTURE.md), "Engine model: host and plug-ins").

- `HostClock` — the production `EngineClock`: the host time clock with a `ContinuousClock`-based absolute-deadline tick loop.
- `InputRegistry` — the actor where input plug-ins register the inputs they contribute and the engine resolves them from; the host's concrete `InputRegistering`.
- `InputRegistryError` — errors thrown by the registry (e.g. registering a duplicate input identifier).
- `PlugInLoader` — the host's plug-in lifecycle: activates plug-ins against a `PlugInContext`, reporting each outcome on the event bus; a throwing plug-in is skipped, never fatal.
- `OSLogSink` — the always-on system-of-record sink: routes every event to OSLog (`subsystem` `com.moonwink.tingra`, `category` = domain), params `.private`.

### `packages/TingraCapturePlugIns`

The first party capture plug-ins: camera and microphone discovery now, the full inputs at roadmap step 2. AVFoundation is imported only inside this package, behind the `Input` seam.

- `AVFoundationCapturePlugIn` — contributes the Mac's cameras and microphones as inputs with stable identifiers (`AVCaptureDevice.uniqueID`); discovery-only until capture lands.

### `apps/tingra-cli`

The headless front end over the engine (see [CLI.md](docs/CLI.md)): one invocation selects inputs, configures compression, and streams. An executable, so it exposes no public types; its surface is its subcommands — `devices` (input discovery: human table and stable `--json`, see [CLI.md](docs/CLI.md)) and `version` so far, with `stream`, `probe`, `serve`, and `mcp` arriving per the roadmap.

### `apps/ingest-simulator` (planned)

The local RTMP/SRT ingest server used for integration testing (see [SIMULATOR.md](docs/SIMULATOR.md)); a MediaMTX-based harness, not yet scaffolded.

## License

Tingra is released under the [MIT License](LICENSE).
