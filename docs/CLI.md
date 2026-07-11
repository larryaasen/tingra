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

Display/window inputs, shot composition, transitions, and multiple destinations are app roadmap items; the CLI adds them later once the engine exposes them. v1 is: one camera, one microphone, one destination. Local recording (`--record`) was deferred until after streaming was solid and landed at roadmap step 5.

## Repository and package layout

`tingra-cli` lives in the Tingra monorepo at `apps/tingra-cli`, one of the runnable products under `apps/` (alongside `apps/ingest-simulator` and, in phase 3, the `apps/tingra` app). It builds on the engine libraries under `packages/`: `TingraHost`, `TingraPlugInKit`, `TingraEventBus`, and the first party feature plug-ins `TingraCapturePlugIns` and `TingraGeneratorPlugIns` (names finalized; see "Repository structure" in ARCHITECTURE.md). In the CLI era, bundled plug-ins are compiled into the binary but register through the same code path the external bundle loader will use.

Argument parsing uses Apple's [swift-argument-parser](https://github.com/apple/swift-argument-parser), which generates `--help` text and completion scripts.

## Distribution

Signed and notarized binary for Apple Silicon (arm64) only, distributed through a Homebrew tap.

**Identity.** The code signing identity stays stable across releases so Camera, Microphone, and (later) Screen Recording authorization does not need re-granting on every update: one Team ID, and the explicit code signing identifier **`com.moonwink.tingra.cli`** (set with `codesign -i`, never left to default to the binary name). All Tingra identifiers live under `com.moonwink.tingra.*`.

**Embedded Info.plist.** A bare executable has no bundle, so the CLI embeds its Info.plist in the binary via the `__TEXT,__info_plist` linker section (in SPM: `-sectcreate` linker flags on the executable target — `unsafeFlags` is acceptable here because `tingra-cli` is a leaf product nothing depends on). The plist carries `CFBundleIdentifier` (`com.moonwink.tingra.cli`), the version keys, and the TCC usage descriptions `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`, written as real explanations of why Tingra uses the device. Without those strings TCC does not deny the request — it kills the process outright.

**Hardened runtime and entitlements.** Notarization requires the hardened runtime, and the hardened runtime denies camera and microphone access unless the binary opts in. Signing applies an entitlements file with `com.apple.security.device.camera`, `com.apple.security.device.audio-input`, and `com.apple.security.cs.disable-library-validation` (third party plug-in loading, per ARCHITECTURE.md). No sandbox entitlement — Tingra is deliberately unsandboxed.

**Notarization artifacts.** Each release publishes two artifacts from the same signed binary: a **zip** consumed by the Homebrew tap (a bare Mach-O cannot be stapled, so Gatekeeper fetches the notarization ticket online on first run) and a **stapled `.pkg`** for offline capable direct download.

**The tap never builds from source.** The formula downloads the prebuilt, signed, notarized artifact. Building on the user's machine would produce an unsigned binary with no stable identity — no notarization, and TCC grants keyed to nothing.

**CI verification.** The packaging job asserts identity, entitlements, and the embedded plist on every release — `codesign --verify --strict`, `codesign -d --entitlements -`, and an `otool -s __TEXT __info_plist` presence check — so a regression fails the pipeline, not a user's Mac.

**Versioning.** Product releases tag `v<MAJOR>.<MINOR>.<PATCH>`; `tingra-cli version` prints the number without the `v`, kept in sync with the embedded Info.plist's `CFBundleShortVersionString` (`scripts/package-cli.sh` asserts they match). The plug-in protocol package (`TingraPlugInKit`) and the event bus (`TingraEventBus`) SemVer independently under prefixed tags (`plugin-kit-<x.y.z>`, `event-bus-<x.y.z>`) so the API-stability diff pins the right baseline in a monorepo that ships several products from one commit. Between releases `main` carries the next version with a `-dev` suffix.

**The recipe is implemented.** `scripts/package-cli.sh` runs the whole pipeline (release build → sign → verify → notarized zip + stapled `.pkg` → sha256), gated on signing/notarization credentials passed as environment variables (absent creds fall back to an unsigned dev artifact). `.github/workflows/packaging.yml` runs it on a `v*` tag; the formula template lives at `packaging/homebrew/tingra-cli.rb`, copied per release into the external `larryaasen/homebrew-tingra` tap (see `packaging/README.md`).

Open question tracked in TODO.md: how bundled plug-ins ship next to a bare binary (app bundle style layout, compiled in, or a plug-ins directory installed by the formula). For the CLI era they are compiled in (see ARCHITECTURE.md); the question is what changes when the external bundle loader ships.

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
tingra-cli devices [--type camera|mic|all] [--json] [--watch]
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

Device connection and disconnection is a normal event, not an error; without `--watch`, the engine reports current state at the moment of the call.

**`--watch`** keeps the process alive to observe device connection and disconnection live: it prints the current listing first, then one line per `device.connected` / `device.disconnected` event on the bus as devices come and go, until Ctrl-C / SIGTERM. The capture plug-in keeps the input registry current as devices change, so in human mode each reported change is followed by the refreshed listing on standard output — plug in a microphone and the MICROPHONES table reprints with it included. Under `--json`, the initial listing document is the first line, followed by the same NDJSON event lines the console sink emits everywhere else (EVENTS.md) — no bespoke output path, and the document is not re-emitted (scripts fold the event lines into it). `--type` filters the events and the reprinted listing the same way it filters the initial listing. The events come from the capture plug-in's device notifications behind the `Input` seam, never from polling. Exit code 0 on a clean stop.

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

**v1 scope: RTMP and RTMPS go live; SRT output arrives at roadmap step 8** (decided 2026-07-04, see TODO.md — an RTMP-only build stays fully source, with no prebuilt libsrt). `srt://` URLs still parse, but resolve no registered output and report a clear `invalidArgument` error naming the roadmap step.

**Reconnect semantics.** A lost connection gets up to `--reconnect` attempts, `--reconnect-delay` seconds apart. A reconnected stream must then survive a stability window (10 seconds) before it counts as recovered: a connection that drops again within the window is the same outage and keeps draining the attempt budget. Without this, a destination that accepts every publish and closes the connection moments later — how most services reject a bad stream key — would reconnect forever. When the budget is exhausted, the stream ends with `connectionLost` (exit 75).

#### Input selection

| Option | Description |
| :----- | :---------- |
| `--camera <sel>` | Camera by index, unique name substring, or ID from `devices --json`. Default: system default camera. |
| `--mic <sel>` | Microphone, same selector forms. Default: system default input. |
| `--no-video` | Audio only stream. |
| `--no-audio` | Video only stream. |
| `--video-generator bars` | SMPTE color bars generator with burned in timecode instead of a camera. For testing on machines with no camera (CI). |
| `--video-generator alignment` | Industry-standard-style alignment pattern instead of a camera. The pattern image is generated once at runtime, then reused for subsequent frames. |
| `--video-generator pluge` | PLUGE (Picture Line-Up Generation Equipment) black-level calibration pattern instead of a camera. Useful for checking shadow detail and crushed blacks. |
| `--video-generator pluge-strict` | Stricter broadcast-style PLUGE pattern instead of a camera. Uses a sparse reference-black field with the classic below-black / reference-black / above-black trio. |
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
| `--record <path>` | Simultaneously record the program to `.mp4`/`.mov` via AVAssetWriter, independent of streaming output. The extension selects the container (`.mov`/`.mp4`); any other extension is a usage error (exit 64). Recording runs alongside streaming — it keeps writing across a reconnect gap and is finalized cleanly on any stop (Ctrl-C, `--duration`, or a lost connection). A recording that cannot be created fails the command (`recordingFailed`, exit 70) before streaming; a write failure once recording (a full disk) is reported as a `recordingFailed` error event and stops the recording, but does not fail the stream (the exit code follows the stream's fate). |
| `--duration <sec>` | Stop automatically after N seconds. |
| `--dry-run` | Resolve inputs, build the pipeline, print the resolved configuration, and exit without connecting. See "Dry run" below. |

#### Status events

The `--json` status events are bus events on the standard NDJSON stream (EVENTS.md): one source of truth for humans, scripts, and agents. All are `event`-group events in the `output` domain; their param names mirror `stream.plan`'s and are a stable scripting contract (append-only, like every JSON shape here).

| Event | When | Params |
| :---- | :--- | :----- |
| `stream.started` | The connection and publish succeeded; media is flowing. | `url`, plus the resolved video block (`videoInput`, `videoInputName`, `resolution`, `fps`, `videoCodec`, `videoBitrate`, `keyframeInterval`) and audio block (`audioInput`, `audioInputName`, `audioCodec`, `audioBitrate`, `audioSamplerate`); a disabled side omits its block. |
| `stream.stats` | Every `--stats-interval` seconds. | `elapsed`, `bytesSent`, `bitrate` (bits/second), `fps`. |
| `stream.reconnecting` | A reconnect attempt is starting. | `attempt`, `maxAttempts`, `delay`, `reason`. |
| `stream.reconnected` | A reconnect attempt succeeded. | `attempt`. |
| `stream.stopped` | The stream ended, however it ended. | `reason`: `stopRequested` (Ctrl-C/SIGTERM), `durationElapsed`, or `connectionLost`. |
| `recording.started` | `--record` opened the file and began writing (before `stream.started`). | `path`, `container` (`mov`/`mp4`). |
| `recording.stopped` | The recording was finalized on teardown. | `path`. |

Failures ride the same stream as `error` events carrying `identifier` + `message` (see "Error identifiers"). A recording write failure surfaces as an `error` event with `identifier` `recordingFailed`; because recording is independent of streaming, that error stops the recording but not the stream. The stream key never appears in any event (the recording path is not a secret and does appear); the key is never made a param in the first place (EVENTS.md, Redaction).

#### Dry run

`--dry-run` parses and validates the full option surface, resolves the input selectors against the registry, reports the resolved plan, and exits 0 — no network, no TCC authorization request, and the stream key is never read (`--key-stdin` is validated for exclusivity only; the key is read at connect time, which a dry run never reaches).

**Selector resolution** (also how a live `stream` will resolve): an exact ID from `devices --json` wins outright; otherwise an integer selects by position in the listing order `devices` prints; anything else matches case-insensitively against input names and must match exactly one. Without `--camera`/`--mic` the system default device is resolved and reported; without a connected default the run fails with `inputNotFound`.

**Output.** In human mode the plan prints to standard output as the command result. Under `--json` the plan is one `stream.plan` event line on the standard NDJSON stream — flat, stable params (`url`, `keySource`, `videoInput`, `videoInputName`, `resolution`, `fps`, `videoCodec`, `videoBitrate`, `keyframeInterval`, `audioInput`, `audioInputName`, `audioCodec`, `audioBitrate`, `audioSamplerate`, `reconnect`, `reconnectDelay`, `statsInterval`, plus `duration`/`logFile` when set). A side disabled by `--no-video`/`--no-audio` omits its whole block; the stream key never appears in any output, only `keySource` (`none`, `option`, `environment`, `stdin`).

**Failures.** Flag and cross-flag validation problems are usage errors (exit 64, argument-parser message on stderr). Registry resolution failures flow through the event bus as `error` events carrying `identifier` and `message` params (see "Error identifiers") and exit with the identifier's code.

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

#### Error identifiers

Every `error` event the CLI emits carries a stable, machine-readable `identifier` param alongside a human `message`; exit-code semantics map to these identifiers, not to message wording (MCP.md, "Errors that teach" — the MCP tools reuse the same identifiers). This registry is the authoritative list. Identifiers are lowerCamelCase, bare (no dots — the dotted name on the event says *where* it happened; the identifier says *what kind* of failure it is), and **append-only: an identifier, once shipped, is never renamed or reused** (decided 2026-07-04). The Swift constants live in the plug-in protocol package (`ErrorIdentifier`) under its API stability contract.

| Identifier | Exit code | Meaning |
| :--------- | :-------- | :------ |
| `invalidArgument` | 64 | An option value failed validation: malformed URL, bad `--resolution` form, odd program dimensions, unparseable bitrate, conflicting flags. |
| `inputNotFound` | 69 | No registered input matches the selector (or no device of the required kind is connected to default to). |
| `inputAmbiguous` | 69 | A name-substring selector matches more than one input of that kind; the message lists the matches. |
| `authorizationDenied` | 69 | Camera or microphone TCC authorization was denied; the message names the permission and the System Settings fix. |
| `pipelineError` | 70 | An internal pipeline error: a stage failed in a way that is not the caller's input or the network. |
| `recordingFailed` | 70 | The local recording (`--record`) could not be written — an unwritable path, a rejected format, or a write/finalize error (a full disk). At setup this fails the command; once recording, it is reported but does not change the stream's exit code. |
| `connectionFailed` | 75 | The initial connection or handshake to the destination was rejected or unreachable. |
| `connectionLost` | 75 | The connection dropped and was not recovered within the configured reconnect attempts. |

### `tingra-cli serve` and `tingra-cli mcp`

The MCP server, not raw CLI shell invocation, is the primary AI agent interface (see MCP.md — a first class interface, not an internal tool).

`serve` runs the persistent engine process — the daemon. It owns the session: which inputs are active, what is streaming, connection state. Because the process persists, pipeline state survives across individual tool calls, and TCC authorization attaches to one long running identity. In the product path the daemon is launchd managed and socket activated (a LaunchAgent installed by `serve --install` or the Homebrew formula), starting on the first connection and idle-exiting when quiet; manual `serve` in a terminal remains the development path. See MCP.md for the transport, lifecycle, and the TCC attribution rationale behind the launchd decision.

```
tingra-cli serve [--install | --uninstall] [--program <path>] [--socket <path>]
                 [--idle-timeout <sec>] [--json] [--verbose|--quiet] [--log-file <path>]
```

`--install` writes and loads the launchd LaunchAgent (`~/Library/LaunchAgents/com.moonwink.tingra.serve.plist`) so the daemon becomes socket-activated, then exits; `--uninstall` unloads and removes it. `--program` overrides the absolute `tingra-cli` path written into the plist (default: this executable; pass the Homebrew `bin` path for upgrade stability). Run `serve --install` once after installing (the Homebrew formula's caveats point users here). `--socket` overrides the socket path (default: the standard per-user location); `--idle-timeout` sets the quiet period before the daemon exits (default 300 seconds, `0` disables — it never exits while a stream is active regardless). When launched by launchd the daemon adopts the launchd-owned socket automatically; run by hand it creates its own (manual mode). The daemon logs its own lifecycle to stderr (or NDJSON under `--json`); that output is separate from the MCP traffic, which flows only over the socket. Ctrl-C / SIGTERM stops it cleanly (exit 0).

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

**Recording is not yet in the MCP surface** (decided 2026-07-05, roadmap step 5). `--record` ships on the CLI's `stream` command only; the MCP tools gain no `record_start`/`record_stop`, and `stream_start` gains no `record` option in this step. The agent-facing contract stays as small as it can be until an agent actually needs recording, at which point recording attaches as an optional `record` field on `stream_start`'s input schema (reusing the same `RecordingService` the CLI drives) — a purely additive change. `stream_stop` already documents "finalize any recording," so the tool table is forward-compatible; the daemon writing files under its own identity is the extra consideration that addition carries.

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
- **`probe` subcommand:** performs the RTMP handshake and publish, watches briefly for the destination closing the connection (how services that validate at publish reject a bad key), then disconnects — no media is ever sent. Key options mirror `stream` (`--key`/`--key-env`/`--key-stdin`); success is exit 0 (a `probe.succeeded` event under `--json`), rejection or unreachability exit 75. Honesty note: key validation is only as strong as the service's publish-time enforcement — an ingest that only rejects once media flows (MediaMTX included) passes a data-free probe with a bad key; the `stream` path catches those via the reconnect stability window.
- **Roadmap alignment:** the CLI spans roadmap steps 1 to 4 in ARCHITECTURE.md (scaffold + `devices` → inputs and generators → streaming → MCP). v1 ships at step 3, before recording, composition, or any app UI. It is the first shippable milestone and the permanent integration test surface for the engine.

## Testing

Unit tests cover argument parsing, input selector resolution, and config validation. Integration tests run `tingra-cli stream` with generators against the local simulator and verify the stream server side: `scripts/integration-test.sh` runs the SIMULATOR.md scenarios (happy path, bad key, probe, reconnect across an outage) locally and in the separate `integration.yml` CI workflow, which triggers on streaming/output changes rather than blocking every PR. See SIMULATOR.md.
