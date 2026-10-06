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

- [ ] **SRT reconnect on a mid-stream loss.** HaishinKit 2.x's SRT publish
  path pushes no event when a live link dies (`SRTConnection.connected` flips
  false only on our own `close()`), so an SRT leg reports start-time failures
  but never `connectionLost`, and the reconnect machinery never fires for it.
  SRT's own retransmission covers ordinary packet loss; the gap is the
  hard-timeout case. It also blinds the last-live-leg rule: a mixed RTMP + SRT
  run whose RTMP leg dies keeps going on an SRT leg that may be dead. Waits on
  a HaishinKit surface that pushes the loss, or a sanctioned liveness read —
  never a poll loop. Records: DONE.md, "Step 8, SRT output" and "SRT ships the
  prebuilt libsrt"; ARCHITECTURE.md, "How HaishinKit is incorporated".

- [ ] **Left open from “Build, test, and check by hand the cloud session's
  untested Swift”** (done; record in DONE.md, "Housekeeping"):
  - **Dropped frames in a recording.** The app recording force-quit on
    2026-09-29 holds 897 of 900 video frames: two missing at exactly 10.0 s
    (the first fragment boundary) and three at 12.0 s (not a boundary); the
    20 s boundary is clean. `AVAssetWriterBackend` drops a frame whenever
    `isReadyForMoreMediaData` is false, and writing a fragment may be what
    makes it briefly false, but the 12 s gap shows frames drop without one.
    Measure over a longer take (count frames and DTS steps with `ffprobe`)
    before changing anything.

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
    - [ ] Follow-ups: safe mode, the Plug-ins settings pane, `tingra-cli
      plug-ins`, the `TingraPlugInSDK` release script and repo, the 1.0.0 tag
      after NDI (Decision 29). *Designed 2026-09-27 as Decisions 30–37
      (PLUGINS.md, "The bundle loader's follow-ups: the design"), awaiting
      Larry's veto; nothing built yet.*
      - [x] Decision 30: the CLI's release build via `xcodebuild`, kits as
        frameworks in `Frameworks/` beside the binary, with coverage off
        and a packaging check for `__llvm_prf` sections (the generated scheme
        instrumented the check's Release build, which then wrote
        `default.profraw` wherever it ran); plus the three small defects the
        manual check found (`loadFailed` message carrying dyld's
        unabbreviated home path, the misleading `noPrincipalClass` for a
        second kit copy, the fixture input's missing `media`). *Built
        2026-09-27 (PLUGINS.md, "Decision 30 built"): `CLANG_COVERAGE_MAPPING=NO`
        because `-enableCodeCoverage` is test-only, the rpath Release-only,
        the version read from the staged binary, the zip made with
        `ditto --norsrc` (Homebrew's `unzip` would write `._` files into the
        frameworks and break their seal), the `.pkg`'s framework components
        pinned (not relocatable, not version-checked). A Developer ID signed,
        hardened copy loaded the fixture from the user folder; the notarized
        release and a Homebrew install of the new layout come with the next
        release.*
      - [x] Decisions 31–34: safe mode (Shift, the offer after an unclean
        exit, `--safe-mode`), the load-crash guard, `plug-ins.json`.
        *Built 2026-09-28: the loader takes one bundle at a time inside a
        per-process marker, skips turned-off, crashed, and safe-mode
        bundles (`plugin.skipped`), and reports `plugin.safeMode`; the app
        reads Shift and makes the offer in `applicationWillFinishLaunching`,
        and ends its subtitle in "Safe Mode"; the Data pane lists Plug-ins
        Turned Off. Verified end to end in the packaged CLI with the
        fixture (normal, safe mode, a dead process's marker, a new build,
        turned off, an unreadable file). Decision 30's rpath moved from the
        manifest to the packaging script. TingraHost 278, CLI 88, app 781.*
        - [x] Larry: check the app's half by hand — Shift at launch, the
          offer after stopping a run from Xcode with the fixture installed,
          and the subtitle. *Done 2026-09-29.*
      - [x] Decision 38: move app-tier plug-ins' app-scoped files out of the
        Plug-ins folder, into `Plug-in Data/<id>/`, so Remove All Data never
        deletes an installed bundle. *Approved and built 2026-09-29.*
      - [x] Each event once, and in the unified log, in every front end
        (2026-09-29, found while reading the safe-mode log). The app's
        stdout `ConsoleEventSink` is attached only when `TINGRA_CONSOLE_LOG=1`,
        set by the scheme's Run action and `run-app.sh`, and then prints
        every group in the log file's format while `OSLogSink` is left off,
        since Xcode's console shows the unified log too (Larry wanted the
        log file's format in Xcode, not the OSLog copy). `tingra-cli` attaches `OSLogSink` on every run: the
        2026-07-04 rule skipping it for a terminal rested on a mirror
        macOS does not provide (measured: only `OS_ACTIVITY_DT_MODE`
        copies `os_log` to a terminal), so interactive runs were missing
        from the unified log. `OSLogAttachment` and its two tests are gone.
        An interactive `devices` run printed its table once, and its events
        appeared under `/usr/bin/log show --info`.
      - [x] Decision 35: `tingra-cli plug-ins [--json] [--safe-mode]`,
        `plug-ins enable|disable <id>`. *Built 2026-09-29 (PLUGINS.md,
        "Decision 35 built"): `PlugInLoadReport` joined in the host
        (`PlugInActivation.report`, the scan's `found`), bundle name and
        version from the Info.plist, a `message` on every skip, `serve`'s
        engine factored into `DaemonEngine` so the listing matches the
        daemon, `list` the default subcommand. Verified end to end in the
        packaged CLI with the fixture (active, refused, disabled, safe mode,
        a crash, enable). TingraHost 293, CLI 99.*
      - [x] Decision 36: the Plug-ins settings pane. *Built 2026-09-30
        (PLUGINS.md, "Decision 36 built"): `PlugInsSettingsView` after
        Logging, one row per plug-in over the launch's `PlugInLoadReport`
        (`EngineModel.plugInReport`) joined to the app tier
        (`PlugInListing`), Tingra's toggle writing `plug-ins.json` through
        `PlugInEnablementModel` with "Takes effect the next time Tingra
        opens", refusals with Show in Finder, Manage… presenting
        `EXAppExtensionBrowserViewController`, Open Plug-ins Folder, the
        Shift hint, and the safe-mode banner; the plug-ins' settings panes
        are under Plug-in Settings. App 807 tests.*
        - [x] Larry: look at the pane in the running app — a toggle and its
          line, a refused bundle's Show in Finder, the Manage… sheet, and
          the banner in safe mode. *Done 2026-09-30.*
      - [x] Decision 37: `scripts/release-sdk.sh`, `release-sdk.yml`,
        `packaging/sdk/`. *Built 2026-09-30 (PLUGINS.md, "Decision 37
        built"): one archive of the kit builds both frameworks, each
        XCFramework carries its `.swiftinterface` and dSYM, a probe plug-in
        builds against the rendered development package with the compiler
        reading only the interfaces, the install names are checked, the
        XCFrameworks are Developer ID signed, publishing tags here then
        releases a draft on the SDK repo and checks the published zips'
        checksums. Without `TINGRA_SIGN_ID` it builds a development SDK into
        `dist/sdk` and publishes nothing. Run with `--build-only` and
        `--dry-run` only. An Xcode bundle built against the development
        package loaded in the packaged CLI.*
        - [x] Decision 51 (approved and built 2026-10-03): Xcode embeds the
          SDK's binary frameworks into a bundle and nothing can stop it, so
          the loader reports `embeddedKit` only for a kit copy in another
          form than the host's, and the SDK's README explains the copy
          instead of saying Do Not Embed. TingraHost 302.
        - [x] Xcode pinned at 27.0 (2026-10-03): every workflow runs on the
          `xcode-27` image with `DEVELOPER_DIR` at Xcode 27.0, the new
          toolchain floor, and `release-sdk.sh` reads its floor from the
          workflow.
        - [ ] Larry: watch the first Format & Test run on the `xcode-27`
          image, which GitHub still marks as a preview.
        - [ ] Larry: create the public `larryaasen/tingra-plug-in-sdk`
          (empty is fine) and extend `TINGRA_RELEASE_TOKEN` to it.
        - [ ] Larry: the first publish, through Actions → Release
          TingraPlugInSDK (Xcode 27.0, the same as a local build here).
        - [ ] Larry: run the app half of the end-to-end check — an
          SDK-built bundle in the user folder, loaded by Tingra.app. His
          debug instance was running, so a session could not.
  - [ ] **NDI as an external plug-in bundle**, outside this repo, importing
    the closed-source SDK: an NDI input and an NDI output. Waits on the
    loader; NDI's own virtual input is the stopgap the capture plug-in
    already sees as a camera.
  - [ ] **Plug-ins Phase 5, the plug-in gallery** (PLUGINS.md, "Phase 5 —
    the plug-in gallery"): a Plug-in Gallery window listing free plug-ins,
    modelled on VS Code's Extensions view over a signed static index in a
    public repo. *Proposed 2026-09-30 as Decisions 39–50, awaiting
    approval.* Waits on both kits at 1.0.0 (after NDI), Tingra.app
    shipping, and Decisions 35–37.

## Clock and timing

Found by the 2026-10-03 review of CLOCK.md against the code. CLOCK.md states
the rule each of these breaks or leaves unbuilt.

- [ ] **Left open from “Streamed audio sits behind video by the time the
  destination took to connect”** (fixed 2026-10-04; record in DONE.md, "Clock
  and timing"):
  - **SRT audio leads video by about 100 ms.** Seen while confirming the fix:
    over SRT the beep arrived 98 ms and 119 ms ahead of the flash, with no
    backlog and with a two second one alike, so it is not the pre-`T0`
    defect. RTMP on the same probe reads 10 to 50 ms. Not diagnosed; the
    read-back was the simulator's RTMP side, so first rule out MediaMTX's
    remux by reading the stream back over SRT.
  - **An integration scenario with a flash and a beep.** The probe was a
    throwaway and is gone; nothing in `scripts/integration-test.sh` measures
    A/V offset, and its generators have no sync signal. A flash-and-beep
    generator plus a server side onset check would hold this fix and catch
    the SRT offset above.

- [ ] **Nothing keeps the Mac or the process awake during a session.** No
  power assertion, no declared activity, and no App Nap opt-out anywhere in
  the engine or the app, so an idle sleep pauses a live stream or recording
  for its length (CLOCK.md, "System sleep and App Nap"). First check whether
  a running capture session already holds the Mac awake (`pmset -g
  assertions` during a stream). Then hold one for the life of a session,
  behind a host seam so the CLI and the daemon get it too. Related: the
  `caffeinate -d` question in the display sleep item above.

- [ ] **The SRT service measures its frame rate on its own clock.**
  `SRTHaishinKitStreamingService` keeps a `ContinuousClock` for its frames
  per second figure: not the injected `EngineClock`, and it counts sleep, so
  the first reading after a wake is wrong. It stamps no media. Use the
  injected clock.

- [ ] **Sync offset is designed and unbuilt.** GLOSSARY.md and CLOCK.md
  define it as a persisted setting; nothing applies or stores one, and
  comments in `CameraInput.swift` and `Input.swift` say it joins "when it
  lands". CLOCK.md, "Sync offset" records why a timestamp shift is not
  enough: the compositor and the mixer never read a captured PTS, so the
  offset has to be a delay at the video slot and in the channel queue. Decide
  where it sits on the roadmap.

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

- [ ] **Tingra needs a logo** *(added 2026-10-04)*. One mark, used everywhere
  the project shows its face: the GitHub repository
  (https://github.com/larryaasen/tingra — the README header and the social
  preview image), the macOS app (the `Tingra.app` icon, the About window),
  and other places as they come up (the Homebrew tap README, the
  `tingra-plug-in-sdk` repository, the `.pkg` installer, a future website).
