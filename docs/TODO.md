# TODO

Open decisions and roadmap progress. The authoritative step sequencing is
ARCHITECTURE.md, "Roadmap sequencing"; the progress section here tracks where
the work actually stands. Decision items (below) should each end as a sentence
or two in the doc that owns them — none need a rewrite.

Finished items move to [DONE.md](DONE.md) with their full records, so this
file lists only open work. An open check left inside a finished item stays
here, under "Left open from “…”", pointing at its record there.

## Roadmap progress

- [ ] **Display capture across display sleep: built 2026-09-26, not yet seen
  working live.** ScreenCaptureKit stops a display capture whenever the
  displays sleep; `DisplayInput` now reports that as `input.interrupted` and
  restarts on `NSWorkspace`'s screen wake (`input.resumed`). The state machine
  is unit-tested (ARCHITECTURE.md, "Display capture across display sleep").
  Remaining: run the new build, put Display 2 in a shot, `pmset
  displaysleepnow`, wake, and confirm the layer moves again and the log
  shows the interrupted/resumed pair. `tingra-cli` cannot restart (a
  command-line process receives no screen wake notification) — decide
  whether that wants `caffeinate -d` guidance in CLI.md or more.

- [ ] **Two small defects seen while building the stream's Stopping state
  (2026-09-26), not fixed.** (1) Record has the gap Stop Streaming had: while
  a recording is finishing (`RecordingStatus.finalizing`) `RecordButton`
  already reads Record and can be clicked. (2) `EngineModel.destinationStates`
  is never cleared when a stream ends, though its doc comment says it is empty
  when not streaming, so the Streaming pane's per-destination status rows can
  keep reading Live after a stop.

- [ ] **Steps 7–8** — app era: production features (presets, shots, layers,
  transitions, audio mixer) *(step 7 complete 2026-07-20)*, SRT/multiple
  destinations/WHIP-WHEP *(step 8: **both decided deliverables landed** — SRT
  2026-07-24, multiple destinations 2026-07-26; **WHIP/WHEP remains**, and is
  deliberately ungated by a date — ARCHITECTURE.md sequences it "as support
  matures", i.e. when `RTCHaishinKit` leaves alpha. Nothing else in step 8 is
  outstanding, so the next production iteration is a scoping call, not a
  queued item)*.

- [ ] **Step 10 — content, snapshots, the Library, the log window, and the
  bundle loader** *(planned 2026-09-10 from Larry's napkin sketch; the design
  record is ARCHITECTURE.md, "Step 10")*. Seven iterations in a decided order,
  each still to be designed and recorded before its code under the
  decide-then-build rule. Set aside from the sketch: **audio mixer
  improvements** (Larry scopes those separately — the first slice opened
  2026-09-12 as "The console mixer", below) and a bottom panel under the
  content column (rejected — the Library goes in the trailing column).
  - [ ] **Left open from “Snapshots”** (done; record in DONE.md):
    - [ ] Check by hand: the first snapshot into `~/Pictures` raises no TCC
      prompt from a fresh permission state, and the Library's tab strip fits
      the sidebar at its narrowest (280 points). Not seen by the building
      session, which had no screen-capture or accessibility grant.
    - [ ] Deferred from the record: a `program.snapshot` MCP tool returning
      image content, so an agent can see the program (needs a daemon-side
      program-frame accessor; the writer then moves to
      `TingraComposition`); Copy Snapshot; JPEG/HEIC; interval capture.
  - [ ] **Left open from “The Recordings tab”** (done; record in DONE.md):
    - [ ] Check by hand: three segments at 280 points (the heading yields,
      the titles never abbreviate), and a take appearing as its own row when
      Record is pressed and turning playable, with its length, on stop. Not
      seen by the building session, which had no screen-capture or
      accessibility grant.
  - [ ] **Left open from “The console mixer”** (done; record in DONE.md):
    - [ ] Check by hand: the column proportions and the readouts at the
      small control size, the horizontal scroll with many strips, and a
      double-click on a fader returning it to unity. Not seen by the
      building session — Larry's Xcode debug instance was running.
    - [ ] Later slices, each named in the record: typed dB entry, a scale
      beside the meter, narrow/wide strips, solo as pre-fader listen on the
      monitor bus (never in place), strip color and icon, in-place rename.
  - [ ] **Left open from “Bounded frame streams”** (done; record in DONE.md):
    - [ ] **What grew main-thread load over the first eleven minutes** of
      both leaking sessions is not known; with the streams bounded it is a
      performance question, not a memory one. Measure with the log window
      open and closed once the monitor draw cadence is fixed. *A likely
      part of it, found 2026-09-26:* the log window's lazy `ScrollView`
      spent about 0.7 s of main thread per arriving line with a full chunk
      loaded (18,623 lines), and held 321 MB and growing; it is now an
      `NSTableView` (`LogLineTable`, about 11 ms a line, 32 MB — ARCHITECTURE.md,
      "The log window").
    - [ ] **Bound the inputs' `frames()`/`audio()` streams** — generators,
      media, capture. Their consumers are nonisolated and were healthy, but
      the buffers are unbounded; `Input.frames()` has no policy parameter
      (stability contract), so the bound goes inside each conformer, with
      the generators' and media tests taught to attach before ticking.
  - [ ] **Left open from “Meters off the SwiftUI clock”** (done; record in DONE.md):
    - [ ] Every pass in the main window ran twice, about a millisecond
      apart — one in the display cycle's commit, a second in the idle step
      that follows, set off by the first pass's own invalidation. With the
      meters off the clock the passes are event-driven and rare, but each
      one (a fader drag's, say) still costs double. Not yet traced to a
      cause.
  - [ ] **Plug-ins Phase 2, the rest** (PLUGINS.md, same section for the
    sequencing): declared parameters on every host-tier registration
    (Decision 15) — *built 2026-09-15 as the third slice: `Parameter` and
    `ParameterDescribing` on every registration, `Input.setParameters`,
    `Destination`/`RecordingFile.parameters`, `Project.inputParameters`, the
    tone's frequency and level behind the strip's Input Settings button;
    the destination editor and video-input hook wait for a provider that
    declares something*; the narrowed secure-storage method — *built
    2026-09-17 as the fourth slice: `tingra/secrets.get`/`set`,
    `PlugInConnection.secret(named:)`/`setSecret(_:named:)`,
    `PlugInSecretStore` filing `plugin:<id>.<name>` in the engine's Keychain
    store, the Data pane's Plug-in Secrets and Plug-in Data kinds*; windows
    and status bar items — *built 2026-09-18 as the fifth slice:
    `WindowDescriptor` (a pane in a window of its own, opened by a command's
    `showsWindow`, one `WindowGroup(for: PaneID.self)` scene) and
    `StatusItemDescriptor` with `tingra/statusItem.set` /
    `PlugInConnection.setStatusText(_:for:)`, drawn by the app at the status
    bar's trailing end and dropped when the plug-in stops; verified in the
    running app; leading-sidebar hosting still deferred*; the app-owned
    `program_stream_start`/`program_stream_stop`/`program_record_start`/
    `program_record_stop` tools (Decision 17) — *built 2026-09-18 as the
    sixth slice: argument-free, each naming a state rather than a toggle
    (`changed`), results in `tingra://session`'s shape, through the
    `ProgramOutputControlling` seam; not yet called against a live stream*;
    the opt-in `tingra/meters` notification at ≤ 10 Hz (Decision 18) —
    *built 2026-09-18 as the seventh slice: `tingra/meters.subscribe`,
    linear levels inline, `MeterFeed` folding mix blocks into windows,
    `PlugInConnection.meters()`*; and frames (spike row 4) — *built
    2026-09-18 as the eighth slice: the bus's own `IOSurface` attached to a
    `tingra/frame` notification (`SurfaceMessageTransport`), one per
    `tingra/frame.next` demand, `PlugInConnection.frames(_:)` and
    `BusMonitorView`; Decisions 20 and 21 approved 2026-09-22, the
    shared-memory blit question still open; neither slice yet watched in the
    running app (his debug instance was up)*. Phase 2's seams are all built.
  - [ ] **Left open from “The external bundle loader”** (done; record in DONE.md):
    - [ ] Manual check: a signed bundle in
      `~/Library/Application Support/Tingra/Plug-ins` loads in the running
      app and in `tingra-cli devices`, and a quarantined unnotarized one is
      refused with its `plugin.bundle` event.
    - [ ] Follow-ups: safe mode, the Plug-ins settings pane, `tingra-cli
      plug-ins`, the `TingraPlugInSDK` release script and repo, the 1.0.0 tag
      after NDI (Decision 29).
  - [ ] **NDI as an external plug-in bundle**, outside this repo, importing
    the closed-source SDK: an NDI input and an NDI output. Waits on the
    loader; NDI's own virtual input is the stopgap the capture plug-in
    already sees as a camera.

## Decisions to settle

- [ ] **Left open from “The log file and the Logging settings pane — decided 2026-09-07, built 2026-09-08.”** (done; record in DONE.md):
  - [ ] **Rotation, only if measured.** No rollover ships with the pane. Run
    one real production session on the built app, read the log's size from
    the pane, and hand Larry the number; a size-based rollover is proposed
    only if it says so — instrument before guessing. First data point,
    2026-09-08: 28 KB after about forty minutes of test runs and settings
    clicks, no streaming or recording — not yet the session that decides.

- [ ] **Bundled plug-in shipping next to a bare binary** (referenced from CLI.md
  "Distribution"). ARCHITECTURE.md settles the CLI era — first-party plug-ins are
  compiled in, registering through the same code path the external bundle loader
  will use. Open for when the loader ships: app bundle style layout, staying
  compiled in, or a plug-ins directory installed by the Homebrew formula.

## CI follow-ups

Jobs promised in CLAUDE.md "Toolchain & CI" that were deliberately left out of
the first `.github/workflows/ci.yml` because their prerequisites don't exist yet.
Each lists its trigger condition:

- [ ] **API-diff job** (`swift package diagnose-api-breaking-changes` on
  `TingraPlugInKit` and `TingraEventBus`) — add when those packages get their
  first tag; the check diffs against the latest tag, so it has nothing to
  compare until then.

## De-risking
Nothing open.

## Release mechanics

- [ ] **Daemon shows the signer's name, not "Tingra", in Login Items & Extensions
  → App Background Activity** *(found 2026-07-11)*. macOS groups a standalone
  LaunchAgent by its **code-signing identity**; with an individual Developer ID
  the certificate's org name is the person's legal name ("Larry Aasen"), so that
  is what displays. Apps that show a product name there (1Password, ChatGPT) are
  app bundles registered via `SMAppService`. **No plist/Info.plist key overrides
  this for a bare CLI** (if `CFBundleName` were used it would already read
  "tingra-cli"). **Fix when the phase-3 `Tingra.app` ships:** register the daemon
  via `SMAppService` (or give the plist `AssociatedBundleIdentifiers =
  com.moonwink.tingra`) so macOS resolves the name to the app and displays
  "Tingra". Resolved by the decision below — once the app bundles the CLI, every
  install path has the app present, so this stops being a CLI-only edge case.
  Cosmetic only meanwhile; the daemon is unaffected.

- [ ] **Package `tingra-cli mcp` as a Claude Desktop Extension (`.mcpb`)**
  *(found 2026-07-11)*. Claude Desktop has no UI form for adding a local stdio
  MCP server by command — connecting Tingra means editing `claude_desktop_config.json`
  (Settings → Developer → Edit Config opens it, but it's still hand-written JSON;
  documented in README.md "Use it from Claude" and the tap README). The only
  genuine no-file-editing path is a **Desktop Extension**: a `.mcpb` bundle
  (manifest + the server) installed via Settings → Extensions → Advanced settings
  → Extension Developer → Install Extension…, or eventually listed in Anthropic's
  extension directory. Scope: an `mcpb`-format manifest wrapping the signed
  `tingra-cli` binary with `args: ["mcp"]`, built and versioned alongside the
  existing packaging pipeline (`scripts/release-cli-package.sh`/`release-cli-publish.sh`). Worth
  revisiting once `Tingra.app` exists (previous item) — the extension could point
  at the app-bundled CLI rather than a separate artifact. Not started; a real
  scoped project, not a quick add.

## Generator plug-ins

Issues found in a 2026-07-07 review of `packages/TingraGeneratorPlugIns` (see
GeneratorPlugIn.swift and the Bars/Alignment/Pluge/Tone generators). All three
fixed together on 2026-08-06.

Nothing open.

## Housekeeping
Nothing open.
