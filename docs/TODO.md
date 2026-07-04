# TODO

Open decisions and roadmap progress. The authoritative step sequencing is ARCHITECTURE.md, "Roadmap sequencing"; the progress section here tracks where the work actually stands. Decision items (below) should each end as a sentence or two in the doc that owns them — none need a rewrite.

## Roadmap progress

- [x] **Step 1 — Monorepo scaffold + `tingra-cli devices`** *(complete 2026-07-04)*
  - [x] `apps/`/`packages/` split scaffolded: `TingraEventBus` (bus, redaction, 17 tests), `TingraPlugInKit` (protocol seams: `Input`, `StreamingService`, `EngineClock`, `PlugIn`), `TingraHost` (`HostClock`, `InputRegistry`), `tingra-cli` skeleton (`devices` stub, `version`).
  - [x] Review of package names, type names, and conventions (Larry, approved 2026-07-03) — final names recorded in CLAUDE.md "Project Structure" and ARCHITECTURE.md "Repository structure".
  - [x] Camera and microphone **input discovery** behind the `Input` seam: `packages/TingraCapturePlugIns` (`AVFoundationCapturePlugIn`, AVFoundation imported only there), registered through the `InputRegistering` seam into `InputRegistry` with `AVCaptureDevice.uniqueID` identifiers, activated via `PlugInLoader`.
  - [x] `tingra-cli devices` for real: human table + `--json` (stable `cameras`/`microphones` document per CLI.md); errors flow through the event bus console sink; listing output stays clean on stdout.
  - [x] First event bus **sinks**: `EventSink` protocol + `attach`/`shutdown` on the bus, `OSLogSink` (TingraHost), `ConsoleSink` (owned by the CLI; human lines to stderr, NDJSON to stdout).
  - [x] `scripts/format-swift.sh` / `check-format.sh` (swift-format, root `.swift-format` config: 4-space indent, 120 columns) and the GitHub Actions workflow `.github/workflows/ci.yml` (formatting check + warning-clean `swift build --build-tests` + `swift test` for every package and app, matrixed). Deferred jobs are tracked in "CI follow-ups" below.
- [x] **Step 2** — camera/microphone inputs + generators + `stream --dry-run` + `devices --watch` *(complete 2026-07-04)*
  - [x] Generators as the first full plug-ins: `packages/TingraGeneratorPlugIns` (`GeneratorPlugIn`, `BarsGenerator` — SMPTE bars with burned in timecode, IOSurface 32BGRA tagged BT.709; `ToneGenerator` — 440 Hz mono float32), synthesized on the injected clock's tick, fully deterministic under the synthetic clock. The permanent CI test surface; added to the CI matrix.
  - [x] Real capture in `TingraCapturePlugIns`: `CameraInput` (AVCaptureSession, 32BGRA IOSurface output, BT.709 tagged at the seam, host-time PTS passed through) and `MicrophoneInput` (AVAudioEngine input tap selected by Core Audio UID; PTS from `AVAudioTime.hostTime`, buffers without host time are skipped, never restamped). Hardware paths behind seams; unit tests cover the injected-authorization denied path, PCM→`CMSampleBuffer` conversion, and tagging.
  - [x] `device.connected`/`device.disconnected` events from the capture plug-in's AVFoundation notifications (`DeviceEventReporter`; normal events, never errors, never polling) — consumed by `devices --watch` now and `stream` sessions at step 3. The reporter also keeps the registry current (register on connect, unregister on disconnect — `InputRegistering` gained `unregister`, a pre-1.0 protocol addition), which is what lets `--watch` reprint the refreshed listing after each change.
  - [x] `Input` seam grew `audio()` (default: finished stream) with `CapturedAudio` beside `CapturedFrame`; `InputKind.generator` added; selector resolution (`resolveInput(selector:ofKind:)`, ID → index → unique name substring) and canonical listing order live in `InputRegistry`.
  - [x] `stream --dry-run`: full CLI.md option surface parsed and validated (`--record` excluded — it arrives at step 5), selectors resolved against the registry, plan reported (human table on stdout; a `stream.plan` event line under `--json`), stable error identifiers + exit codes on failure. `stream` without `--dry-run` is a usage error until step 3.
  - [x] `devices --watch` per the CLI.md spec, including the single-line listing document under `--json` and `--type` filtering of device events (a `ConsoleSink` refinement, no bespoke output path). Ctrl-C/SIGTERM via a self-pipe (`TerminationSignal`), exit 0. `--log-file`'s `FileSink` also landed (console-human lines, appended).
- [ ] **Step 3** — streaming: simulator harness (SIMULATOR.md), HaishinKit behind `StreamingService`; **`tingra-cli` v1 ships here**.
- [ ] **Step 4** — MCP server: `serve` daemon (launchd socket activation) + `mcp` proxy (MCP.md).
- [ ] **Step 5** — local recording (`--record`).
- [ ] **Steps 6–8** — app era: Metal composition/preview, production features, SRT/multiple destinations.

## Decisions to settle

- [x] **OSLog sink attachment in `tingra-cli`.** Decided 2026-07-04: skip attaching `OSLogSink` when standard error is a terminal, since macOS's own unified-logging terminal mirror already echoes the process's events there and attaching would double every line. Interactive runs lose nothing (the console sink already covers the human); non-interactive runs (scripts, launchd, redirected/piped output) keep OSLog as the system of record. Recorded in EVENTS.md, "OSLog sink"; a `tingra-cli`-level policy (`OSLogAttachment`), not a change to the sink itself.
- [ ] **MCP implementation dependency.** MCP.md commits the daemon to speaking MCP JSON-RPC natively but not *how*: the official `modelcontextprotocol/swift-sdk` or hand-rolled JSON-RPC framing. Recommendation: adopt the official Swift SDK behind the MCP/Control service boundary (JSON-RPC lifecycle, capability negotiation, and notifications are exactly the "thankless standardized parts" ARCHITECTURE.md design principle 4 says to adopt). Record the decision in MCP.md and CLAUDE.md's sanctioned-dependency list.
- [x] **Sanction `swift-argument-parser` explicitly.** Done 2026-07-04: added to CLAUDE.md's sanctioned third-party dependency list (Apple-authored, effectively first party; confined to the CLI target, no seam required). CLI.md already committed to it.
- [x] **Finalize package names.** Approved as scaffolded (2026-07-03): `TingraEventBus`, `TingraPlugInKit`, `TingraHost` under `packages/`, `apps/tingra-cli`. Recorded in ARCHITECTURE.md "Repository structure" and CLAUDE.md "Project Structure".
- [ ] **EventBusBasics identity.** Decide: evolve the shared personal `EventBusBasics` package upstream, or keep the Tingra-named port. The scaffold starts `TingraEventBus` as a port; the deltas in EVENTS.md are generic enough to upstream later. The SemVer/API-diff CI obligation from ARCHITECTURE.md lands on whichever package wins.
- [x] **Frame ownership rule for the `Input` seam.** Decided 2026-07-04: the draft rule stands — transfer at yield, one holder at a time, immutable after transfer — extended to audio buffers, with `CapturedFrame` and `CapturedAudio` as the only sanctioned `@unchecked Sendable` in the codebase. Permanent home: ARCHITECTURE.md, "Frame ownership across the `Input` seam"; the wrapper types restate it briefly. *(Flagged for Larry's veto in the step-2 summary before more work stacks on it.)*
- [ ] **Stream-key retention policy in the daemon.** MCP.md says keys pass through tool input into Keychain-backed secure storage, but not whether they persist. Recommendation: transient in v1 (key required per `stream_start`, deleted when the stream stops); persistence arrives with the destination model. One sentence in MCP.md.
- [ ] **Bundled plug-in shipping next to a bare binary** (referenced from CLI.md "Distribution"). ARCHITECTURE.md settles the CLI era — first-party plug-ins are compiled in, registering through the same code path the external bundle loader will use. Open for when the loader ships: app bundle style layout, staying compiled in, or a plug-ins directory installed by the Homebrew formula.
- [x] **Error-identifier registry.** Decided 2026-07-04, before the first `--json` error event shipped: the registry lives in CLI.md ("Error identifiers", next to the exit codes); the shape is bare lowerCamelCase (`authorizationDenied`, `inputNotFound`, `inputAmbiguous`, `invalidArgument`, `pipelineError`, `connectionFailed`, `connectionLost`), append-only, never renamed or reused. Error events carry `identifier` + human `message` params. Swift constants: `ErrorIdentifier` in `TingraPlugInKit` under the stability contract, with a test pinning every raw value.

- [x] **`stream --dry-run` scope in v1.** Decided 2026-07-04 (recorded in CLI.md, "Dry run"): dry-run validates the full flag surface and resolves inputs against the registry, but performs no network I/O, no TCC authorization check (checking would be the first prompt-triggering step on some paths, and authorization belongs to `start()`), and never reads the stream key (`--key-stdin` is validated for exclusivity only). Syntactic/cross-flag failures are argument-parser usage errors (exit 64, stderr); only registry resolution failures flow through the bus as `error` events with identifiers (exit 69). `--record` is excluded from the surface until roadmap step 5 adds it.

## CI follow-ups

Jobs promised in CLAUDE.md "Toolchain & CI" that were deliberately left out of the first `.github/workflows/ci.yml` because their prerequisites don't exist yet. Each lists its trigger condition:

- [ ] **Integration-test job** against the local ingest simulator (SIMULATOR.md) — add when the `apps/ingest-simulator` harness lands (roadmap step 3); a separate job run on streaming/output changes, not blocking every PR.
- [ ] **Packaging job** (Developer ID signing, hardened runtime, notarization, zip + stapled `.pkg`) — add when the release tooling and signing secrets exist (CLI.md "Distribution"; `tingra-cli` v1 ships at roadmap step 3).
- [ ] **API-diff job** (`swift package diagnose-api-breaking-changes` on `TingraPlugInKit` and `TingraEventBus`) — add when those packages get their first tag; the check diffs against the latest tag, so it has nothing to compare until then.

## De-risking

- [ ] **HaishinKit seam spike, before roadmap step 3 work stacks up.** The "clean seam" story rests on the assumption that HaishinKit 2.x accepts externally produced video buffers and audio with Tingra's PTS, compresses internally, and honors that timeline without its `MediaMixer`. A half-day throwaway spike (bars generator → HaishinKit → MediaMTX, verify with `ffprobe`) validates the append API before capture and composition work stacks on top of it.

## Release mechanics

- [ ] **Create the Homebrew tap repo** (e.g. `homebrew-tingra`) — it lives outside this monorepo and is not yet mentioned anywhere as a thing to create.
- [ ] **Define the product versioning scheme:** what `tingra-cli version` prints and what release tags look like in a monorepo that also independently SemVers the plug-in protocol package.
- [x] **Verify GitHub Actions macOS runners offer Xcode 26.6** before CI lands — runner images lag Xcode releases. Verified 2026-07-04: the `macos-26` arm64 image (version 20260630.0213.1) ships Xcode 26.6 (17F113) alongside 26.0.1–26.5, but defaults to 26.5 — so `.github/workflows/ci.yml` runs on `macos-26` and pins `DEVELOPER_DIR` to `/Applications/Xcode_26.6.app` rather than relying on the image default.

## Housekeeping

- [ ] **Commit the doc baseline** (the full doc set plus the LICENSE change is staged but uncommitted) so scaffolding diffs cleanly.
- [x] **Fix the dangling "the Tingra plan" references in CLI.md** ("decided in the Tingra plan", "tracked in the plan") — done 2026-07-04: the pre-repo planning document is never referenced from this repo (rule recorded in CLAUDE.md "Documentation"); the two sentences now point at MCP.md and this file's "Decisions to settle".
