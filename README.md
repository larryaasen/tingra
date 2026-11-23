# Tingra — Native Live Streaming for macOS

[![codecov](https://codecov.io/gh/larryaasen/tingra/graph/badge.svg)](https://codecov.io/gh/larryaasen/tingra)

Tingra: An open-source live streaming and production app
built exclusively for macOS. It is designed to be Mac-first and Swift-native end
to end — a real SwiftUI/AppKit app built directly on Apple's media stack, not
a cross-platform tool ported to the Mac.

Under the hood, Tingra is written entirely in Swift. It captures displays,
windows, and applications through ScreenCaptureKit, and cameras and
microphones through AVFoundation. Shot compositing, transitions, and visual
effects run on Metal, Apple's modern GPU framework, with Core Image for
filters. Compression is handled by VideoToolbox for hardware-accelerated
H.264 and HEVC, and audio mixing runs through AVAudioEngine. Captured frames
stay GPU-resident from capture through compositing to compression, avoiding
costly CPU round-trips. Tingra's real differentiation is combining a
genuinely native Swift/SwiftUI codebase with being fully open source, a
combination nothing else currently offers.

Tingra offers the essentials creators expect: presets and shots, layered
inputs, audio mixing, real-time preview, recording, and streaming to any RTMP
or SRT destination, including YouTube, Twitch, and custom servers. The
interface is built in SwiftUI and AppKit, so it looks and behaves like a real
Mac app rather than a transplanted one.

The project targets a narrow but real gap. Native-feeling streaming apps for
the Mac exist, but they are commercial and closed-source.
Full-featured open-source tools exist, but none are Swift-native, Metal-based,
or built with a native Mac UI framework. Tingra aims to be the missing piece:
an open-source, transparent, genuinely Mac-native broadcaster — not
necessarily a faster one.

Tingra is for streamers, educators, podcasters, and developers who want a
fast, focused, native tool — and who believe the best Mac software is built
with the platform, not around it.

## The hierarchy: project, preset, shot, layers

Tingra's vocabulary is Apple Pro app and broadcast terminology, defined in
[GLOSSARY.md](docs/GLOSSARY.md). Four terms carry the whole production model,
and they nest: **project > preset > shot > layers.**

| | Project | Preset | Shot | Layer |
|---|---|---|---|---|
| **What it is** | The saved document for a whole show | A collection of settings inside that document | A composition inside a preset, saved with it | One positioned element inside a shot |
| **Lifespan** | The show | Long-term; kept across sessions | Persisted; kept across sessions with its preset, however briefly it is on air | As long as the shot holds it |
| **Count** | One per show, one open at a time | Many per project | Many per preset | Several per shot, in stacking order |
| **Contains** | Every preset, destination configuration, and setting | Its shots, layer arrangements, audio channels, connected inputs | Its layer tree and an optional default transition | An input, a frame rect, an opacity, and an optional effect chain |
| **Effect on program** | Closing one show, opening another | None — the switch is seamless, program keeps playing | This *is* the change viewers see, via cut, dissolve, wipe, or shader | Immediate on the next tick, if its shot is on program |

A project is saved as a `.tingraproject` file (JSON inside). Every preset,
every shot, and every layer is in it. The app keeps one project open and
autosaves it; the File menu makes a new one, opens another (or a recent one,
or one double-clicked in the Finder), and saves the open show under a new
name, and the launch reopens the project that was open last. Which preset is
active and which shots are on program and preview are *where the operator is
standing* rather than part of the show, so they stay out of the document —
but they are not lost either: the app records them per project in
machine-local preferences and restores them at launch, along with the armed
transition.

## Installing the app

Tingra.app is distributed as a signed, notarized disk image, through the same
Homebrew tap as the CLI:

```sh
brew install --cask larryaasen/tingra/tingra
```

`brew upgrade --cask tingra` updates it. The disk image is also attached to
each [GitHub release](https://github.com/larryaasen/tingra/releases): open it
and drag Tingra to Applications. The app needs an Apple Silicon Mac running
macOS 15 (Sequoia) or later. It does not yet carry `tingra-cli` or the MCP
server; install those with the formula below.

## Getting started: the CLI and MCP server

`tingra-cli` is a headless front end over the engine. It
can stream on its own, and it exposes the engine to AI agents (Claude and
others) as an [MCP](https://modelcontextprotocol.io) server. This section
takes a first-time user from install to controlling a stream from Claude.

> **Requirements:** an Apple Silicon Mac (arm64) running macOS 15 (Sequoia)
> or later. Intel Macs are not supported.

### 1. Install

Tingra is distributed as a signed, notarized binary through a Homebrew tap:

```sh
brew install larryaasen/tingra/tingra-cli
```

The tap downloads the prebuilt binary — it never builds from source, so the
signing identity stays stable and macOS keeps your Camera and Microphone
permissions across updates.

### 2. Set up the MCP server

The MCP server runs as a launchd **LaunchAgent** so the daemon is its own
process. This matters for permissions: camera and microphone prompts are
attributed to **Tingra**, not to whichever agent app connected, and a single
grant sticks across updates. Register it once:

```sh
tingra-cli serve --install
```

That installs `~/Library/LaunchAgents/com.moonwink.tingra.serve.plist` and
loads it. The daemon starts automatically the first time an agent connects and
idle-exits when quiet — you never start or stop it by hand. To remove it
later:

```sh
tingra-cli serve --uninstall
```

Re-run `tingra-cli serve --install` after a `brew upgrade` so the LaunchAgent
points at the new version.

### 3. Verify

Confirm the CLI works — these run in-process and need no daemon:

```sh
tingra-cli version           # prints: tingra-cli 0.1.0
tingra-cli devices           # lists your cameras and microphones
```

The first time you list or stream a camera or microphone, macOS prompts for
Camera/Microphone access — grant it in **System Settings › Privacy & Security**.
To verify a streaming destination without going live (no media is sent), use
`probe`:

```sh
tingra-cli probe --url rtmp://live.twitch.tv/app --key <your-stream-key>
```

To confirm the MCP daemon itself answers, you can run it in the foreground in
one terminal (`tingra-cli serve`) and connect the proxy in another
(`tingra-cli mcp`), but with the LaunchAgent installed the usual path is
simply to point Claude at it (next step).

### 4. Use it from Claude

The agent-facing entry point is `tingra-cli mcp` — a thin stdio proxy that
forwards to the daemon. Point your Claude client at it.

**Claude Desktop** — Claude Desktop doesn't yet have a form for adding a local
MCP server by command, so this still means editing a config file, but Claude
opens it for you:

1. Open **Claude → Settings → Developer**.
2. Click **Edit Config** — this opens `claude_desktop_config.json` in your
   default editor (creating it if it doesn't exist yet).
3. Add the `tingra` entry below (merge it into the existing `mcpServers`
   object if there is one; use the absolute path, since the app may not have
   Homebrew's `bin` on its `PATH`), save, and quit and reopen Claude Desktop:

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

> **You:** Start streaming SMPTE bars and a 440 Hz tone to my Twitch
> destination at rtmp://live.twitch.tv/app — the key is `live_1234567890`.
>
> **Claude:** *(calls `stream_start`)* Streaming is live — generators (bars +
> tone) to `rtmp://live.twitch.tv/app`. I'll leave it running; say "stop the
> stream" when you're done.

Stream keys are secrets: they go straight into Tingra's Keychain-backed secure
storage and are never echoed back — any status or log that references one shows
it redacted (`live_12…`). One stream runs at a time in v1; asking to start
another while one is live returns a clear error naming the active session.

## Packages and apps

The monorepo splits into `packages/` (the engine libraries) and `apps/` (the
runnable products). Each one gets a single line here saying what it is, linked
to its section in [TYPES.md](docs/TYPES.md), which says in detail what it is
and why it exists and lists every type in it. The design behind each piece is
in [ARCHITECTURE.md](docs/ARCHITECTURE.md).

**Packages**

- [`TingraEventBus`](docs/TYPES.md#packagestingraeventbus) — the event bus every part of the engine reports through.
- [`TingraPlugInKit`](docs/TYPES.md#packagestingrapluginkit) — the plug-in protocols, a stability contract shipped as the SDK.
- [`TingraHost`](docs/TYPES.md#packagestingrahost) — the host: plug-in loading, registries, session state, secure storage.
- [`TingraCapturePlugIns`](docs/TYPES.md#packagestingracaptureplugins) — camera, microphone, display, window, and application inputs.
- [`TingraUVC`](docs/TYPES.md#packagestingrauvc) — a standalone library for a USB webcam's picture controls.
- [`TingraApplicationAudio`](docs/TYPES.md#packagestingraapplicationaudio) — a standalone library capturing one application's sound.
- [`TingraGeneratorPlugIns`](docs/TYPES.md#packagestingrageneratorplugins) — bars, tone, and other generators: the CI test surface.
- [`TingraComposition`](docs/TYPES.md#packagestingracomposition) — the compositor, its layers, and the presets and shots.
- [`TingraAudio`](docs/TYPES.md#packagestingraaudio) — the mixer: one channel strip per audio input, into the program mix.
- [`TingraEffectPlugIns`](docs/TYPES.md#packagestingraeffectplugins) — the first-party audio and video effects.
- [`TingraOutputPlugIns`](docs/TYPES.md#packagestingraoutputplugins) — streaming to RTMP, RTMPS, and SRT destinations.
- [`TingraRecordingPlugIns`](docs/TYPES.md#packagestingrarecordingplugins) — recording the program to a local `.mov` or `.mp4`.
- [`TingraMediaPlugIns`](docs/TYPES.md#packagestingramediaplugins) — images, video and audio files, and text documents as inputs.
- [`TingraMonitorPlugIns`](docs/TYPES.md#packagestingramonitorplugins) — the first-party monitor overlays: guides and checking views.
- [`TingraJSONRPC`](docs/TYPES.md#packagestingrajsonrpc) — the JSON-RPC 2.0 wire types and transports, XPC included.
- [`TingraMCP`](docs/TYPES.md#packagestingramcp) — the MCP server, the engine daemon, its proxy, and the control tools.
- [`TingraAppPlugInKit`](docs/TYPES.md#packagestingraapppluginkit) — what an app-tier plug-in links to extend the app.

**Apps**

- [`tingra-cli`](docs/TYPES.md#appstingra-cli) — the CLI: inputs, streaming, recording, and the MCP daemon, headless.
- [`ingest-simulator`](docs/TYPES.md#appsingest-simulator) — a local RTMP and SRT server for the integration tests.
- [`tingra-app`](docs/TYPES.md#appstingra-app) — the Tingra macOS app, the SwiftUI and AppKit switcher.
- [`tingra-cameras`](docs/TYPES.md#appstingra-cameras) — Tingra Cameras, a standalone camera picker with live preview.

## License

Tingra is released under the [MIT License](LICENSE).
