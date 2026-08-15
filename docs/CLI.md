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

Display/window inputs, shot composition, and transitions are app roadmap items; the CLI adds them later once the engine exposes them. v1 is: one camera, one microphone. Local recording (`--record`) was deferred until after streaming was solid and landed at roadmap step 5; **multiple destinations** was also a deferral here and landed at roadmap step 8 — a repeatable `--url` now fans one program out to several services at once (see "Destination"), though it is still one capture and one composite, and every destination shares the run's compression settings.

## Repository and package layout

`tingra-cli` lives in the Tingra monorepo at `apps/tingra-cli`, one of the runnable products under `apps/` (alongside `apps/ingest-simulator` and, in phase 3, `apps/tingra-app`). It builds on the engine libraries under `packages/`: `TingraHost`, `TingraPlugInKit`, `TingraEventBus`, and the first party feature plug-ins `TingraCapturePlugIns` and `TingraGeneratorPlugIns` (names finalized; see "Repository structure" in ARCHITECTURE.md). In the CLI era, bundled plug-ins are compiled into the binary but register through the same code path the external bundle loader will use.

Argument parsing uses Apple's [swift-argument-parser](https://github.com/apple/swift-argument-parser), which generates `--help` text and completion scripts.

## Distribution

Signed and notarized binary for Apple Silicon (arm64) only, distributed through a Homebrew tap.

**Identity.** The code signing identity stays stable across releases so Camera, Microphone, and (later) Screen Recording authorization does not need re-granting on every update: one Team ID, and the explicit code signing identifier **`com.moonwink.tingra.cli`** (set with `codesign -i`, never left to default to the binary name). All Tingra identifiers live under `com.moonwink.tingra.*`.

**Embedded Info.plist.** A bare executable has no bundle, so the CLI embeds its Info.plist in the binary via the `__TEXT,__info_plist` linker section (in SPM: `-sectcreate` linker flags on the executable target — `unsafeFlags` is acceptable here because `tingra-cli` is a leaf product nothing depends on). The plist carries `CFBundleIdentifier` (`com.moonwink.tingra.cli`), the version keys, and the TCC usage descriptions `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`, written as real explanations of why Tingra uses the device. Without those strings TCC does not deny the request — it kills the process outright.

**Hardened runtime and entitlements.** Notarization requires the hardened runtime, and the hardened runtime denies camera and microphone access unless the binary opts in. Signing applies an entitlements file with `com.apple.security.device.camera`, `com.apple.security.device.audio-input`, and `com.apple.security.cs.disable-library-validation` (third party plug-in loading, per ARCHITECTURE.md). No sandbox entitlement — Tingra is deliberately unsandboxed.

**Only unrestricted entitlements, and this is a hard limit.** `tingra-cli` ships as a bare Mach-O executable, which has nowhere to embed a provisioning profile — and a provisioning profile is what authorizes a *restricted* entitlement. `codesign` does not check, so a restricted entitlement signs, verifies, and notarizes clean, then dies with SIGKILL at `exec`, before `main`, with no output and no crash report. v0.1.1 shipped that way with `keychain-access-groups` and every invocation was killed (DESTINATIONS.md, "What v0.1.1 settled about the CLI and restricted entitlements"). Adding a restricted entitlement therefore requires moving the CLI inside a bundle first — a distribution change, not an entitlements change.

**Notarization artifacts.** Each release publishes two artifacts from the same signed binary: a **zip** consumed by the Homebrew tap (a bare Mach-O cannot be stapled, so Gatekeeper fetches the notarization ticket online on first run) and a **stapled `.pkg`** for offline capable direct download.

**The tap never builds from source.** The formula downloads the prebuilt, signed, notarized artifact. Building on the user's machine would produce an unsigned binary with no stable identity — no notarization, and TCC grants keyed to nothing.

**CI verification.** The packaging job asserts identity, entitlements, and the embedded plist on every release — `codesign --verify --strict`, `codesign -d --entitlements -`, and an `otool -s __TEXT __info_plist` presence check — so a regression fails the pipeline, not a user's Mac.

**And it runs the binary.** Those three checks all passed on the unrunnable v0.1.1, because each inspects the artifact rather than executing it, and notarization does not execute it either. `release-cli-package.sh` now runs `tingra-cli version` on the packaged binary before notarizing and stops the release if it does not exit 0 reporting the expected version. It is the cheapest possible end-to-end check and the only one in the pipeline that would have caught that release.

**Versioning.** Product releases tag `v<MAJOR>.<MINOR>.<PATCH>`; `tingra-cli version` prints the number without the `v`, kept in sync with the embedded Info.plist's `CFBundleShortVersionString` (`scripts/release-cli-package.sh` asserts they match). The plug-in protocol package (`TingraPlugInKit`) and the event bus (`TingraEventBus`) SemVer independently under prefixed tags (`plugin-kit-<x.y.z>`, `event-bus-<x.y.z>`) so the API-stability diff pins the right baseline in a monorepo that ships several products from one commit. Between releases `main` carries the next version with a `-dev` suffix.

**The recipe is implemented.** `scripts/release-cli-package.sh` runs the whole pipeline (release build → sign → verify → notarized zip + stapled `.pkg` → sha256), gated on signing/notarization credentials passed as environment variables (absent creds fall back to an unsigned dev artifact). `.github/workflows/packaging.yml` runs it on a `v*` tag; the formula template lives at `packaging/homebrew/tingra-cli.rb`, copied per release into the external `larryaasen/homebrew-tingra` tap (see `packaging/README.md`).

### Cutting a release

`scripts/release-cli.sh` cuts and publishes a release in one command. It owns the version decision — prompting for the next version number and bumping `TingraCLIVersion.current` and the embedded `Info.plist` together — then hands off to `scripts/release-cli-publish.sh` for the build, signing, notarization, tag, GitHub release, and tap update. `release-cli-publish.sh` stays non-interactive and callable on its own, so CI and the `v*` tag workflow are unaffected.

**Step by step.**

1. **Land the work.** The tree must be clean and the branch level with `origin/main`; both are checked before anything is written, and a dirty tree is refused outright (the tag has to name a committed state, and the script is about to write two files of its own).

2. **Export the signing credentials** — they live only in the environment, never in a tracked file:

   ```sh
   export TINGRA_SIGN_ID="Developer ID Application: … (TEAMID)"
   export TINGRA_INSTALLER_SIGN_ID="Developer ID Installer: … (TEAMID)"
   export TINGRA_NOTARY_PROFILE="…"   # a notarytool store-credentials profile
   ```

   Missing credentials are a warning plus a confirmation prompt, not a hard stop, because `release-cli-package.sh` still produces a usable unsigned artifact for local inspection. Never publish that artifact: Gatekeeper rejects it and its TCC grants key to nothing.

3. **Run it:**

   ```sh
   scripts/release-cli.sh
   ```

4. **Answer the version prompt.** The default is the next version: the current number with its `-dev` suffix dropped when `main` is on-scheme, otherwise the next patch. A default that is already tagged is skipped over, and an explicitly requested version that collides is refused — so a release can never overwrite a shipped tag. The version must be `MAJOR.MINOR.PATCH`; a `-dev` suffix is rejected here by design.

5. **Confirm the plan.** The script prints the version transition, tag, branch, tap, and expected artifacts, then asks once before anything is published. Everything up to this prompt is read-only.

6. **Answer the `-dev` prompt** after the release completes, to reopen `main` on the next `-dev` version per the versioning scheme above. Skip it with `--no-dev-bump`.

7. **Verify** the published release from a consumer's position, not by reading the script's output:

   ```sh
   brew update && brew upgrade tingra-cli && tingra-cli version
   tingra-cli serve --install    # re-point the LaunchAgent at the new binary
   ```

**Flags.** `--version <x.y.z>` skips the prompt; `--dry-run` runs the preflight and prints the plan without changing anything; `--no-dev-bump` skips step 6; `--help` prints usage. `TINGRA_RELEASE_BRANCH` overrides the expected branch (default `main`); releasing from another branch warns and asks rather than refusing.

**Resumable.** If a run stops partway — a notarization timeout is the usual cause — re-run it with the same `--version`. The bump and its commit are skipped when already in place, and `release-cli-publish.sh` is itself idempotent (it reuses an existing tag and clobbers uploaded artifacts), so a resumed run finishes the release rather than starting a second one.

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
| `--url <url>` | RTMP(S) or SRT destination. Examples: `rtmp://live.twitch.tv/app`, `rtmps://a.rtmps.youtube.com/live2`, `srt://host:8890?streamid=...`. Required. **Repeatable** — see "Multiple destinations". |
| `--key <key>` | Stream key. For RTMP(S) it becomes the publish name; for SRT it is composed into the URL's `streamid` (see the SRT note). **Repeatable**, one per `--url` in the same order. Prefer `--key-env` or `--key-stdin` in scripts. |
| `--key-env <VAR>` | Read the stream key from an environment variable (keeps it out of shell history and `ps` output). Repeatable, one per `--url`. |
| `--key-stdin` | Read the stream key from stdin. Single-destination only — stdin yields one value. |
| `--reconnect <n>` | Reconnection attempts on connection loss (default 3, `0` disables). Applied **per destination**. |
| `--reconnect-delay <sec>` | Delay between attempts (default 2). |

**RTMP, RTMPS, and SRT all go live** (SRT landed 2026-07-24, roadmap step 8; RTMP/RTMPS from v1). Each resolves to its output provider by URL scheme through the one output registry.

**Multiple destinations.** Repeat `--url` to put one program on air to several services at once — Twitch and YouTube together, or a backup ingest beside the primary. It is **one stream fanned out to N destination legs**, not N streams: one capture, one composite, one timeline, one `stream.started`, one exit code. Each leg gets its own connection, its own encoder, and its own reconnect budget.

```bash
tingra-cli stream \
  --url rtmp://live.twitch.tv/app        --key-env TWITCH_KEY \
  --url rtmps://a.rtmps.youtube.com/live2 --key-env YOUTUBE_KEY
```

- **Keys pair with URLs by position.** Pass one `--key` (or `--key-env`) per `--url` in the same order, or none at all. An unequal count is a usage error (exit 64) naming both counts, rather than silently shifting a key onto the wrong destination. Mixing `--key` with `--key-env` in one run is still rejected, as it always was.
- **Transports can be mixed.** Each URL resolves its own provider by scheme, so an RTMP destination and an SRT destination in one run are normal.
- **Legs are named `destination-1`, `destination-2`, …** in order, and every per-destination event carries that id in its `destination` param (plus the URL in `destinationUrl`).
- **Every leg encodes with the same `--resolution`/`--video-bitrate`/… settings.** Per-destination compression settings are a later iteration; note that fan-out therefore costs one encoder per destination.

**Starting and losing destinations.** The start is **best effort** and a partial loss does not end the run:

- A destination that **refuses the connection at start** is reported as a `stream.destination.rejected` error event (identifier `connectionFailed`) and is not streamed to; the rest go live. The command throws (exit 75) only when **every** destination is refused — so a single-destination run behaves exactly as it always has.
- A destination refused at start **does not enter the reconnect budget**. That budget governs mid-stream losses; a destination that was wrong from the first handshake is not retried against a typo.
- A destination that **drops mid-stream** reconnects on its own budget (`--reconnect` attempts, `--reconnect-delay` apart, its own stability window). Its `stream.reconnecting` events carry its id; the other destinations are untouched and never charged for its outage.
- When a destination exhausts its budget it is reported as `stream.destination.lost` (identifier `connectionLost`) and stays dead for the run. **The run continues and exits 0 while at least one destination is still delivering**; exit 75 comes only when the last live one is lost.

**SRT and the stream key.** SRT has no RTMP-style publish name; the key rides in the URL's `streamid` (e.g. MediaMTX's `publish:<path>` shape). `--key` composes in so scripts keep the key out of the URL and out of `ps`/history:
- `--key` (or `--key-env`/`--key-stdin`) with an SRT URL that has **no** `streamid` → `streamid=<key>` is appended to the URL. Pass the whole `streamid` value as the key (e.g. `--key 'publish:live/abc123'`).
- `--key` with an SRT URL that **already** carries a `streamid` is ambiguous and is rejected (`invalidArgument`): supply the key one way, not both — either put the whole `streamid` in the URL, or pass it as the key with no `streamid` in the URL.
- No key → the SRT URL is used exactly as given (its own `streamid`, if any).

The key is placed into `streamid` **literally** (not percent-encoded), so a `publish:live/key` value stays `publish:live/key`; the key must therefore be URL-safe. The composed URL holds the secret and is never logged. Note SRT reconnect: an SRT link that dies mid-stream is not currently auto-reconnected — see "Reconnect semantics".

**Reconnect semantics.** A lost connection gets up to `--reconnect` attempts, `--reconnect-delay` seconds apart. A reconnected stream must then survive a stability window (10 seconds) before it counts as recovered: a connection that drops again within the window is the same outage and keeps draining the attempt budget. Without this, a destination that accepts every publish and closes the connection moments later — how most services reject a bad stream key — would reconnect forever. When the budget is exhausted, that destination ends with `connectionLost`; the run ends (exit 75) once the last live destination has.

The budget and the stability window are **per destination**: with several `--url`s, one flapping destination never spends another's attempts.

Note that no reconnect attempt is ever made for the **initial** connection, on any transport: a destination that refuses the first handshake is reported straight away rather than retried.

*RTMP(S) only in this iteration.* A **bad SRT connection is still caught at start** — a rejected handshake (bad `streamid`, unreachable host) is reported at once, and fails the command (exit 75) when it is the only destination. What SRT lacks is the **mid-stream** loss signal: HaishinKit 2.x's SRT publish path exposes no event when an already-established link later dies, so a hard SRT timeout is not auto-reconnected the way an RTMP drop is (SRT's own ARQ retransmission already rides out ordinary packet loss below this layer). Recorded in TODO.md as a deferral; never worked around with a poll loop. **With several destinations this has a further consequence:** an SRT leg never reports a mid-stream loss, so it counts as healthy for the whole run — a mixed RTMP + SRT run whose RTMP leg dies keeps going and exits 0 on the strength of an SRT leg that may already be dead.

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
| `--video-generator black` | Full-frame opaque black instead of a camera. The **black generator** a switcher carries as a selectable input on its rows — upstream of fade to black, so overlays and keys composite over it, where FTB is a downstream master stage that obscures everything. |
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
| `stream.started` | At least one destination connected and published; media is flowing. | `url` (the **first live** destination's), `destinations` (how many went live), `destinationsRejected` (how many were refused), plus the resolved video block (`videoInput`, `videoInputName`, `resolution`, `fps`, `videoCodec`, `videoBitrate`, `keyframeInterval`) and audio block (`audioInput`, `audioInputName`, `audioCodec`, `audioBitrate`, `audioSamplerate`); a disabled side omits its block. |
| `stream.destination.started` | One destination went live (one per live destination, after `stream.started`). | `destination`, `destinationUrl`. |
| `stream.stats` | Every `--stats-interval` seconds, **once per live destination**. | `destination`, `destinationUrl`, `elapsed`, `bytesSent`, `bitrate` (bits/second), `fps`. |
| `stream.reconnecting` | A reconnect attempt is starting for one destination. | `destination`, `destinationUrl`, `attempt`, `maxAttempts`, `delay`, `reason`. |
| `stream.reconnected` | A reconnect attempt succeeded for one destination. | `destination`, `destinationUrl`, `attempt`. |
| `stream.stopped` | The stream ended, however it ended. | `reason`: `stopRequested` (Ctrl-C/SIGTERM), `durationElapsed`, `connectionLost`, or `recordingFailed`. Optional `session`: present only when the caller labelled the session, so a caller running two at once can tell their events apart (the app's record-only session; never set by the CLI). |
| `recording.started` | `--record` opened the file and began writing (before `stream.started`). | `path`, `container` (`mov`/`mp4`). |
| `recording.stopped` | The recording was finalized on teardown. | `path`. |

The `recordingFailed` stop reason is **not reachable from the CLI**: it ends a session whose only sink was the recording, and `stream` still requires at least one `--url`. It exists because the engine now allows a session with no destination when a recording is configured — the app's record-only session (ARCHITECTURE.md, "Recording in the app"), and since 2026-08-06 the daemon's too (`stream_start` with `record` and no destination, MCP.md, "Sessions and concurrency") — and the value is listed here because `reason` is a scripting contract, so a caller must be able to see the whole set. A CLI run with `--record` behaves exactly as it always has: a write failure is reported and the stream carries on.

Two `error`-group events report a destination the run continues without (see "Multiple destinations"): **`stream.destination.rejected`** (`destination`, `destinationUrl`, `identifier` `connectionFailed`, `message`) when a destination refuses the connection at start, and **`stream.destination.lost`** (same params, `identifier` `connectionLost`) when one exhausts its reconnect budget mid-stream. Neither ends a run that still has a live destination — the `recordingFailed` precedent: reported with a stable identifier, without changing the run's fate.

Every per-destination event carries `destination` (the leg id, `destination-1`…) and `destinationUrl`. A single-destination run emits exactly the events it always did, plus these additive params and one `stream.destination.started` line — the shapes are append-only, so existing scripts keep reading the same keys.

`--dry-run` mirrors the same shape: `stream.plan` gains a `destinations` count (its `url` stays the first destination's), and each destination gets one `stream.plan.destination` event with `destination`, `destinationUrl`, and `keySource`.

Failures ride the same stream as `error` events carrying `identifier` + `message` (see "Error identifiers"). A recording write failure surfaces as an `error` event with `identifier` `recordingFailed`; because recording is independent of streaming, that error stops the recording but not the stream. No stream key ever appears in any event (the recording path is not a secret and does appear); a key is never made a param in the first place (EVENTS.md, Redaction).

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
| 0 | Clean stop (signal or `--duration`) — including a run that lost or was refused *some* of its destinations while at least one kept delivering. |
| 64 | Usage error (bad flags, malformed URL, a `--key` count that does not match the `--url` count). |
| 69 | Input not found or authorization denied (camera/mic TCC). |
| 70 | Internal pipeline error. |
| 75 | Connection failed or lost after all reconnect attempts — every destination refused at start, or the last live one lost. |

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
| `noActiveStream` | — | An MCP tool addressed "the active stream" (an omitted session id) while no stream was active (MCP.md, "Tool surface"). MCP-only: no CLI command addresses a session by omission, so no exit code maps to it. |
| `destinationNotFound` | — | No saved destination matches a `destination` selector on `stream_start` or `probe` (DESTINATIONS.md); the message points at `destinations_list`. MCP-only in v1 — no CLI command resolves a destination by name — so no exit code maps to it; were the CLI to gain a destination selector, it would exit 69 beside `inputNotFound`. |
| `destinationAmbiguous` | — | A `destination` name selector matches more than one saved destination; the message lists the matches. MCP-only on the same terms as `destinationNotFound`. |

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
| `stream_status` | `--json` status events | Bitrate, fps, dropped frames, and a derived per-leg connection state. `sessionId` optional: omitted addresses the active stream. The session's own `state` is derived from its legs — `idle`, `pending`, `live`, `degraded`, `lost` (MCP.md, "Tool surface"). |
| `stream_stop` | Ctrl-C | Clean stop: flush compression, close connection, finalize any recording. `sessionId` optional: omitted stops the active stream; nothing active is a `noActiveStream` error. |

One active stream session in v1 — which may fan out to several destinations (see MCP.md, "Sessions and concurrency"). Stream keys arrive as `stream_start` tool input and are transient in the daemon (see MCP.md, "Sessions and concurrency"): held only for the life of the session, released on every teardown path, never persisted to secure storage by the daemon, never logged, and referenced only redacted per EVENTS.md.

**Recording joined the MCP surface 2026-08-06** (it had been deferred 2026-07-05, roadmap step 5): `stream_start` gained the optional `record` field this paragraph always planned for — a purely additive change reusing the same `RecordingService` this command drives, with the same extension resolution, the same free-space floor, and the same reported-but-the-stream-carries-on write-failure rule; `stream_stop` already documented "finalize any recording." The identity consideration that addition carried is answered in MCP.md ("Tool surface"): the daemon writes as the operator — it is a LaunchAgent in the operator's GUI session — and what remains is location guidance (record to `~/Movies`; TCC-protected folders prompt), not an allowlist. A `record`-only `stream_start` (no destination) starts a record-only session there; `stream` itself is unchanged and still requires at least one `--url`.

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

# One program to Twitch and YouTube at once: repeat --url, one key each,
# in the same order. One capture, one composite, one exit code; each
# destination reconnects on its own budget, and losing one does not end
# the run.
export TWITCH_KEY=live_xxxxxxxx YOUTUBE_KEY=yt_xxxxxxxx
tingra-cli stream \
  --url rtmp://live.twitch.tv/app         --key-env TWITCH_KEY \
  --url rtmps://a.rtmps.youtube.com/live2 --key-env YOUTUBE_KEY

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
