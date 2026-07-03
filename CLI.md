# tingra-cli: Command Line Streaming for Tingra

`tingra-cli` is a headless companion to Tingra. It drives the same engine as the app, with no UI. A single invocation can select a camera and microphone, configure compression, and stream to any RTMP or SRT destination.

Naming: the `-cli` suffix is deliberate. A user may have the Tingra app installed on the same machine, and the suffix makes the two easy to tell apart in the shell, in Activity Monitor, and in authorization prompts.

Vocabulary follows GLOSSARY.md: inputs and generators, compression, output, destinations, plug-ins.

## Goals

1. **One invocation does everything.** Select inputs, set compression parameters, and go live in a single command. No interactive prompts unless explicitly requested.
2. **Scriptable and automatable.** Stable exit codes, machine readable output (`--json`), and clean signal handling make it usable from scripts, launchd jobs, and CI.
3. **Same engine as the app.** The CLI is a thin front end over the engine packages (capture via AVFoundation input plug-ins, output via the `StreamingService` seam described in ARCHITECTURE.md; streaming compression happens inside HaishinKit and recording compression inside AVAssetWriter, both hardware accelerated through VideoToolbox). No forked pipeline.
4. **Agent ready.** The engine's controls are exposed as MCP tools through a persistent process; the MCP server is the primary interface for AI agents (see `serve` and `mcp` below).
5. **Testable without hardware or a real service.** Generators and the local simulator (see SIMULATOR.md) allow full end to end tests on any machine.

## Non-goals (v1)

Display/window inputs, shot composition, transitions, and multiple destinations are app roadmap items; the CLI adds them later once the engine exposes them. v1 is: one camera, one microphone, one destination. Local recording (`--record`) is deferred until after streaming is solid.

## Repository and package layout

`tingra-cli` lives in the Tingra monorepo at `apps/tingra-cli`, one of the runnable products under `apps/` (alongside `apps/ingest-simulator` and, in phase 3, the `apps/tingra` app). It builds on the engine libraries under `packages/`: the host/core package, the plug-in protocol package, and the first party feature plug-ins (see "Repository structure" in ARCHITECTURE.md). Package names are not finalized. In the CLI era, bundled plug-ins are compiled into the binary but register through the same code path the external bundle loader will use.

Argument parsing uses Apple's [swift-argument-parser](https://github.com/apple/swift-argument-parser), which generates `--help` text and completion scripts.

## Distribution

Signed and notarized binary for Apple Silicon (arm64) only, distributed through a Homebrew tap.

**Identity.** The code signing identity stays stable across releases so Camera, Microphone, and (later) Screen Recording authorization does not need re-granting on every update: one Team ID, and the explicit code signing identifier **`com.moonwink.tingra.cli`** (set with `codesign -i`, never left to default to the binary name). All Tingra identifiers live under `com.moonwink.tingra.*`.

**Embedded Info.plist.** A bare executable has no bundle, so the CLI embeds its Info.plist in the binary via the `__TEXT,__info_plist` linker section (in SPM: `-sectcreate` linker flags on the executable target — `unsafeFlags` is acceptable here because `tingra-cli` is a leaf product nothing depends on). The plist carries `CFBundleIdentifier` (`com.moonwink.tingra.cli`), the version keys, and the TCC usage descriptions `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`, written as real explanations of why Tingra uses the device. Without those strings TCC does not deny the request — it kills the process outright.

**Hardened runtime and entitlements.** Notarization requires the hardened runtime, and the hardened runtime denies camera and microphone access unless the binary opts in. Signing applies an entitlements file with `com.apple.security.device.camera`, `com.apple.security.device.audio-input`, and `com.apple.security.cs.disable-library-validation` (third party plug-in loading, per ARCHITECTURE.md). No sandbox entitlement — Tingra is deliberately unsandboxed.

**Notarization artifacts.** Each release publishes two artifacts from the same signed binary: a **zip** consumed by the Homebrew tap (a bare Mach-O cannot be stapled, so Gatekeeper fetches the notarization ticket online on first run) and a **stapled `.pkg`** for offline capable direct download.

**The tap never builds from source.** The formula downloads the prebuilt, signed, notarized artifact. Building on the user's machine would produce an unsigned binary with no stable identity — no notarization, and TCC grants keyed to nothing.

**CI verification.** The packaging job asserts identity, entitlements, and the embedded plist on every release — `codesign --verify --strict`, `codesign -d --entitlements -`, and an `otool -s __TEXT __info_plist` presence check — so a regression fails the pipeline, not a user's Mac.

Open question tracked in the plan: how bundled plug-ins ship next to a bare binary (app bundle style layout, compiled in, or a plug-ins directory installed by the formula).

## Command structure

```
tingra-cli <subcommand> [options]

SUBCOMMANDS
  stream      Start streaming (the main one shot command)
  devices     List available cameras, microphones, and their IDs
  probe       Validate a destination URL/key without going live
  serve       Run the persistent engine process (session survives across calls)
  mcp         MCP entry point for agents (thin stdio client of the serve process)
  version     Print version and build info
```

### `tingra-cli devices`

Lists inputs available for capture (input discovery). Default output is a human readable table; `--json` emits stable identifiers for scripting.

```
tingra-cli devices [--type camera|mic|all] [--json]
```

Example output:

```
CAMERAS
  0  FaceTime HD Camera            (id: 0x8020000005ac8514)
  1  Logitech BRIO                 (id: 0x14100000046d085e)
MICROPHONES
  0  MacBook Pro Microphone        (id: BuiltInMicrophoneDevice)
  1  Shure MV7                     (id: AppleUSBAudioEngine:Shure:MV7)
```

Device connection and disconnection is a normal event, not an error; the engine reports current state at the moment of the call.

### `tingra-cli stream`

Starts capture and streams until stopped (Ctrl-C / SIGTERM stops cleanly, flushing compression and closing the connection) or until `--duration` elapses.

```
tingra-cli stream --url <destination> [--key <stream key>] [options]
```

#### Destination

| Option | Description |
| :----- | :---------- |
| `--url <url>` | RTMP(S) or SRT destination. Examples: `rtmp://live.twitch.tv/app`, `rtmps://a.rtmps.youtube.com/live2`, `srt://host:8890?streamid=...`. Required. |
| `--key <key>` | Stream key, appended to the RTMP URL path. Prefer `--key-env` or `--key-stdin` in scripts. |
| `--key-env <VAR>` | Read the stream key from an environment variable (keeps it out of shell history and `ps` output). |
| `--key-stdin` | Read the stream key from stdin. |
| `--reconnect <n>` | Reconnection attempts on connection loss (default 3, `0` disables). |
| `--reconnect-delay <sec>` | Delay between attempts (default 2). |

#### Input selection

| Option | Description |
| :----- | :---------- |
| `--camera <sel>` | Camera by index, unique name substring, or ID from `devices --json`. Default: system default camera. |
| `--mic <sel>` | Microphone, same selector forms. Default: system default input. |
| `--no-video` | Audio only stream. |
| `--no-audio` | Video only stream. |
| `--video-generator bars` | SMPTE color bars generator with burned in timecode instead of a camera. For testing on machines with no camera (CI). |
| `--audio-generator tone` | 440 Hz tone generator instead of a microphone. |

#### Compression

| Option | Description |
| :----- | :---------- |
| `--resolution <WxH>` | Program resolution (default `1920x1080`). Captured frames are scaled if needed. |
| `--fps <n>` | Frame rate (default 30). |
| `--video-codec h264\|hevc` | Default `h264` (broadest destination support; Twitch RTMP is H.264 only). |
| `--video-bitrate <rate>` | e.g. `6000k` (default `4500k`). |
| `--keyframe-interval <sec>` | Default 2 (Twitch/YouTube recommendation). |
| `--audio-codec aac` | AAC only in v1. |
| `--audio-bitrate <rate>` | Default `160k`. |
| `--audio-samplerate <hz>` | Default 48000. |

#### Recording and control

| Option | Description |
| :----- | :---------- |
| `--record <path>` | Simultaneously record the program to `.mp4`/`.mov` via AVAssetWriter, independent of streaming output. Post v1: arrives at roadmap step 5, after streaming ships. |
| `--duration <sec>` | Stop automatically after N seconds. |
| `--dry-run` | Resolve inputs, build the pipeline, print the resolved configuration, and exit without connecting. |

#### Output and logging

| Option | Description |
| :----- | :---------- |
| `--json` | Emit newline delimited JSON status events (started, stats, reconnecting, stopped, error) instead of human readable logs. |
| `--stats-interval <sec>` | How often to print bitrate/fps/dropped frame stats (default 5, `0` disables). |
| `--verbose` / `--quiet` | Log level control. |
| `--log-file <path>` | Also write logs to a file. |

#### Exit codes

| Code | Meaning |
| :--- | :------ |
| 0 | Clean stop (signal or `--duration`). |
| 64 | Usage error (bad flags, malformed URL). |
| 69 | Input not found or authorization denied (camera/mic TCC). |
| 70 | Internal pipeline error. |
| 75 | Connection failed or lost after all reconnect attempts. |

### `tingra-cli serve` and `tingra-cli mcp`

The MCP server, not raw CLI shell invocation, is the primary AI agent interface (decided in the Tingra plan).

`serve` runs the persistent engine process — the daemon. It owns the session: which inputs are active, what is streaming, connection state. Because the process persists, pipeline state survives across individual tool calls, and TCC authorization attaches to one long running identity. In the product path the daemon is launchd managed and socket activated (a LaunchAgent installed by `serve --install` or the Homebrew formula), starting on the first connection and idle-exiting when quiet; manual `serve` in a terminal remains the development path. See MCP.md for the transport, lifecycle, and the TCC attribution rationale behind the launchd decision.

`mcp` is a thin stdio entry point for agents: it speaks [MCP](https://modelcontextprotocol.io) JSON-RPC on stdio and proxies it byte for byte to the daemon's Unix domain socket rather than owning the pipeline itself, reconciling desktop extension process lifecycles with the persistent daemon model (see MCP.md). An agent config points at the binary:

```json
{ "mcpServers": { "tingra": { "command": "tingra-cli", "args": ["mcp"] } } }
```

The MCP tool surface is plug-in defined: plug-ins contribute tools to the host's tool registry, and the MCP/Control service aggregates and namespaces them, so the agent facing API and the plug-in API stay the same shape. The initial host and first party tool set mirrors the CLI surface:

| Tool | Mirrors | Notes |
| :--- | :------ | :---- |
| `devices_list` | `devices --json` | Same identifiers, same JSON shape. |
| `probe` | `probe` | Validate URL/key without going live. |
| `stream_start` | `stream` options | Input schema mirrors the flags (url, key, camera, mic, resolution, bitrate, ...). Returns a session id. |
| `stream_status` | `--json` status events | Bitrate, fps, dropped frames, connection state for a session. |
| `stream_stop` | Ctrl-C | Clean stop: flush compression, close connection, finalize any recording. |

One active stream session in v1. Stream keys pass through tool input into the host's secure storage and are never logged.

## Usage examples

```sh
# Simplest case: a Mac laptop with no external gear, streaming to Twitch.
# The built in camera and built in mic are the system defaults, so no
# input flags are needed; compression defaults (1080p, 30 fps, H.264,
# 4500k) are within Twitch's recommended settings. Paste your stream
# key from dashboard.twitch.tv and you are live. Ctrl-C to stop.
tingra-cli stream --url rtmp://live.twitch.tv/app --key live_xxxxxxxxxxxx

# List inputs, grab IDs
tingra-cli devices --json

# Stream the BRIO + Shure MV7 to Twitch, key from environment
export TWITCH_KEY=live_xxxxxxxx
tingra-cli stream --url rtmp://live.twitch.tv/app --key-env TWITCH_KEY \
  --camera BRIO --mic MV7 --resolution 1280x720 --fps 30 --video-bitrate 4500k

# YouTube over RTMPS, HEVC, with a local recording (post v1)
tingra-cli stream --url rtmps://a.rtmps.youtube.com/live2 --key-stdin \
  --video-codec hevc --record ~/Movies/backup.mp4 < key.txt

# SRT destination
tingra-cli stream --url "srt://ingest.example.com:8890?streamid=publish:mystream"

# Fully generated 30 second test against the local simulator (no hardware)
tingra-cli stream --url rtmp://localhost:1935/live --key tingra_test_key \
  --video-generator bars --audio-generator tone --duration 30 --json
```

## Implementation notes

- **Authorization:** camera and microphone access require TCC authorization. The CLI requests it on first run; in headless contexts (SSH/CI) generators avoid TCC entirely. The stable signing identity (see Distribution) keeps grants valid across updates. Attribution nuance: a one shot `stream` launched from a terminal gets its prompt attributed to the terminal app (the responsible process), so that grant lands on Terminal/iTerm/etc.; the launchd managed daemon (see MCP.md) is attributed to Tingra itself. Both paths run the same binary under the same identity, and the embedded usage descriptions are mandatory in every path — absent strings mean TCC kills the process rather than prompting.
- **Seam discipline:** the CLI talks only to engine types. HaishinKit stays behind `StreamingService`, capture frameworks stay behind `Input`, per ARCHITECTURE.md.
- **`probe` subcommand:** performs the RTMP/SRT handshake and immediately disconnects, letting scripts validate credentials before an event without going live.
- **Roadmap alignment:** the CLI spans roadmap steps 1 to 4 in ARCHITECTURE.md (scaffold + `devices` → inputs and generators → streaming → MCP). v1 ships at step 3, before recording, composition, or any app UI. It is the first shippable milestone and the permanent integration test surface for the engine.

## Testing

Unit tests cover argument parsing, input selector resolution, and config validation. Integration tests run `tingra-cli stream` with generators against the local simulator and verify the stream server side. See SIMULATOR.md.
