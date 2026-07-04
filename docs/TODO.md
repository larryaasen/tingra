# TODO

Open decisions and roadmap progress. The authoritative step sequencing is ARCHITECTURE.md, "Roadmap sequencing"; the progress section here tracks where the work actually stands. Decision items (below) should each end as a sentence or two in the doc that owns them — none need a rewrite.

## Roadmap progress

- [x] **Step 1 — Monorepo scaffold + `tingra-cli devices`** *(complete 2026-07-04)*
  - [x] `apps/`/`packages/` split scaffolded: `TingraEventBus` (bus, redaction, 17 tests), `TingraPlugInKit` (protocol seams: `Input`, `StreamingService`, `EngineClock`, `PlugIn`), `TingraHost` (`HostClock`, `InputRegistry`), `tingra-cli` skeleton (`devices` stub, `version`).
  - [x] Review of package names, type names, and conventions (Larry, approved 2026-07-03) — final names recorded in CLAUDE.md "Project Structure" and ARCHITECTURE.md "Repository structure".
  - [x] Camera and microphone **input discovery** behind the `Input` seam: `packages/TingraCapturePlugIns` (`AVFoundationCapturePlugIn`, AVFoundation imported only there), registered through the `InputRegistering` seam into `InputRegistry` with `AVCaptureDevice.uniqueID` identifiers, activated via `PlugInLoader`.
  - [x] `tingra-cli devices` for real: human table + `--json` (stable `cameras`/`microphones` document per CLI.md); errors flow through the event bus console sink; listing output stays clean on stdout.
  - [x] First event bus **sinks**: `EventSink` protocol + `attach`/`shutdown` on the bus, `OSLogSink` (TingraHost, always-on), `ConsoleSink` (owned by the CLI; human lines to stderr, NDJSON to stdout).
  - [x] `scripts/format-swift.sh` / `check-format.sh` (swift-format, root `.swift-format` config: 4-space indent, 120 columns) and the GitHub Actions workflow `.github/workflows/ci.yml` (formatting check + warning-clean `swift build --build-tests` + `swift test` for every package and app, matrixed). Deferred jobs are tracked in "CI follow-ups" below.
- [ ] **Step 2** — camera/microphone inputs + generators (bars, tone) as the first plug-ins; `stream --dry-run`.
- [ ] **Step 3** — streaming: simulator harness (SIMULATOR.md), HaishinKit behind `StreamingService`; **`tingra-cli` v1 ships here**.
- [ ] **Step 4** — MCP server: `serve` daemon (launchd socket activation) + `mcp` proxy (MCP.md).
- [ ] **Step 5** — local recording (`--record`).
- [ ] **Steps 6–8** — app era: Metal composition/preview, production features, SRT/multiple destinations.

## Decisions to settle

- [ ] **MCP implementation dependency.** MCP.md commits the daemon to speaking MCP JSON-RPC natively but not *how*: the official `modelcontextprotocol/swift-sdk` or hand-rolled JSON-RPC framing. Recommendation: adopt the official Swift SDK behind the MCP/Control service boundary (JSON-RPC lifecycle, capability negotiation, and notifications are exactly the "thankless standardized parts" ARCHITECTURE.md design principle 4 says to adopt). Record the decision in MCP.md and CLAUDE.md's sanctioned-dependency list.
- [x] **Sanction `swift-argument-parser` explicitly.** Done 2026-07-04: added to CLAUDE.md's sanctioned third-party dependency list (Apple-authored, effectively first party; confined to the CLI target, no seam required). CLI.md already committed to it.
- [x] **Finalize package names.** Approved as scaffolded (2026-07-03): `TingraEventBus`, `TingraPlugInKit`, `TingraHost` under `packages/`, `apps/tingra-cli`. Recorded in ARCHITECTURE.md "Repository structure" and CLAUDE.md "Project Structure".
- [ ] **EventBusBasics identity.** Decide: evolve the shared personal `EventBusBasics` package upstream, or keep the Tingra-named port. The scaffold starts `TingraEventBus` as a port; the deltas in EVENTS.md are generic enough to upstream later. The SemVer/API-diff CI obligation from ARCHITECTURE.md lands on whichever package wins.
- [ ] **Frame ownership rule for the `Input` seam.** `CVPixelBuffer`/`CMSampleBuffer` are not `Sendable`; CLAUDE.md requires a deliberate, documented ownership rule rather than ad hoc `@unchecked`. A draft rule is written as the doc comment on `CapturedFrame` in `TingraPlugInKit` — review it, then give it a proper home (an ARCHITECTURE.md section or its own short doc).
- [ ] **Stream-key retention policy in the daemon.** MCP.md says keys pass through tool input into Keychain-backed secure storage, but not whether they persist. Recommendation: transient in v1 (key required per `stream_start`, deleted when the stream stops); persistence arrives with the destination model. One sentence in MCP.md.
- [ ] **Bundled plug-in shipping next to a bare binary** (referenced from CLI.md "Distribution"). ARCHITECTURE.md settles the CLI era — first-party plug-ins are compiled in, registering through the same code path the external bundle loader will use. Open for when the loader ships: app bundle style layout, staying compiled in, or a plug-ins directory installed by the Homebrew formula.
- [ ] **Error-identifier registry.** MCP.md promises exit-code semantics map to stable error identifiers, but nothing enumerates them. Decide where the list lives (CLI.md, next to the exit codes) and the naming shape (`authorizationDenied`, `inputNotFound`, …) before the first `--json` error event ships — they cannot be renamed after.

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
