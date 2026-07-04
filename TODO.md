# TODO

Open decisions and roadmap progress. The authoritative step sequencing is ARCHITECTURE.md, "Roadmap sequencing"; the progress section here tracks where the work actually stands. Decision items (below) should each end as a sentence or two in the doc that owns them — none need a rewrite.

## Roadmap progress

- [ ] **Step 1 — Monorepo scaffold + `tingra-cli devices`** *(in progress)*
  - [x] `apps/`/`packages/` split scaffolded: `TingraEventBus` (bus, redaction, 17 tests), `TingraPlugInKit` (protocol seams: `Input`, `StreamingService`, `EngineClock`, `PlugIn`), `TingraHost` (`HostClock`, `InputRegistry`), `tingra-cli` skeleton (`devices` stub, `version`).
  - [ ] Review of package names, type names, and conventions (Larry) — then record the final names in CLAUDE.md "Project Structure" and ARCHITECTURE.md "Repository structure".
  - [ ] Camera and microphone **input discovery** behind the `Input` seam (AVFoundation stays inside the plug-in), registered through `InputRegistry`, with stable identifiers.
  - [ ] `tingra-cli devices` for real: human table + `--json` (stable identifiers per CLI.md), wired through the event bus console sink.
  - [ ] First event bus **sinks** (OSLog sink always-on; console sink owned by the CLI).
  - [ ] `scripts/format-swift.sh` / `check-format.sh` and the GitHub Actions workflows (formatting, build, unit tests per package).
- [ ] **Step 2** — camera/microphone inputs + generators (bars, tone) as the first plug-ins; `stream --dry-run`.
- [ ] **Step 3** — streaming: simulator harness (SIMULATOR.md), HaishinKit behind `StreamingService`; **`tingra-cli` v1 ships here**.
- [ ] **Step 4** — MCP server: `serve` daemon (launchd socket activation) + `mcp` proxy (MCP.md).
- [ ] **Step 5** — local recording (`--record`).
- [ ] **Steps 6–8** — app era: Metal composition/preview, production features, SRT/multiple destinations.

## Decisions to settle

- [ ] **MCP implementation dependency.** MCP.md commits the daemon to speaking MCP JSON-RPC natively but not *how*: the official `modelcontextprotocol/swift-sdk` or hand-rolled JSON-RPC framing. Recommendation: adopt the official Swift SDK behind the MCP/Control service boundary (JSON-RPC lifecycle, capability negotiation, and notifications are exactly the "thankless standardized parts" ARCHITECTURE.md design principle 4 says to adopt). Record the decision in MCP.md and CLAUDE.md's sanctioned-dependency list.
- [ ] **Sanction `swift-argument-parser` explicitly.** CLI.md already commits to it, but CLAUDE.md's sanctioned third-party dependency list names only HaishinKit and MediaMTX. Add it (Apple-authored, effectively first party).
- [ ] **Finalize package names.** The scaffold proposes `TingraEventBus`, `TingraPlugInKit`, and `TingraHost` under `packages/` — review, tweak, then update the "Repository structure" section in ARCHITECTURE.md and the Project Structure section in CLAUDE.md to record the final names.
- [ ] **EventBusBasics identity.** Decide: evolve the shared personal `EventBusBasics` package upstream, or keep the Tingra-named port. The scaffold starts `TingraEventBus` as a port; the deltas in EVENTS.md are generic enough to upstream later. The SemVer/API-diff CI obligation from ARCHITECTURE.md lands on whichever package wins.
- [ ] **Frame ownership rule for the `Input` seam.** `CVPixelBuffer`/`CMSampleBuffer` are not `Sendable`; CLAUDE.md requires a deliberate, documented ownership rule rather than ad hoc `@unchecked`. A draft rule is written as the doc comment on `CapturedFrame` in `TingraPlugInKit` — review it, then give it a proper home (an ARCHITECTURE.md section or its own short doc).
- [ ] **Stream-key retention policy in the daemon.** MCP.md says keys pass through tool input into Keychain-backed secure storage, but not whether they persist. Recommendation: transient in v1 (key required per `stream_start`, deleted when the stream stops); persistence arrives with the destination model. One sentence in MCP.md.
- [ ] **Error-identifier registry.** MCP.md promises exit-code semantics map to stable error identifiers, but nothing enumerates them. Decide where the list lives (CLI.md, next to the exit codes) and the naming shape (`authorizationDenied`, `inputNotFound`, …) before the first `--json` error event ships — they cannot be renamed after.

## De-risking

- [ ] **HaishinKit seam spike, before roadmap step 3 work stacks up.** The "clean seam" story rests on the assumption that HaishinKit 2.x accepts externally produced video buffers and audio with Tingra's PTS, compresses internally, and honors that timeline without its `MediaMixer`. A half-day throwaway spike (bars generator → HaishinKit → MediaMTX, verify with `ffprobe`) validates the append API before capture and composition work stacks on top of it.

## Release mechanics

- [ ] **Create the Homebrew tap repo** (e.g. `homebrew-tingra`) — it lives outside this monorepo and is not yet mentioned anywhere as a thing to create.
- [ ] **Define the product versioning scheme:** what `tingra-cli version` prints and what release tags look like in a monorepo that also independently SemVers the plug-in protocol package.
- [ ] **Verify GitHub Actions macOS runners offer Xcode 26.6** before CI lands — runner images lag Xcode releases.

## Housekeeping

- [ ] **Commit the doc baseline** (the full doc set plus the LICENSE change is staged but uncommitted) so scaffolding diffs cleanly.
- [ ] **Fix the dangling "the Tingra plan" references in CLI.md** ("decided in the Tingra plan", "tracked in the plan") — that document is not in the repo; either bring it in or repoint those sentences at MCP.md/CLI.md themselves.
