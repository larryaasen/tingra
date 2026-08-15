# Tingra — Native Live Streaming for macOS

Tingra is a free, open-source live streaming and production application
built exclusively for macOS. It bets on being Mac-first and Swift-native end
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
the Mac exist (e.g. Ecamm Live), but they are commercial and closed-source.
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
| **What it is** | The saved document for a whole show | A collection of settings inside that document | A short-term composition inside a preset | One positioned element inside a shot |
| **Lifespan** | The show | Long-term; kept across sessions | Short-term; quick to create, switch, discard | As long as the shot holds it |
| **Count** | One per show, one open at a time | Many per project | Many per preset | Several per shot, in stacking order |
| **Contains** | Every preset, destination configuration, and setting | Its shots, layer arrangements, audio channels, connected inputs | Its layer tree and an optional default transition | An input, a frame rect, an opacity, and an optional effect chain |
| **Effect on program** | Closing one show, opening another | None — the switch is seamless, program keeps playing | This *is* the change viewers see, via cut, dissolve, wipe, or shader | Immediate on the next tick, if its shot is on program |

A project is saved as a `.tingraproject` file (JSON inside). Which preset is
active, and which shot is on program, is session state — never part of the
saved document.

## Getting started: the CLI and MCP server

Tingra ships first as `tingra-cli`, a headless front end over the engine. It
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
runnable products). Every package and app is listed here with what it is and why
it exists; the public types inside each one are listed in
[TYPES.md](docs/TYPES.md), and the design behind each piece is in
[ARCHITECTURE.md](docs/ARCHITECTURE.md). Both listings are kept current as code
lands.

### `packages/TingraEventBus`

The zero-dependency event bus: the structured event spine every part of the
engine and every plug-in reports through (see [EVENTS.md](docs/EVENTS.md)).

**Types:** [`TingraEventBus` in TYPES.md](docs/TYPES.md#packagestingraeventbus)

### `packages/TingraPlugInKit`

The plug-in protocol package: the stability contract first- and third-party
plug-ins build against, importable without the engine (see
[ARCHITECTURE.md](docs/ARCHITECTURE.md), "Plug-in API stability and versioning").

**Types:** [`TingraPlugInKit` in TYPES.md](docs/TYPES.md#packagestingrapluginkit)

### `packages/TingraHost`

The host/core package: plug-in loading, registries, frame transport,
session/state, secure storage, the operator's destination store, and
authorization — the minimal core that is not a plug-in (see
[ARCHITECTURE.md](docs/ARCHITECTURE.md), "Engine model: host and plug-ins").

**Types:** [`TingraHost` in TYPES.md](docs/TYPES.md#packagestingrahost)

### `packages/TingraCapturePlugIns`

The first party capture plug-ins: camera, microphone, and display discovery and
capture, and the device connection/disconnection events on the bus. AVFoundation,
Core Audio, and ScreenCaptureKit are imported only inside this package, behind
the `Input` seam.

**Types:** [`TingraCapturePlugIns` in TYPES.md](docs/TYPES.md#packagestingracaptureplugins)

### `packages/TingraGeneratorPlugIns`

The first party generator plug-ins — inputs that synthesize their content from
the injected clock, so they run anywhere with no camera, microphone, or TCC: the
permanent CI test surface.

**Types:** [`TingraGeneratorPlugIns` in TYPES.md](docs/TYPES.md#packagestingrageneratorplugins)

### `packages/TingraComposition`

The composition engine library (roadmap steps 6–7): the tick-paced Metal/Core
Image compositor, the layer tree it renders, and the presets and shots it
switches among. A host-side library — not a plug-in, and not folded into the
minimal `TingraHost` — depending only on the protocol package and the event bus,
so it stays testable with a synthetic clock and a mock renderer (see
[ARCHITECTURE.md](docs/ARCHITECTURE.md), "Composition").

**Types:** [`TingraComposition` in TYPES.md](docs/TYPES.md#packagestingracomposition)

### `packages/TingraAudio`

The audio engine library (roadmap step 7): the mixer, the audio surface of the
engine, combining every audio input into the program mix — one channel strip per
input. A host-side library beside `TingraComposition` on the same rule — not a
plug-in (audio effects and taps plug into it later), not folded into `TingraHost`,
depending only on the protocol package and the event bus, so it stays testable
with a synthetic clock and scripted inputs (see [ARCHITECTURE.md](docs/ARCHITECTURE.md),
"The audio mixer").

**Types:** [`TingraAudio` in TYPES.md](docs/TYPES.md#packagestingraaudio)

### `packages/TingraEffectPlugIns`

The first party effect plug-ins: the audio and video staples behind the
shared effect seam (see [ARCHITECTURE.md](docs/ARCHITECTURE.md), "The effect
seam", "Audio effect chains", "Per-layer video effects"). Pure DSP and Core
Image over the seam's native currencies, so the package depends on the
protocol package alone and is fully deterministic in tests — no hardware,
no TCC.

**Types:** [`TingraEffectPlugIns` in TYPES.md](docs/TYPES.md#packagestingraeffectplugins)

### `packages/TingraOutputPlugIns`

The first party streaming output plug-in: the HaishinKit-backed
`StreamingService` for RTMP/RTMPS and SRT destinations. HaishinKit (and its
Logboard logging façade, rerouted to OSLog) is imported only inside this
package, behind the `StreamingService` seam.

**Types:** [`TingraOutputPlugIns` in TYPES.md](docs/TYPES.md#packagestingraoutputplugins)

### `packages/TingraRecordingPlugIns`

The first party local recording plug-in: the `AVAssetWriter`-backed
`RecordingService` writing the program to a local `.mov`/`.mp4`, independent of
streaming. AVFoundation is imported only inside this package (behind the
`RecordingService` seam), and it pulls in neither HaishinKit nor Logboard, so
`TingraOutputPlugIns` stays the sole HaishinKit importer.

**Types:** [`TingraRecordingPlugIns` in TYPES.md](docs/TYPES.md#packagestingrarecordingplugins)

### `packages/TingraMCP`

The MCP/Control service (see [MCP.md](docs/MCP.md)): the hand-rolled MCP
JSON-RPC layer, the engine daemon, the transparent stdio↔socket proxy, and the
first-party control tools that mirror the CLI surface. Speaks MCP verbatim on
the wire but takes no third-party dependency — the JSON-RPC framing is a few
hundred lines behind this seam rather than the official swift-sdk's
SwiftNIO/swift-log/eventsource stack.

**Types:** [`TingraMCP` in TYPES.md](docs/TYPES.md#packagestingramcp)

### `apps/tingra-cli`

The headless front end over the engine (see [CLI.md](docs/CLI.md)): one
invocation selects inputs, configures compression, and streams. An executable,
so it exposes no public types; its surface is its subcommands — `devices` (input
discovery: human table and stable `--json`; `--watch` streams live device
connect/disconnect events), `stream` (live streaming with `--reconnect`,
`--duration`, optional `--record` to a local `.mov`/`.mp4`, clean Ctrl-C/SIGTERM
stop, the `stream.*`/`recording.*` status events, and `--dry-run` plan
reporting), `probe` (validate a destination URL/key without going live), `serve`
(the persistent engine daemon behind a Unix domain socket — manual foreground
mode, or launchd socket-activated in the product path; `--install`/`--uninstall`
register and remove the LaunchAgent), `mcp` (the transparent stdio↔socket proxy
agents point at), and `version`.

### `apps/ingest-simulator`

The local RTMP/SRT ingest server used for integration testing (see
[SIMULATOR.md](docs/SIMULATOR.md)): a pinned MediaMTX binary wrapped in
`sim.sh` (`start | stop | status | verify`) with key-validating paths
(`mediamtx.yml`, `keys.env`). Test-only — never linked into the product. The
streaming integration scenarios run against it via `scripts/integration-test.sh`.

### `apps/tingra-app`

The assembled SwiftUI/AppKit app (phase 3), scaffolded at roadmap step 6: it
takes shape around the proven engine — a camera input and a display input
composited by `TingraComposition` and shown live in an on-screen `MTKView`, the
audio inputs mixed by `TingraAudio` into the program mix, and both streamed to
an RTMP(S) destination through the same `TingraOutputPlugIns` HaishinKit output
the CLI uses. A native Xcode project (`tingra-app.xcodeproj`, scheme
`tingra-app`, product `Tingra.app`, module `TingraApp`) rather than an SPM
package, so the bundle, the Info.plist usage descriptions, and a stable
code signature are build settings rather than scripts — which is what lets one
TCC grant for Screen Recording, Camera, and Microphone survive a rebuild. It
links the ten engine packages as local package references — recording the
program to a local file through the same `TingraRecordingPlugIns`
`RecordingService` the CLI's `--record` drives, in its own session so it starts
and stops independently of the stream. An app, so it exposes no public API
beyond its `@main` entry. User-facing strings are localized
(`Localizable.xcstrings`, en/de/es).

To build a signed, runnable copy, copy `apps/tingra-app/Local.xcconfig.example`
to `Local.xcconfig` (git-ignored) and set your own Apple Developer Team ID; the
tracked project file carries no one's team, so an unsigned
`CODE_SIGNING_ALLOWED=NO` build needs nothing at all.
The app is not sandboxed and uses the hardened runtime instead, so
`tingra-app/tingra-app.entitlements` grants camera and audio-input resource
access plus `disable-library-validation` — the same combination
`apps/tingra-cli` and `apps/tingra-cameras` need, and without which a camera's
CMIOExtension never starts streaming. Notarizing the `.app` for release is
deferred packaging, tracked alongside the CLI's distribution recipe.

**Types:** [`tingra-app` in TYPES.md](docs/TYPES.md#appstingra-app)

### `apps/tingra-cameras`

A standalone "Tingra Cameras" macOS app: a two-column hardware picker — a
sidebar listing the available cameras and microphones beside a large live-camera
preview canvas. A native Xcode project (`tingra-cameras.xcodeproj`, single app
target), self-contained (no engine package dependencies), and styled with the
standard SwiftUI Liquid Glass look rather than any bespoke theme (see its own
[CLAUDE.md](apps/tingra-cameras/CLAUDE.md)). An app, so it exposes no public API
beyond its `@main` entry. User-facing strings are localized
(`Localizable.xcstrings`, en/de/es).

**Types:** [`tingra-cameras` in TYPES.md](docs/TYPES.md#appstingra-cameras)

## License

Tingra is released under the [MIT License](LICENSE).
