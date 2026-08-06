# TODO

Open decisions and roadmap progress. The authoritative step sequencing is
ARCHITECTURE.md, "Roadmap sequencing"; the progress section here tracks where
the work actually stands. Decision items (below) should each end as a sentence
or two in the doc that owns them — none need a rewrite.

## Roadmap progress

- [x] **App discovery gaps: all four findings** *(code complete 2026-07-28)*.
  The four findings from the 2026-07-28 test log. The two design-shaped ones
  — live device lists, and the private-aggregate filter — were **recorded and
  approved before any code** under the decide-then-build rule; their full
  records are in ARCHITECTURE.md and in "Decisions to settle" below, and the
  go-ahead **included display hot-plug**. The two small ones needed no record
  of their own and are below.
  - [x] **Live device lists in the app.** The app now refreshes `cameras`,
    `displays`, `videoInputs`, and `audioInputs` from the input registry on
    every `device.connected`/`device.disconnected` event, sharing the bus
    consumer that already carried stream status — attached before the
    plug-ins activate, so no first-session event is missed. A vanished device
    stays selected, bound, and stripped, dormant everywhere; a hot-plugged
    one always arrives **muted**, because the refresh syncs the active preset
    first and so can never fall through to `MixerStrip.seed`. Stops now
    report `reason: "disconnected"` where the input has left the registry.
  - [x] **Display hot-plug in the capture plug-in.**
    `ScreenCaptureKitCapturePlugIn` gained `DisplayChange` /
    `DisplayEventReporter` over `CGDisplayRegisterReconfigurationCallback` —
    the mirror of `DeviceEventReporter`, same registry-before-event ordering,
    same event names with `kind=display`, same injected-stream test seam.
    Changes are read by **diffing display snapshots** rather than from the
    callback's `CGDirectDisplayID`, because a removed display's id no longer
    resolves to the UUID that is its only stable identifier — which also
    means a resolution or arrangement change reports nothing instead of a
    spurious disconnect/reconnect pair.
  - [x] **The private aggregate filter.** `AVAudioEngineMonitor` now pairs
    the has-output-channels test with a private-aggregate test in one
    `isMonitorable(_:)`, so `outputDevices()` and `deviceID(forUID:)` cannot
    disagree. The rule is a pure `isPrivateComposition(_:)`, unit-tested in
    both directions with no audio hardware.
  - [x] **The phantom `camera.picker` tap at boot.** `ContentView`'s
    `.onChange(of:)` handlers reported their taps, so the model assigning the
    default camera and display during boot recorded two taps with no user
    involved — a synthetic entry in exactly the record macro capture and
    replay would read back (EVENTS.md, "The `tap` convention"). Fixed by a
    shared `Binding.reportingTap(to:_:domain:params:)`: a control's binding
    setter runs only when the control is operated, so the **tap** moves there
    while the **effect** (`reconfigure()`) stays in `onChange`, where it must
    run however the value changed. Applied to all five pickers, not just the
    two that were firing — the other three (`transition`, `wipeEdge`,
    `shaderName`) were only safe because nothing assigns them
    programmatically *yet*, which is not a property worth relying on, and one
    file with two mechanisms is worse than one with either. EVENTS.md's
    convention amended: it had named `onChange` as the right place.
  - [x] **The monitor picker's invalid selection at startup.**
    `MixerView`'s picker bound to the persisted `monitorDeviceUID` while
    `monitorDevices` filled asynchronously, so no tag matched on first render
    — SwiftUI's "undefined results", logged twice. Fixed by giving the
    picker an entry for a selection the device list cannot currently
    resolve, labelled from a `MonitorPreferences.deviceName` cache and marked
    "Not connected" (`de`/`es` added) — the dormant channel strip, one
    control over. This covers the *second* way to reach an unmatched
    selection too, which the startup race had been masking: a chosen device
    that is unplugged stays deliberately selected so it resumes on return.
    The same entry is what lets the camera and display pickers keep a
    vanished selection under "Live device lists in the app".

  Tests: `TingraAudio` 61 → 66, `TingraCapturePlugIns` 30 → 38,
  `apps/tingra` 123 → 131 — **795 across 13 targets**, warning-clean.
  `check-format` was **not** clean at `e1c9f59` — a stray trailing blank line
  in `PresetEdit.swift`, unrelated and now removed. `integration-test.sh` not
  re-run: nothing in the streamed path changed, and `tingra-cli` loads only
  the AVFoundation plug-in, so it never installs the display callback.

- [x] **Step 1 — Monorepo scaffold + `tingra-cli devices`** *(complete 2026-07-04)*
  - [x] `apps/`/`packages/` split scaffolded: `TingraEventBus` (bus, redaction,
    17 tests), `TingraPlugInKit` (protocol seams: `Input`, `StreamingService`,
    `EngineClock`, `PlugIn`), `TingraHost` (`HostClock`, `InputRegistry`),
    `tingra-cli` skeleton (`devices` stub, `version`).
  - [x] Review of package names, type names, and conventions (Larry, approved
    2026-07-03) — final names recorded in CLAUDE.md "Project Structure" and
    ARCHITECTURE.md "Repository structure".
  - [x] Camera and microphone **input discovery** behind the `Input` seam:
    `packages/TingraCapturePlugIns` (`AVFoundationCapturePlugIn`, AVFoundation
    imported only there), registered through the `InputRegistering` seam into
    `InputRegistry` with `AVCaptureDevice.uniqueID` identifiers, activated via
    `PlugInLoader`.
  - [x] `tingra-cli devices` for real: human table + `--json` (stable
    `cameras`/`microphones` document per CLI.md); errors flow through the event
    bus console sink; listing output stays clean on stdout.
  - [x] First event bus **sinks**: `EventSink` protocol + `attach`/`shutdown`
    on the bus, `OSLogSink` (TingraHost), `ConsoleSink` (owned by the CLI;
    human lines to stderr, NDJSON to stdout).
  - [x] `scripts/format-swift.sh` / `check-format.sh` (swift-format, root
    `.swift-format` config: 4-space indent, 120 columns) and the GitHub Actions
    workflow `.github/workflows/ci.yml` (formatting check + warning-clean
    `swift build --build-tests` + `swift test` for every package and app,
    matrixed). Deferred jobs are tracked in "CI follow-ups" below.

- [x] **Step 2** — camera/microphone inputs + generators + `stream --dry-run` +
  `devices --watch` *(complete 2026-07-04)*
  - [x] Generators as the first full plug-ins:
    `packages/TingraGeneratorPlugIns` (`GeneratorPlugIn`, `BarsGenerator` —
    SMPTE bars with burned in timecode, IOSurface 32BGRA tagged BT.709;
    `ToneGenerator` — 440 Hz mono float32), synthesized on the injected clock's
    tick, fully deterministic under the synthetic clock. The permanent CI test
    surface; added to the CI matrix.
  - [x] Real capture in `TingraCapturePlugIns`: `CameraInput` (AVCaptureSession,
    32BGRA IOSurface output, BT.709 tagged at the seam, host-time PTS passed
    through) and `MicrophoneInput` (AVAudioEngine input tap selected by Core
    Audio UID; PTS from `AVAudioTime.hostTime`, buffers without host time are
    skipped, never restamped). Hardware paths behind seams; unit tests cover the
    injected-authorization denied path, PCM→`CMSampleBuffer` conversion, and
    tagging.
  - [x] `device.connected`/`device.disconnected` events from the capture
    plug-in's AVFoundation notifications (`DeviceEventReporter`; normal events,
    never errors, never polling) — consumed by `devices --watch` now and
    `stream` sessions at step 3. The reporter also keeps the registry current
    (register on connect, unregister on disconnect — `InputRegistering` gained
    `unregister`, a pre-1.0 protocol addition), which is what lets `--watch`
    reprint the refreshed listing after each change.
  - [x] `Input` seam grew `audio()` (default: finished stream) with
    `CapturedAudio` beside `CapturedFrame`; `InputKind.generator` added; selector
    resolution (`resolveInput(selector:ofKind:)`, ID → index → unique name
    substring) and canonical listing order live in `InputRegistry`.
  - [x] `stream --dry-run`: full CLI.md option surface parsed and validated
    (`--record` excluded — it arrives at step 5), selectors resolved against the
    registry, plan reported (human table on stdout; a `stream.plan` event line
    under `--json`), stable error identifiers + exit codes on failure. `stream`
    without `--dry-run` is a usage error until step 3.
  - [x] `devices --watch` per the CLI.md spec, including the single-line listing
    document under `--json` and `--type` filtering of device events (a
    `ConsoleSink` refinement, no bespoke output path). Ctrl-C/SIGTERM via a
    self-pipe (`TerminationSignal`), exit 0. `--log-file`'s `FileSink` also
    landed (console-human lines, appended).

- [x] **Step 3** — streaming: simulator harness (SIMULATOR.md), HaishinKit
  behind `StreamingService` *(code complete 2026-07-05; packaging/notarization
  and the versioning scheme remain under "Release mechanics" before v1 is
  shippable)*.
  - [x] HaishinKit seam spike de-risked first (see "De-risking" below for the
    findings the implementation builds on).
  - [x] `apps/ingest-simulator` per SIMULATOR.md: pinned MediaMTX v1.19.2
    (`sim.sh start|stop|status|verify`, download cached under gitignored
    `.bin/`), key-validating paths in `mediamtx.yml`, fake committed keys in
    `keys.env`, RTSP readback for `verify`.
  - [x] The output registration seam and the pre-composition program tick
    decided and recorded (see "Decisions to settle").
  - [x] `packages/TingraOutputPlugIns`: `HaishinKitOutputPlugIn` →
    `RTMPStreamingServiceProvider` (schemes `rtmp`/`rtmps`) →
    `HaishinKitStreamingService` — the only package importing HaishinKit. Video
    appended as uncompressed `CMSampleBuffer`s, audio converted to
    `AVAudioPCMBuffer` + `AVAudioTime` per the spike findings; HaishinKit's
    Logboard console logging rerouted to OSLog so `--json` stdout stays pure
    NDJSON. The seam grew `StreamingServiceProvider`, `OutputRegistering`,
    `StreamConfiguration`, `StreamingServiceEvent`, `StreamingStatistics`,
    `StreamingServiceError`, and `PlugInContext.outputs`; the host grew
    `OutputRegistry`, `ProgramPacer`, and `StreamSession`.
  - [x] `tingra-cli stream` live: connect + publish, tick-paced video /
    pass-through audio on the shared `T0` timeline, `--reconnect`/`--reconnect-delay`
    with the 10-second stability window (a reconnect only counts as recovered
    after surviving it — what turns the bad-key connect-drop loop into exit 75),
    Ctrl-C/SIGTERM clean stop, `--duration`, and the
    `stream.started`/`stream.stats`/`stream.reconnecting`/`stream.reconnected`/`stream.stopped`
    event set (documented in CLI.md "Status events"). Keys via
    `--key`/`--key-env`/`--key-stdin`, read only at connect time, never in any
    output.
  - [x] `tingra-cli probe`: handshake + publish + a short close-watch window,
    then disconnect; no media ever sent (CLI.md notes the enforcement-strength
    caveat).
  - [x] Tests: 205 unit tests across the seven build targets (generators, mocks,
    synthetic/manual clocks — no hardware, no TCC, no live services);
    `scripts/integration-test.sh` runs the SIMULATOR.md scenarios against the
    local simulator (all passing 2026-07-05); `TingraOutputPlugIns` added to the
    ci.yml matrix and the `integration.yml` workflow added (see "CI follow-ups").

- [x] **Step 4** — MCP server: `serve` daemon + `mcp` proxy (MCP.md) *(code
  complete 2026-07-05; the launchd socket-activated LaunchAgent —
  `serve --install/--uninstall`, label `com.moonwink.tingra.serve` — is a
  recorded follow-up under "Release mechanics"; manual mode ships now)*.
  - [x] **Dependency decided:** hand-rolled JSON-RPC/MCP layer, not the official
    swift-sdk (see "Decisions to settle" above; recorded in MCP.md and
    CLAUDE.md).
  - [x] `packages/TingraMCP`: the MCP/Control service. The tool seam (`Tool`,
    `ToolError`, `ToolRegistering`, `JSONValue`, `IdentifiedError`) landed in
    `TingraPlugInKit`; the host grew `ToolRegistry` and `StatusSink`;
    `PlugInContext` gained `tools`. The package holds the JSON-RPC 2.0 layer,
    the newline-framed message transport (in-memory + fd-backed), `MCPSession`,
    the `Daemon` (accept loop, `LOCAL_PEERCRED` peer-uid check, idle-exit that
    never fires mid-stream), `StreamCoordinator` (the one active stream, reusing
    `StreamSession`), the `ByteProxy`/`StdioSocketProxy`, and
    `ControlToolsPlugIn` (the five first-party tools).
  - [x] `tingra-cli serve` (manual mode: creates its own socket at
    `~/Library/Application Support/Tingra/tingra.sock`, dir `0700`) and
    `tingra-cli mcp` (the transparent proxy). Both wired into the root command.
  - [x] Tools mirror the CLI surface (`devices_list`, `probe`, `stream_start`,
    `stream_status`, `stream_stop`), plug-in contributed through the tool
    registry; tool errors key off the `ErrorIdentifier` registry; one active
    stream, a conflicting `stream_start` names the active session; status changes
    broadcast as `notifications/message` fed by the status sink (no polling).
  - [x] Tests: 44 unit tests in `TingraMCPTests` (JSON-RPC codec, `MCPSession`
    flow over the in-memory transport, tool-registry dispatch, `stream_start`
    parsing, the coordinator with mocks, the `ByteProxy` over a socket pair, and
    a real-socket daemon round trip) plus `ToolRegistry`/`StatusSink` tests in
    the host; `scripts/integration-test.sh` gained an MCP scenario (serve + a
    socket client streaming generators to the simulator, verified server side,
    clean shutdown, key redaction — all passing 2026-07-05). `TingraMCP` added
    to the ci.yml matrix and integration.yml paths.

- [x] **Step 5** — local recording (`--record`) *(code complete 2026-07-05)*.
  - [x] The recording seam shape decided and recorded (see "Decisions to settle"
    — a narrower `RecordingService`/`RecordingServiceProvider` pair through the
    same `OutputRegistering` seam, not a "file"-scheme `StreamingServiceProvider`).
  - [x] `packages/TingraRecordingPlugIns`: `RecordingPlugIn` →
    `AVAssetWriterRecordingServiceProvider` (extensions `mov`/`mp4`) →
    `AVAssetWriterRecordingService`, over a `RecordingWriterBackend` seam (real
    `AVAssetWriterBackend`; a mock for lifecycle unit tests). AVFoundation
    imported only here; no HaishinKit, no Logboard. New package so
    `TingraOutputPlugIns` stays the sole HaishinKit importer.
  - [x] Seam types in `TingraPlugInKit`: `RecordingService`,
    `RecordingServiceProvider`, `RecordingServiceEvent` (`failed`),
    `RecordingServiceError` (`IdentifiedError`), `RecordingFile`;
    `OutputRegistering` gained a second `register` overload (a pre-1.0 addition,
    like `InputRegistering.unregister`); `StreamConfiguration` gained
    `includesVideo`/`includesAudio` (track topology the writer needs up front);
    `ErrorIdentifier.recordingFailed` (exit 70, append-only registry + pin test).
  - [x] Host: `OutputRegistry` holds recording providers keyed by extension
    (`recordingProvider(forFileExtension:)`, `duplicateFileExtension`);
    `StreamSession` drives the recording sink from the same rebased program
    media as the stream — opened before connecting, pumped to both sinks,
    finalized on every teardown path (stop, duration, connectionLost), a write
    failure reported as `recordingFailed` without ending the stream.
  - [x] `tingra-cli stream --record <path>`: extension validated at parse (exit
    64), resolved against the output registry, reported in the dry-run plan;
    `recording.started`/`recording.stopped` events and the `recordingFailed`
    error path.
  - [x] MCP recording control **deferred** (see "Decisions to settle"); CLI-only
    for now.
  - [x] Tests: 11 in `TingraRecordingPlugInsTests` (service lifecycle over the
    mock backend, provider/plug-in registration — no disk), recording tests
    added to `TingraHostTests` (`StreamSession` recording + `OutputRegistry`
    recording), CLI `--record` validation/plan tests; `scripts/integration-test.sh`
    gained a recording scenario (record generators to a temp `.mp4`, verified
    with `ffprobe` for H.264+AAC and ~duration). `TingraRecordingPlugIns` added
    to the ci.yml matrix and the integration.yml paths.

- [x] **Step 6** — Metal composition + preview: a camera input + a display
  input composited to an on-screen `MTKView`; phase-3 app scaffolding begins
  *(code complete 2026-07-06)*.
  - [x] Display capture behind the `Input` seam: `InputKind.display` (a pre-1.0
    additive case) and `ScreenCaptureKitCapturePlugIn` → `DisplayInput` in
    `TingraCapturePlugIns` — discovery via CoreGraphics (no Screen Recording
    prompt, stable `CGDisplayCreateUUIDFromDisplayID` identifiers that survive
    reconnection), capture via `SCStream` (32BGRA IOSurface, BT.709-tagged at
    the seam, host-time PTS, idle frames skipped). ScreenCaptureKit imported
    only here; the capture machinery is task-confined (no new `@unchecked
    Sendable`), the injected authorization seam keeps the denied path testable
    without TCC.
  - [x] `packages/TingraComposition`: the tick-paced `Compositor` (a latest-wins
    slot per input, renders the current `Shot`'s layer tree each program tick),
    `Shot`/`Layer`/`ProgramFormat`/`BackgroundColor`, and the `ShotRenderer`
    seam with a Metal-backed `CoreImageShotRenderer` default. The step-6
    realization of the model `ProgramPacer` stood in for — same tick, slots, and
    timestamps, "take the latest frame" replaced by "render the layer tree"
    (CLOCK.md). A host-side engine library (depends only on `TingraPlugInKit` +
    `TingraEventBus`, never the host), so it stays testable with a synthetic
    clock and a mock renderer; the software-`CIContext` pixel tests verify
    compositing, the top-left→bottom-left Y-flip, opacity, and BT.709 tagging
    with no GPU.
  - [x] `apps/tingra` scaffolded (phase 3): a SwiftUI `@main` app, an
    `@Observable @MainActor` `EngineModel` that boots the host and activates
    the same capture/generator plug-ins through the same `PlugInContext` the CLI
    uses, camera and display pickers, and a Core Image `MTKView` program preview
    sampling the program at display rate (never driving the tick). `Localizable.xcstrings`
    with `de`/`es`. Bundling into a signed/notarized `.app` (embedded Info.plist,
    TCC usage descriptions) is deferred packaging, tracked alongside the CLI's
    distribution recipe.
  - [x] Tests: display plug-in registration + the authorization-denied path
    (`TingraCapturePlugInsTests`, now 34), the compositor's pacing/stall/shot-switch/latest-wins
    semantics + the Core Image renderer's pixel output (`TingraCompositionTests`,
    16), and the app's `ProgramLayout` arrangement (`TingraTests`, 4).
    `TingraComposition` and `tingra` added to the ci.yml matrix.

- [x] **Step 9 — buses and monitoring** *(complete 2026-07-27)*. The
  production surfaces the monitoring ruling sequenced after step 8
  (ARCHITECTURE.md, "Roadmap sequencing" step 9), in the three iterations that
  slice was deliberately cut into. Each was **decided and recorded before any
  code** under the effect seam's decide-then-build rule; the full records are
  in ARCHITECTURE.md and in "Decisions to settle" below.
  - [x] **The preview bus** *(code complete 2026-07-26)* — the engine's second
    video bus: a second `ShotRenderer` pass over the same tick's snapshot
    behind `Compositor.previewFrames()`, with `setPreview(shotID:)` staging
    and `takePreview(transition:)` promoting as a **swap**, and the app's
    preview monitor, second switcher row, and Take button.
    `ProgramPreviewView` became `MonitorView`. See "The preview bus".
  - [x] **The monitor path** *(code complete 2026-07-27)* — the slice's larger
    half and the engine's **first audio output path**: the `AudioMonitor` seam
    and its `AVAudioEngineMonitor` default in `TingraAudio`, a sink on the
    app's program-audio tee rather than a second bus, plus **post-fader stereo
    master metering** on the existing `MeterBlock` and the app's master strip.
    Renamed in the deciding — this is *monitoring*, not the "audio preview"
    the docs had called it since 2026-07-19, because preview names the staging
    bus and Tingra's audio is per-preset, not shot-scoped. GLOSSARY.md gained
    **Monitor** and **Master**. See "The monitor path".
  - [x] **Multiview** *(code complete 2026-07-27)* — the last iteration, and
    **the only one that added no bus**: a monitoring window tiling program,
    preview, and every running input, with a **tally** lamp per tile. The
    engine surface is two read-only `Compositor` accessors —
    `latestFrame(forInput:)`, which a tile *pulls* at display cadence from the
    latest-wins slot the compositor already holds, and `programInputIDs`,
    which unions the outgoing shot's inputs mid-transition so a tally cannot
    lie about what is on air. The frame-ownership rule gained **clause 4**
    (read-only sharing for monitoring, never for delivery) to sanction the
    share, and `MonitorView` generalized over a `MonitorFrameSource` so both
    windows share one draw path. Tiles are deliberately **inert**. GLOSSARY.md
    gained **Tally**. See "Multiview".

  **718 tests across 13 targets**, warning-clean, `check-format` clean.
  Nothing in the slice touched the streamed path, `TingraPlugInKit`, or the
  document format — **no version bump** across all three iterations (the
  pre-release rule), and the plug-in stability contract is no closer to a
  breaking edit than it was when step 8 closed.

- [ ] **Steps 7–8** — app era: production features (presets, shots, layers,
  transitions, audio mixer) *(step 7 complete 2026-07-20)*, SRT/multiple
  destinations/WHIP-WHEP *(step 8: **both decided deliverables landed** — SRT
  2026-07-24, multiple destinations 2026-07-26; **WHIP/WHEP remains**, and is
  deliberately ungated by a date — ARCHITECTURE.md sequences it "as support
  matures", i.e. when `RTCHaishinKit` leaves alpha. Nothing else in step 8 is
  outstanding, so the next production iteration is a scoping call, not a
  queued item)*.
  - [x] **Step 8, SRT output** *(code complete 2026-07-24)* — the first
    step-8 iteration: SRT delivery behind the same `StreamingService`/
    `StreamingServiceProvider` seam as RTMP, as a contained provider
    addition. See the detailed record below.
  - [x] **Step 8, multiple destinations** *(design decided 2026-07-24, veto
    cleared and code complete 2026-07-26)* — one program fanned out to N
    destination legs inside `StreamSession` (not N sessions), per-leg
    reconnect, best-effort start, per-leg status events, a repeatable CLI
    `--url`, `Project.destinations: [ProjectDestination]?` folding in the
    single `destination` (no version bump), and secure-storage keying by
    destination id. See the detailed record below.
  - [x] **Step 7 exit criteria — met 2026-07-20** *(drawn 2026-07-19)* — the
    iterations that must land before step 8 opens, collected from the
    deferrals the fourteen records above carried. When this sub-list is
    empty, step 7 is done; nothing joins it silently — widening the list is
    itself a recorded decision. Checked against the roadmap definition
    (ARCHITECTURE.md step 7: "presets, shots, layers, transitions, audio
    mixer") and the GLOSSARY.md vocabulary: transitions are complete when
    all four GLOSSARY.md "Transition" kinds exist (custom shader is the
    last), and the audio mixer is complete when every GLOSSARY.md "channel
    strip" slot exists (the audio effect chain is the last).
    - [x] **Custom-shader transitions** *(landed 2026-07-19 — see the
      fifteenth-iteration record below)* — the last GLOSSARY.md transition
      kind, completing the transitions story: a `Transition` case carrying
      a shader choice, rendered through a `ShotRenderer` seam requirement
      beside `renderWipe` on the dissolve's untouched tick-counted timing
      spine (the wipe pattern). **V1 is first-party built-in shaders
      only** — a fixed menu compiled into the app; loading third-party
      shader code is a plug-in-era surface with a security posture to
      record first (user-supplied GPU code is the dual-use boundary), so
      it is *not* step-7 exit criteria.
    - [x] **The effect seam decision** *(decided 2026-07-19, flagged for
      Larry's veto — see "Decisions to settle" and ARCHITECTURE.md, "The
      effect seam"; no code lands until the veto clears)* — effects are
      plug-ins (CLAUDE.md), so the seam lands in `TingraPlugInKit` under
      the plug-in API stability contract (SemVer, the
      default-implementation rule, the diagnose-api-breaking-changes check
      once tags exist) — the one call that had to be made and recorded in
      ARCHITECTURE.md *before any effect code*: **one shared seam, two
      media protocols** (`AudioEffect`/`VideoEffect` under one
      `EffectRegistering`/identity/parameter surface). Never rushed — a
      half-designed stability contract is worse than an unfinished step.
    - [x] **Audio effect chains** *(landed 2026-07-20 — see the sixteenth
      iteration record below)* — the seam built and its first
      conformances shipped, completing the GLOSSARY.md **channel strip**:
      `TingraPlugInKit` gained the whole effect seam (`EffectID`,
      `EffectConfiguration`, `EffectParameter`, `AudioEffect`/`VideoEffect`,
      their providers, `EffectRegistering`, `PlugInContext.effects`), the
      host an `EffectRegistry`, and the new `TingraEffectPlugIns` package
      the audio staples (gain, high-pass, low-pass).
    - [x] **Per-layer video effects** *(landed 2026-07-20 — see the
      seventeenth iteration record below)* — the seam's second iteration
      and step 7's last exit criterion: `Layer.effects` within v1, chain
      application in `CoreImageShotRenderer` through an injected
      `VideoEffectFactory` (fused into the one render pass), the
      first-party color adjustment and blur, and the layer-tree editor's
      chain UI. **With this the sub-list is empty and step 7 is done.**
    - [x] **Monitoring is ruled out of step 7** *(decided 2026-07-19)* —
      the monitoring slice the docs point at from three places (the app's
      "no audio preview yet" drain note, the mixer record's "a future
      monitoring path may keep muted devices running", the meters record's
      "post-fader metering belongs to the master bus, a later monitoring
      slice") is **not** exit criteria: the roadmap defines step 7's audio
      scope as the mixer, the GLOSSARY.md channel strip has no monitoring
      slot (its meter landed), and audio preview / post-fader master
      metering belong to the buses-and-monitoring vocabulary (preview,
      multiview) — an app-era slice sequenced after step 8, alongside the
      video preview bus it parallels. Recorded here so it cannot silently
      expand the bucket.
  - [x] **Step 8, multiple destinations** *(code complete 2026-07-26)* — the
    second step-8 iteration, and the one that makes the engine a real
    multi-service switcher: **one program fanned out to N destination legs
    inside one `StreamSession`**, built after the design's veto cleared (see
    "Decisions to settle" for the approved spec and the two amendments Larry
    settled at the veto — best-effort start, and a CLI surface). Landed in
    three iterations:
    - **Engine.** `StreamSession` gained a public **`DestinationLeg`** (stable
      id + `Destination` + its own `StreamingService`) and an array of them,
      with the single-destination initializers kept as one-leg conveniences so
      the common case reads unchanged. Reconnect state moved to a per-leg
      `LegState` with one connection watcher each, so **one destination
      flapping never spends another's budget** (the crux); a leg whose budget
      runs out is reported and stays dead while the rest stream on, and only
      the last live leg's loss ends the session with `connectionLost`. Start is
      best effort; a start-refused leg never enters the reconnect budget. Media
      pumps snapshot the services once and deliver to every leg in order.
      `StatusSink` grew per-name-**and**-destination retention so one leg's
      stats can never stand in for another's. Three event names added
      (`stream.destination.started`/`.rejected`/`.lost`), `stream.stats` and
      the reconnect events became per-leg with flat additive `destination` +
      `destinationUrl` params (an event param is a scalar — EVENTS.md), and
      `stream.started` gained `destinations`/`destinationsRejected` while `url`
      stays the first live leg's.
    - **CLI + MCP.** `--url` and `--key`/`--key-env` became repeatable, paired
      by position with an unequal count rejected as exit 64 naming both counts;
      `--key-stdin` stays single-destination. `stream.plan` gained a
      `destinations` count plus one `stream.plan.destination` event each.
      `stream_start` takes either `url`/`key` or a `destinations` array (not
      both) and still returns one session id; `stream_status` grew a
      `destinations` array of per-leg counters with its flat fields staying the
      first leg's. `JSONValue` gained `arrayValue` (additive, completing the
      accessor set).
    - **Document, secure storage, and the app.** `Project.destinations:
      [ProjectDestination]?` folds the older single `destination` key in
      **decode-only** (an optional key within v1, the `Preset.audioChannels`
      precedent); `ProjectDestination` grew `ProjectDestinationID`, `name`, and
      `isEnabled`, all optional on decode. Stream keys moved to secure-storage
      accounts keyed by **destination id, not URL** (no migration —
      pre-release). The app's streaming panel became a destination list:
      `DestinationEdit` (the pure, unit-tested state holding the URL as text,
      streamable only with a supported scheme *and* a host, so a half-typed URL
      never reaches the project file and an edited URL keeps its id and its
      key) behind `DestinationListView` (per-row enable, name, URL, secure key,
      live state, remove-and-clear-key; rows lock while streaming). The session
      banner reports trouble only when nothing is left delivering — one leg of
      several reconnecting is that leg's news, on its own row. New strings
      localized `de`/`es`; every button taps first.

    Tests: `TingraHost` grew a `StreamSession fan-out` suite (8 cases: shared
    timeline across legs, per-leg stats identity, partial start rejection,
    every-leg rejection, no destinations, partial leg loss, last-leg loss, and
    **independent budgets**) plus 2 `StatusSink` cases, reaching 90;
    `TingraComposition` 141 (destinations round-trip, the single-key fold-in,
    list-wins, missing-url throw, equality); `tingra-cli` 81; `TingraMCP` 56;
    `apps/tingra` 99 with a new `DestinationEdit` suite — **665 across the 13
    targets**. `integration-test.sh` gained **three scenarios (11 checks)** —
    one program to two RTMP paths with **both read back off the simulator**
    (`live/` plus the already-configured `live2/` path), a partial start
    rejection exiting 0, and per-leg reconnect isolation proving all reconnects
    belong to the failing leg and none to the healthy one — for **11 scenarios
    / 37 checks, all passing**. Warning-clean, format clean.

    Two things the run itself taught, worth keeping: **MediaMTX does not refuse
    a bad RTMP key at connect** — it accepts and closes moments later (the
    accept-then-drop shape the stability window exists for), so a bad key
    exercises the *mid-stream* path and a genuine start rejection needs an
    unreachable port (`rtmp://localhost:59999/live`, as the probe scenario
    already used). And the per-leg isolation scenario confirmed the crux
    against a real server: all three `stream.reconnecting` events carried
    `destination-2`, none carried `destination-1`. Recorded in ARCHITECTURE.md, "Multiple destinations";
    CLI.md, "Destination"/"Status events"/"Exit codes"/"Non-goals";
    MCP.md, "Sessions and concurrency"; README.md.
  - [x] **Step 8, SRT output** *(code complete 2026-07-24)* — the first
    step-8 iteration and the first new streaming transport since v1: SRT
    delivery behind the same `StreamingService`/`StreamingServiceProvider`
    seam as RTMP, contained in `TingraOutputPlugIns` (still the sole
    HaishinKit importer). `HaishinKitOutputPlugIn` now registers a
    **`SRTStreamingServiceProvider`** (scheme `srt`) alongside the RTMP
    provider; **no consumer changed** — `stream`, `probe`, the MCP tools,
    and the app already resolve `srt://` through
    `OutputRegistry.provider(forScheme:)`, which returned nil before this
    (the old `invalidArgument`-naming-step-8 path is retired). The new
    **`SRTHaishinKitStreamingService`** is the `SRTStream`-backed sibling of
    `HaishinKitStreamingService`; buffer conversion and compression-settings
    mapping are transport-neutral and were **extracted to
    `HaishinKitMediaConversion`** (shared by both, not duplicated — the
    RTMP file's only change). Decisions made and recorded (ARCHITECTURE.md,
    "How HaishinKit is incorporated"; CLI.md, "Destination"; and "Decisions
    to settle" below): **(a)** Tingra ships the prebuilt libsrt xcframework
    (retires the "RTMP-only stays fully source" deferral rationale; the
    binary is embedded/signed for notarization); **(b)** `--key` composes
    into the URL's `streamid` (SRT has no publish name) — appended when the
    URL has none, an `invalidArgument` when the URL already carries one, and
    placed **literally** because HaishinKit reads `streamid` by raw split
    with no percent-decoding; **(c)** stats frame rate is counted from video
    appends (SRT exposes no `currentFPS`), bytes from
    `SRTConnection.performanceData`. **Spike result / recorded deferral:**
    HaishinKit 2.x's SRT publish path exposes **no mid-stream
    connection-loss push** (`SRTConnection.connected` flips false only on our
    own `close()`, the ground-truth socket state is private), so the SRT
    service reports start-time failures (thrown → exit 75, `--reconnect`
    still governs start retries) but never yields `connectionLost`, and the
    reconnect machinery does not fire on an SRT mid-stream outage in this
    iteration — SRT's own ARQ retransmission rides out ordinary packet loss
    below this layer, so the gap is only the hard-timeout case; never a poll
    loop (CLAUDE.md). **Simulator fix:** MediaMTX's SRT listener was rebound
    to IPv4 loopback (`srtAddress: 127.0.0.1:8890`) — HaishinKit's
    `SRTSocketURL` builds only an IPv4 `sockaddr_in` and cannot reach an
    IPv6 (`*:8890`) SRT socket the way the TCP listeners accept IPv4-mapped
    connections; recorded in SIMULATOR.md. Tests: `TingraOutputPlugInsTests`
    grew SRT `streamid` composition (append / ambiguous-throw / URL-own /
    keyless / empty-key), streamid detection, rejection-omits-key, and
    expected-media topology cases, plus the plug-in now registers two
    providers (24 in the target); `integration-test.sh` gained a happy-path
    SRT scenario (bars+tone, `--key` composed into `streamid`, verified
    server side) and an SRT bad-key exit-75 scenario. **No document version
    bump** (SRT streams, but persisting SRT destinations is part of the
    multiple-destinations iteration). Decisions recorded in ARCHITECTURE.md,
    "How HaishinKit is incorporated"; CLI.md, "Destination"/"Reconnect
    semantics"; SIMULATOR.md. **Multiple destinations (the rest of step 8)
    landed 2026-07-26** in the iteration above.
  - [x] **Step 7, per-layer video effects** *(code complete 2026-07-20)* —
    the seventeenth production-feature iteration and **the one that closes
    step 7**: the effect seam's second media protocol becomes code,
    landing the "later 'Effect' iteration" deferred since the layer-tree
    editor. With it the step-7 exit checklist above is **empty** and step
    8 (SRT/multiple destinations) opens. `TingraComposition`'s `Layer`
    gained an optional **`effects`** chain — **no version bump** (the
    pre-release rule): absent = no chain, so pre-effects documents decode
    unchanged and a chainless layer authors no key. The pixel work needed
    the providers without letting `TingraComposition` depend on the host's
    registry, so the seam is a new **`VideoEffectFactory`**
    (`@Sendable (EffectConfiguration) -> (any VideoEffect)?`) injected into
    `CoreImageShotRenderer`; the `Compositor` is **untouched** — it already
    takes a renderer factory, so the resolver rides the renderer the app
    was already injecting (the app builds it from a boot-time snapshot of
    `EffectRegistry.allVideoProviders`). The chain runs **before
    placement** (an effect sees the layer's own image at its own scale, so
    a blur radius means the same thing wherever the layer sits) with its
    output **cropped back to the source extent** (a blur bleeds past the
    edges; a layer occupies its frame, never more), composing lazily
    `CIImage`→`CIImage` so a whole chain **fuses into the one render
    pass**. Instances are **cached per layer** (keyed by shot id and layer
    index) and rebuilt only when the configurations change — a live edit
    lands at the next tick, a steady chain never rebuilds — and an entry
    with no resolvable provider is **skipped as pass-through**, never a
    black layer. `TingraEffectPlugIns` gained **color adjustment**
    (`CIColorControls`: brightness/contrast/saturation) and **blur**
    (`CIGaussianBlur`), the first two GLOSSARY.md video effect names, with
    **every parameter neutral at its default** so adding an effect never
    changes the picture until it is adjusted. `apps/tingra`: the
    layer-tree inspector gained `LayerEffectChainView` — the audio chain
    editor's shape one service over (signal-order slots with Move Up /
    Move Down / Remove, an Add Effect menu, generically drawn parameter
    sliders) — with `LayerTreeEdit` gaining the pure chain operations, all
    flowing through the existing `updateShot` path and debounced autosave;
    the **existing layer edits were audited to preserve the chain** (a
    `Layer` rebuild dropping `effects` would have silently discarded the
    operator's work). Every control reports its `tap` first; the chain UI
    reuses the audio iteration's already-localized strings. Decisions
    recorded in ARCHITECTURE.md, "Per-layer video effects"; README gained
    the new types. Tests: `TingraCompositionTests` (now 136 — chain
    applied before placement, signal order, unresolved entry passing
    through, a resolver-less renderer ignoring chains, a chain edit
    rebuilding the cached instances; `Layer` chain round-trip,
    omitted-when-nil, authored-empty, defaults, equality),
    `TingraEffectPlugInsTests` (now 21 — video provider registration and
    identifiers, neutral defaults, brightness lightening, zero saturation
    going grayscale, range clamping, zero-radius identity, a blur
    softening a hard edge, provider payload at creation), and the app's
    `TingraTests` (now 87 — the chain edit operations: neutral append,
    signal-order append, out-of-range no-ops, removal leaving
    authored-empty, reorder with clamping, parameter set preserving the
    rest, and frame/opacity/rebind all preserving the chain).
  - [x] **Step 7, audio effect chains** *(code complete 2026-07-20)* — the
    sixteenth production-feature iteration, turning the recorded effect
    seam into code and landing the **last slot of the GLOSSARY.md channel
    strip**: the per-strip **audio effect chain**, closing the deferral
    every mixer record has carried since the mixer itself (per-layer video
    effects — the seam's second iteration — are now step 7's one remaining
    exit criterion; SRT/multiple destinations remain step 8).
    `TingraPlugInKit` gained the seam exactly as recorded — `EffectID`,
    `EffectConfiguration` (the persisted `{effect, parameters}` shape),
    `AudioEffect`/`VideoEffect`, `AudioEffectProvider`/`VideoEffectProvider`,
    `EffectRegistering`, plus `PlugInContext.effects` (a pre-1.0 addition
    like `OutputRegistering`'s recording overload) and a forgiving
    `JSONValue.doubleValue` — with **one addition the build surfaced:
    `EffectParameter`**, the descriptor (key, name, range, default, unit,
    linear/logarithmic scale) a provider declares so **a third-party
    effect gets parameter UI for free** instead of needing bespoke app
    code, the exact coupling the seam exists to prevent. `TingraHost`
    gained `EffectRegistry` (one registry, **separate tables per media
    kind** — one provider per id within a kind — in registration order for
    stable menus). The chain sits **post-intake, pre-fader**:
    `AudioMixer` processes each strip's consumed samples through its chain
    before level, pan, and mute, so the meter — unchanged in wording —
    now reads the chain's **output** (the console's insert-metering point:
    an effect's gain shows on the meter, a fader ride still does not), and
    a strip with no chain mixes byte-for-byte as before (the pan record's
    proof rule). Two entry points split by gesture rate:
    `setEffects(_:forInput:)` replaces instances (structural edits),
    `setEffectParameters(_:forEffectAt:forInput:)` retunes a slot **in
    place** so a dragging slider never resets filter memory into a click;
    both report **no events** (the `updateShot` rule), and an effect that
    breaks the block-shape contract is **clamped, never trapped**.
    `TingraComposition`'s `AudioChannel` gained an optional **`effects`**
    chain — **no version bump** (the pre-release rule): absent = no chain,
    so pre-effects documents decode unchanged and a chainless strip
    authors no key; an entry naming an effect this build has no provider
    for round-trips untouched and instantiates as a **pass-through
    holding its slot** (one `effect.resolve` error), the
    layer-bound-to-an-undiscovered-input semantic one service over. New
    package `packages/TingraEffectPlugIns` (protocol-seam dependencies
    only, added to the ci.yml matrix): `EffectPlugIn` registering
    **gain, high-pass, and low-pass** over a shared `BiquadFilter`
    (audio-EQ-cookbook coefficients at Butterworth Q; per-channel memory
    kept across a cutoff sweep). `apps/tingra`: a per-strip **Effects
    button** badged with the chain's length opening `EffectChainView` —
    slots in signal order with Move Up / Move Down / Remove, an Add Effect
    menu over the registry, and **sliders drawn generically from the
    declared parameters**; structural edits re-instantiate the chain,
    parameter drags take the in-place path, both autosaved debounced;
    every control reports its `tap` first; new strings localized
    `de`/`es`. Decisions recorded in ARCHITECTURE.md, "Audio effect
    chains"; GLOSSARY.md's Effect entry now covers both media and gained
    **Effect chain**; README gained the package and every new public type.
    Tests: `TingraPlugInKitTests` (now 26 — configuration round-trip,
    stable keys, missing-id throws, forgiving parameters, unknown-effect
    survival, equality, `doubleValue`), `TingraHostTests` (now 80 —
    registry resolution, duplicate-id rejection per kind, shared ids
    across kinds, listing order), `TingraAudioTests` (now 31 — chain
    before fader, signal order, in-place retune with stale-gesture
    ignores, post-chain metering, chain kept across a reconfigure,
    shape-breaking effect clamped, chainless strip untouched),
    `TingraEffectPlugInsTests` (13 — registration order and identifiers,
    declared parameters, gain unity/+6 dB/clamping/integer payload,
    high-pass DC removal and passband, low-pass DC passband and stopband,
    per-channel memory, cutoff clamping, provider payload at creation),
    `TingraCompositionTests` (now 127 — chain round-trip in signal order,
    omitted-when-nil, authored-empty distinct, equality), and the app's
    `TingraTests` (now 76 — chainless strip authors no key, chain
    conversion, merge adopting an authored chain, appended strips
    chainless, chain equality).
  - [x] **Step 7, custom-shader transitions** *(code complete 2026-07-19)* —
    the fifteenth production-feature iteration, landing the fourth and last
    GLOSSARY.md **transition** kind — **shader**, a custom Metal-shader
    reveal — and with it the repo's first hand-written Metal, arriving
    exactly where the renderer decision sequenced it (the effect subsystem
    is now step 7's one remaining exit criterion; SRT/multiple
    destinations — step 8 — remain). `TingraComposition`'s `Transition`
    gained **`.shader(name:duration:)`** over a new **`TransitionShader`**
    menu (`iris`/`diagonal`/`blinds` — the shapes the wipe record deferred
    as "diagonals, irises, and patterns"), on the project/scripting
    contract: stable `kind: "shader"` + `shader` + `durationSeconds` keys,
    forgiving decode (iris, half-second default), an **unknown shader name
    throws** (a document must not silently take with a different look), no
    version bump. The kernels are **stitchable Metal, runtime-compiled from
    compiled-in first-party source** (`CIKernel.kernels(withMetalString:)`,
    inside the macOS 15 floor; no SPM metallib machinery) behind a new
    per-kind `ShotRenderer.renderShader` requirement — no default
    implementation, the wipe's reasoning — sharing the wipe's feathered
    sweep rule (exact endpoints) and the operator's top-left screen terms
    (the Y-flip); the dissolve's tick-counted `PendingTransition` spine is
    untouched, and a kernel that cannot compile or apply **degrades to the
    incoming shot** (a visible cut — never a crash, never a frozen
    program). **Security posture recorded**: v1 runs first-party shader
    source only — no path reads shader code from documents, files, or user
    input; a third-party shader seam is deferred plug-in-era work whose
    validation/isolation posture must be recorded before any loader lands.
    `apps/tingra`: the switcher picker gained a **Shader** segment with a
    shader pop-up (the wipe's Edge pattern; `shaderName.picker` `tap`), the
    Default Transition submenu the three shaders (`shader` param on its
    `tap`), and `program.take` keeps reporting the kind alone (`"shader"`);
    new strings localized `de`/`es` (Jalousie/Persiana). Decisions recorded
    in ARCHITECTURE.md, "Custom-shader transitions"; GLOSSARY.md's
    Transition entry now names all four kinds and the shader menu; README
    gained `TransitionShader`. Tests: `TingraCompositionTests` (now 123 —
    shader `Transition` round-trip/stable-keys/forgiving-decode/
    unknown-name-throws/equality, the compositor's shader-take progress
    ramp over the mock renderer, and per-shader software-`CIContext` pixel
    tests: exact endpoints doubling as compile checks, iris center-vs-corner,
    diagonal top-left origin, blinds parallel bands, BT.709 tag + tick-time
    stamp) and the app's `TingraTests` (now 71 — a shader default
    transition stored at the default duration).
  - [x] **Step 7, per-strip routing: the persisted mix** *(code complete
    2026-07-19)* — the fourteenth production-feature iteration, landing the
    **routing** slot of the GLOSSARY.md **channel strip** and, with it, the
    debt three records carried: strip settings (level, pan, mute) finally
    **persist** into the preset (audio effect chains remain, as do
    custom-shader transitions and SRT/multiple destinations — step 8).
    **Routing v1: the program mix is the only bus**, so a channel's routing
    *is* its membership in the preset's authored channel list — no new
    engine surface (`AudioMixer`/`ChannelStrip` unchanged; sends and further
    buses are later). `TingraComposition` gained `AudioChannel` (one
    authored channel: the device-UID-stable `input`, a cached display
    `name`, `level`, `pan`, `isMuted` — stable camelCase keys, `input`
    required, the rest decoding forgivingly to strip defaults) and `Preset`
    an optional `audioChannels: [AudioChannel]?` — encodeIfPresent, **no
    version bump** (the pre-release rule): nil = no authored audio, so
    pre-routing documents decode unchanged; per-preset because a preset's
    audio configuration is the console's scene snapshot (GLOSSARY.md's
    "Preset" promise, kept). `apps/tingra`: `MixerStrip.strips(channels:discovered:)`
    merges authored channels (document order — panel order is array order)
    with discovery — a channel whose device is absent stays a **dormant
    strip** (cached name, `mic.slash` "Not connected" marker, settings kept
    for the device's return — the layer-bound-to-an-undiscovered-input
    semantic), a discovered device the preset never authored appends
    **muted** at unity center (never surprise-live), and `MixerStrip.seed`
    (first mic unmuted) stays the nil fallback; strip edits schedule the
    debounced autosave (drags coalesce — the `updateShot` rule, no engine
    events), `syncActivePreset()` writes the session strips into the active
    preset before every save/switch/duplicate (the first save authors a
    pre-routing document by use), and a preset switch/active-preset removal
    adopts the incoming preset's authored audio from the next mix tick — a
    control change, never an interruption — or carries the session mix when
    it has none (the old behavior as the fallback). "Not connected"
    localized `de`/`es`. Decisions recorded in ARCHITECTURE.md, "Per-strip
    routing"; GLOSSARY.md gained the **Routing** entry. Tests:
    `TingraCompositionTests` (now 110 — `AudioChannel` round-trip, stable
    keys, missing-`input` throws, forgiving defaults, equality; `Preset`
    audioChannels round-trip, absent-key nil, omitted-when-nil,
    authored-empty distinct) and the app's `TingraTests` (now 70 — merge
    policy: settings kept + name refreshed, dormant strips, raw-id
    fallback, muted appends, ordering, authored-empty, seed fallback,
    strip→channel conversion; `PresetEdit` carrying audio through
    duplicate/rename).
  - [x] **Step 7, per-strip meters** *(code complete 2026-07-18)* — the
    thirteenth production-feature iteration, landing the monitoring half of
    the GLOSSARY.md **channel strip**: a **meter** per strip (routing and
    audio effect chains — routing being the iteration that persists strip
    settings into the preset — remain, as do custom-shader transitions and
    SRT/multiple destinations — step 8). `TingraAudio` gained `MeterReading`
    (one strip's per-block peak and RMS, linear, `floor` for silence) and
    `MeterBlock` (every live strip's reading keyed by input id, stamped with
    the tick's master-clock time), and `AudioMixer` a `meterReadings()`
    stream — one block per mix tick under `programAudio()`'s single-consumer
    replace-on-recall contract, measured as a byproduct of the walk the tick
    already makes (never a second pass, only while a consumer is attached —
    the streamed program path is byte-for-byte unchanged) and **never the
    event bus** (per-block data; EVENTS.md's control-plane rule). Metering
    is **pre-fader** — after intake normalization, before level/pan/mute —
    so the meter answers "what is this input delivering", holds steady under
    fader rides, and composes with a future monitoring path (engine-side, a
    muted strip still meters; in the app it rests at the floor because
    mute stops the device — app policy, not meter semantics). `apps/tingra`
    gained `StripMeter` (a compact capsule between each strip's name and
    level slider: RMS bar over broadcast green/yellow/red zones — −60…0 dBFS
    scale, green through −20, yellow through −6 — with a decayed peak
    marker) drawn in a `TimelineView(.animation)` off a shared `MeterRelay`
    the model's meter drain fills (the `ProgramFrameRelay` pattern — no
    observation-driven churn; `Gauge` rejected as unable to express zones,
    a peak marker, and draw-time ballistics), with `MeterBallistics`
    applying instant attack and a 20 dB/s decay at draw time (ballistics
    are presentation — engine readings stay raw block truth). Display only:
    no persisted state, no `tap`s, no new engine events
    (`mixer.started`/`mixer.stopped` stay the only lifecycle events); the
    new "Meter" string localized `de`/`es`. Decisions recorded in
    ARCHITECTURE.md, "Per-strip meters". Tests: `TingraAudioTests` (now
    24 — known samples to known peak/RMS, peak vs RMS distinctness,
    pre-fader metering on a muted zero-level strip, stereo hotter-channel,
    floor readings stamped with tick times, stop finishing the meter
    stream) and the app's `TingraTests` (now 62 — instant attack, 20 dB/s
    decay over elapsed time, louder-reading override, floor rest and clamp).
  - [x] **Step 7, per-strip pan** *(code complete 2026-07-18)* — the twelfth
    production-feature iteration, landing the next slot of the GLOSSARY.md
    **channel strip** after level and mute: **pan**, placing each strip in the
    stereo program mix (routing, audio effect chains, and monitoring/meters
    are later iterations; custom-shader transitions and SRT/multiple
    destinations — step 8 — also remain). `TingraAudio`'s `ChannelStrip`
    gained `pan: Double` (−1 hard left, 0 center — the default — 1 hard
    right, clamped at the mix) and `AudioMixer` a `setPan(_:forInput:)`
    mirroring `setLevel` — gesture-rate, no engine events (the `updateShot`
    rule). The pan law is **equal-power (sine/cosine), normalized to unity at
    center**: a centered strip mixes byte-for-byte as before pan existed (the
    pre-pan mixer tests stay green unchanged as the proof), a hard-panned
    strip carries the law's +3 dB on its remaining channel inside the float
    sum's recorded headroom posture, and one law serves both intake shapes —
    a mono strip pans at constant power, a stereo strip balances (channels
    scaled, never folded; implemented in the symmetric sine form so a hard
    pan's silent channel is exact silence). Pan **stays session state** — the
    strip list is still derived from discovery, so pan joins levels and mutes
    in the persisted preset when routing lands (an optional key within v1
    under the pre-release rule, never a bump). `apps/tingra`'s `MixerStrip`
    gained `pan` (seeded centered) and `EngineModel` a
    `setStripPan(_:forStrip:)` (no reconfigure pass — pan never touches
    device lifecycle); `MixerView` grew a compact per-strip pan slider with
    broadcast `L`/`R` value labels and double-click recentering (the macOS
    slider-reset convention), reporting the drag-end `mixerPan.slider` `tap`
    and the discrete `mixerPan.reset` `tap`; new strings localized `de`/`es`.
    Decisions recorded in ARCHITECTURE.md, "Per-strip pan". Tests:
    `TingraAudioTests` (now 18 — mono hard-left/hard-right, center preserving
    the pre-pan spread exactly, stereo balance never folding, `setPan`
    application, beyond-range clamping) and the app's `TingraTests` (still
    57 — seeding centered, pan inequality).
  - [x] **Step 7, per-shot default transitions** *(code complete 2026-07-18)* —
    the eleventh production-feature iteration, landing the deferral recorded
    since the shot-management iteration: a shot carries the transition it is
    taken with, set once instead of re-picked per take (custom-shader
    transitions and SRT/multiple destinations — step 8 — remain).
    `TingraComposition`'s `Shot` gained an optional **`defaultTransition:
    Transition?`** — per-shot, not per-preset (the preference is about
    *arriving at a shot*: a title dissolves in while the interview beside it
    cuts) — on the project/scripting contract: stable camelCase
    `defaultTransition` key, encoded only when set, absent = no default =
    today's cut. **New standing rule (Larry, 2026-07-18): pre-release the
    document format stays version 1** — nothing has shipped, so there are no
    documents in the field to migrate; the interim v1→v2 `destination` bump is
    retired (`Project.currentVersion` returns to 1, the destination and the
    default simply part of v1), the version-key + decode-newer-throws
    machinery stays armed, and version 2 happens the first time the format
    changes after the first release. A stale dev file written under the
    interim numbering decode-throws and is set aside/reseeded (accepted,
    dev-only). The engine surface is otherwise
    untouched: **resolution happens in `EngineModel`**, not the compositor —
    `take(shotID:transition:)` keeps its caller-states-the-transition
    contract, the app resolves the taken shot's `defaultTransition ?? .cut`
    while the switcher's picker is on **Default** (a new leading segment and
    the initial selection; Cut/Dissolve/Wipe are explicit overrides), and
    `program.take` keeps reporting the resolved kind. The default is set from
    a **Default Transition submenu** in the shot's context menu (a
    checkmarked radio group: No Default, Cut, Dissolve, a wipe per edge — all
    at the default durations), a document edit on the rename's line: through
    `Compositor.updateShot(_:)`, debounced autosave, `tap`-event
    observability only (`shotDefaultTransition.menu`); new strings localized
    `de`/`es`. Decisions recorded in ARCHITECTURE.md, "Per-shot default
    transitions". Tests: `TingraCompositionTests` (now 100 — the
    `defaultTransition` round-trip per kind, stable key, omitted-when-nil,
    missing-key, and unknown-kind decoding cases, Shot equality, and the
    document-level missing-key + full round-trip cases) and the app's
    `TingraTests` (now 57 — `ShotEdit.settingDefaultTransition`
    set/clear/no-op, duplicate/rename preservation, and the layer-tree edits'
    preservation of the field).
  - [x] **Step 7, wipe transitions** *(code complete 2026-07-18)* — the tenth
    production-feature iteration, completing the transitions story cut and
    dissolve opened 2026-07-08: the third transition kind, a **directional
    reveal** of the incoming shot from a frame edge (custom-shader transitions
    and SRT/multiple destinations — step 8 — remain). `TingraComposition`'s
    `Transition` gained `.wipe(edge:duration:)` with a four-edge **`WipeEdge`**
    (`left`/`right`/`top`/`bottom`, the operator's top-left-origin screen
    terms) — an **additive** change to the project/scripting contract: stable
    camelCase `kind`/`edge`/`durationSeconds` keys, both non-kind keys optional
    on decode (left edge, half-second default — the dissolve's forgiving-decode
    rule), `cut`/`dissolve` encoding unchanged. The tick-counted transition
    spine is untouched — the compositor's `PendingTransition` gained only a
    kind — and the pixel work landed as a per-kind
    `ShotRenderer.renderWipe(from:to:edge:progress:frames:format:time:)`
    beside `renderDissolve` (deliberately not a generalized
    `renderTransition(kind:)`, and deliberately **no default implementation** —
    a silent dissolve fallback would mask a conformer missing the new kind);
    `CoreImageShotRenderer` implements it **soft-edged** — a `CILinearGradient`
    mask driving `CIBlendWithMask`, feather fixed at 5% of the sweep span,
    endpoints exact (the blend band starts fully off-frame and finishes fully
    past the far edge), the same IOSurface-backed 32BGRA BT.709-tagged output
    tail. `program.take`'s `transition` param extends with `"wipe"`.
    `apps/tingra`'s switcher replaced the boolean Dissolve checkbox with a
    segmented **Transition picker** (Cut ∣ Dissolve ∣ Wipe — visible,
    one-click state for a live switcher, per the HIG) plus an **Edge pop-up**
    shown only while Wipe is selected; both per-take session state (no
    document version bump, format stays v2), both reporting their `tap`
    (`transition.picker`/`wipeEdge.picker`) in `onChange`; new strings
    localized `de`/`es` (Wischblende/Cortinilla). Decisions recorded in
    ARCHITECTURE.md, "Wipe transitions". Tests: `TingraCompositionTests` (now
    93 — `Transition` wipe round-trip/keys/defaults/unknown-edge decoding, the
    repointed unknown-kind case, wipe progress ramping and zero-duration
    completion through the wipe path with its edge, and the renderer's wipe
    pixel output at progress 0/0.5/1 including the top-edge Y-flip and the
    BT.709-tagged, tick-stamped output frame).
  - [x] **Step 7, shot and preset reordering** *(code complete 2026-07-14)* —
    the ninth production-feature iteration, completing the shot-management
    story: the operator changes the switcher order of the active preset's shots
    and — the same operation one level up — of the project's presets
    (wipe/custom-shader transitions and SRT/multiple destinations — step 8 —
    remain). **No document version bump** (the format stays v2): switcher order
    *is* the persisted array order (`Preset`'s shots, `Project`'s presets), so
    `Project`/`Preset`/`Shot` are unchanged. The engine surface is
    `Compositor.moveShot(shotID:to:)` — a granular pool reorder beside
    `addShot(_:at:)`/`removeShot(shotID:)`, not a reload path: it reorders
    `state.shots` and touches nothing else, so **reordering is not taking — the
    program never changes** (`activeShotID`, the rendered shot, and any
    in-progress dissolve all survive by construction); the destination index is
    clamped (matching `addShot`'s index-based insertion), an unknown id is a
    recoverable `shot.move` error, and an actual move reports a discrete
    `shot.moved` event (the `shot.added`/`shot.removed` reasoning — a menu
    command is not gesture-rate). `apps/tingra` added **Move Left / Move Right**
    context-menu commands to the shot switcher (and the preset switcher),
    disabled at the ends — mirroring the layer editor's Move Up / Move Down
    rotated to the horizontal axis; context menu, **not drag-and-drop**, so the
    shot buttons' single click stays reserved for the live on-air take. Preset
    reordering rides `EngineModel.movePreset(_:to:)` — pure document-state array
    move, **no `Compositor` surface, no reconfigure** — reporting `preset.moved`;
    order is meaningful because the app adopts the first preset at launch (front
    = next session's default). Every new command reports its `tap` first; new
    `Move Left`/`Move Right` strings localized `de`/`es` (shared keys across the
    shot and preset menus, the "this shot or preset" comment convention).
    Decisions recorded in ARCHITECTURE.md, "Shot and preset reordering". Tests:
    `TingraCompositionTests` (now 80 — `moveShot` reorder-without-taking with
    the on-program shot, one-step right, out-of-range clamping, same-position
    no-op, unknown-id recoverability, and mid-dissolve reorder leaving the
    dissolve intact); the app's `moveShot`/`movePreset` are thin inline array
    moves over the same clamp logic (like the inline add/remove), covered at the
    engine level.
  - [x] **Step 7, multiple presets in the UI** *(code complete 2026-07-14)* —
    the eighth production-feature iteration, surfacing the preset array the
    project document has persisted since v1: the operator switches among — and
    manages — the project's presets from a preset switcher row above the shot
    switcher (per-preset buttons, an Add Preset button, a Duplicate/Rename…/Remove
    Preset context menu — the shot-management UI one level up the `project >
    preset > shot` hierarchy; wipe/custom-shader transitions, shot reordering,
    and SRT/multiple destinations — step 8 — remain). **No document version bump**
    (the format stays v2): the active preset is session state like the active
    shot (at launch the app adopts the document's first preset), and audio
    configuration stays session state too — the mixer iteration's "strips join
    the preset when routing lands" calculus is unchanged. The engine surface is
    `Compositor.loadPreset(_:)`'s new contract — **switching presets never
    interrupts what is already playing out** (GLOSSARY.md's seamless-switch
    promise): the on-program shot holds when its id exists in the incoming
    preset (adopting that preset's version — the `updateShot` rule), otherwise
    keeps rendering as a **held snapshot** with `activeShotID` nil until a take
    from the new pool (cut-to-first-shot remains only the nothing-on-program
    boot case), with the outcome on `preset.loaded`'s new `activeShot` param —
    plus the `programShot` accessor the app's reconfigure pass uses to keep a
    held snapshot's inputs running. `apps/tingra` gained `PresetEdit` (pure
    new/duplicate/rename operations — a new preset empty, a duplicate under a
    fresh `PresetID` with **shot ids preserved verbatim** so switching between
    original and copy holds program by id match, empty renames ignored) and
    `EngineModel` now owns the full preset array (live shots synced into the
    active preset's slot before every save/switch/duplicate; add is not
    switching; removing the active preset switches to the adjacent one and takes
    its first shot unless an id match holds — the removed preset leaves the air,
    never a dead program; the last remaining preset cannot be removed) with
    `preset.added`/`preset.renamed`/`preset.removed` control-plane events; every
    new button reports its `tap` first; new strings localized `de`/`es`.
    Decisions recorded in ARCHITECTURE.md, "Multiple presets in the UI". Tests:
    `TingraCompositionTests` (now 74 — hold-by-id-match adopting the incoming
    version, held-snapshot rendering until a take, mid-dissolve switch
    completing toward the snapshot) and app `TingraTests` (now 54 — the
    `PresetEdit` operations, fresh-id uniqueness, verbatim shot copies,
    whitespace trimming, empty-rename behavior).
  - [x] **Step 7, the audio mixer** *(code complete 2026-07-12)* — the seventh
    production-feature iteration, building the last unbuilt engine service: the
    **mixer**, replacing the app's single-microphone pass-through with a real
    mixing graph — one **channel strip** per audio input with level and mute
    (pan, routing, audio effect chains, and monitoring/meters are later
    iterations; wipe/custom-shader transitions, multiple presets in the UI, shot
    reordering, and SRT/multiple destinations — step 8 — also remain). New
    package `packages/TingraAudio` (the Audio engine service — a host-side engine
    library beside `TingraComposition`, same protocol-package-only dependency
    rule, added to the ci.yml matrix): `AudioMixer` runs a **mix tick** on the
    injected clock (1024-frame stereo float32 blocks at 48 kHz), summing every
    unmuted strip's queued samples scaled by its level; each strip's audio is
    normalized once at channel intake (a persistent task-confined `AVAudioConverter`;
    mono spreads to both program channels), each channel queue is a one-second
    drop-oldest FIFO, an underrunning strip contributes silence (never stalling
    the mix, which emits from its first tick), and blocks carry the mix tick's
    clock time — contiguous monotonic PTS, the audio analog of the program video
    rule, recorded in CLOCK.md's timestamp table. `StreamSession` gained an
    `AudioSource` enum mirroring `VideoSource` (`.input` pass-through unchanged
    — `init(videoInput:audioInput:)` preserved, CLI and `StreamCoordinator`
    untouched; `.program` consumes the mixer's blocks as-is and reports the
    stable `"mix"`/`"Mix"` identity). `apps/tingra` gained the `TingraAudio`
    dependency and a `MixerView` panel replacing the streaming panel's
    microphone picker — one strip per discovered microphone (mute toggle, live
    level slider), seeded first-unmuted-at-unity, with muting a strip also
    stopping its device (the microphone indicator stays honest) via a coalesced
    audio reconfigure pass; the one program-audio drain tees mixed blocks into
    the live session exactly like the program-frame drain, and the stream now
    always carries program audio (an all-muted mixer streams silence). Strip
    settings are session state this iteration (they join the persisted preset
    when routing lands — no document version bump). Every new control reports its
    `tap` first; new strings localized `de`/`es`. Decisions recorded in
    ARCHITECTURE.md, "The audio mixer". Tests: `TingraAudioTests` (12 —
    silence-from-first-tick, level/mute/negative-level, mono spread and stereo
    mapping, two-strip summing, intake sample-rate conversion, queue-cap
    drop-oldest, strip removal, stop semantics, block-factory rejection),
    `TingraHostTests` (now 75 — a `.program`-audio session delivering mixer
    blocks on the session timeline and naming them "mix"), app `TingraTests` (now
    46 — `MixerStrip` seeding and equality); `scripts/integration-test.sh` re-run
    against the simulator (the CLI audio path unbroken by the `AudioSource`
    refactor — all scenarios pass).
  - [x] **Step 7, streaming from the app** *(code complete 2026-07-12)* — the
    sixth production-feature iteration, scoped to putting the composited program
    on air (the audio mixer, wipe/custom-shader transitions, multiple presets in
    the UI, shot reordering, and SRT/multiple destinations remain later
    iterations; the last is step 8). The engine surface reuses the CLI's proven
    live-stream lifecycle rather than building anything new: `StreamSession` gained
    a `VideoSource` enum so it accepts either a `.input` (the CLI's single camera,
    paced through `ProgramPacer`, session-owned lifecycle) or a `.program` (the
    compositor's already tick-paced `programFrames()`, consumed as-is) — the
    reconnect attempts, the 10-second stability window, the periodic stats, the
    duration timer, and the pass-through audio path are identical for both, and
    the existing `init(videoInput:)` is preserved so the CLI and `StreamCoordinator`
    are untouched. `TingraHost` gained `SecureStorage`/`KeychainSecureStorage`
    (the data-protection Keychain, keyed by destination URL): the stream key
    lives only there, never in the project document, an event, or a log.
    `TingraComposition`'s `Project` went to **document version 2**, adding an
    optional, key-free `ProjectDestination` (URL only) beside the presets — a v1
    file decodes forward with it nil. `apps/tingra` gained the `TingraOutputPlugIns`
    dependency, activates `HaishinKitOutputPlugIn` into a real `OutputRegistry`,
    tees its one program drain into both the preview and (while live) the session,
    and grew a streaming panel (destination URL, secure key field, microphone
    picker, Start/Stop, and a `StreamStatus` label driven entirely by the bus's
    `stream.*` events — no poll); audio is microphone pass-through on the shared
    timeline (the CLI's model), reconnect defaults are `StreamSession.Policy`'s.
    Every new button reports its `tap` first; new strings localized `de`/`es`.
    Decisions recorded in ARCHITECTURE.md, "Streaming the program". Tests:
    `TingraHostTests` (a `.program`-source `StreamSession` delivering
    compositor frames on the session timeline and naming them "program"; the
    `SecureStorage` seam contract via an in-memory double),
    `TingraCompositionTests` (`Project` v2 + `ProjectDestination` round-trip,
    forward-compatible v1 decode, stable keys, missing-url throwing), all green;
    `scripts/integration-test.sh` re-run against the simulator (the CLI streaming
    path unbroken by the `StreamSession` refactor — all scenarios pass).
  - [x] **Step 7, presets and shots** *(code complete 2026-07-06)* — the data
    model plus engine plumbing, scoped ahead of transitions/layers/audio.
    `TingraComposition` gained `Preset` + `PresetID` (a named, persisted
    `Codable` collection of shots) and `Shot` grew a stable `ShotID` + `name`;
    `Shot`/`Layer` became `Codable` for the project/scripting contract (stable
    camelCase keys, `Layer.frame` flattened to `x`/`y`/`width`/`height`). The
    `Compositor` holds a loaded preset's shots and cuts among them with
    `loadPreset(_:)`/`take(shotID:)` (a cut; `setShot(_:)` stays the low-level
    direct path), emitting `preset.loaded`/`program.take` control-plane events;
    an unknown `take` id is a recoverable error event, never a crash. `apps/tingra`
    builds a preset of fixed-id shots (picture-in-picture, display, camera) from
    the current inputs and shows a shot switcher that takes a shot to program,
    preserving the active shot's role across input-selection rebuilds. Decisions
    (active shot is session state not persisted; a switch is a cut; fixed shot
    ids survive rebuilds) recorded in ARCHITECTURE.md, "Presets and shots". Tests:
    `TingraCompositionTests` (now 29 — preset/shot Codable round-trip +
    missing/optional-field decoding, `loadPreset`/`take`/unknown-id semantics)
    and app `TingraTests` (now 8 — the `ProgramLayout.shots` arrangement and
    stable ids).
  - [x] **Step 7, transitions: cut and dissolve** *(code complete 2026-07-08)* —
    the second production-feature iteration, scoped to cut/dissolve only (wipe
    and custom shader transitions remain unrepresented). `TingraComposition` gained
    `Transition` (`cut`/`dissolve(duration:)`, plain `Codable`, the same
    project-file contract as `Preset`/`Shot`); `Compositor.take(shotID:transition:)`
    grew a `transition: Transition = .cut` parameter, tracking an in-progress
    dissolve as a tick countdown (duration converted to whole ticks at call time,
    so progress is exact and deterministic under both the master clock and a
    synthetic test clock) rather than comparing wall-clock timestamps.
    `ShotRenderer` grew `renderDissolve(from:to:progress:frames:format:time:)`
    alongside `render(shot:frames:format:time:)`; `CoreImageShotRenderer` renders
    both shots' layer trees with its existing compositing path and alpha-blends
    the incoming image over the outgoing one at `progress` — no new shader.
    `activeShotID` updates immediately when `take` is called, whether the
    transition is a cut or a dissolve in progress, matching the cut's existing
    contract. `apps/tingra`'s shot switcher grew a `useDissolveTransition` toggle
    (a plain checkbox — GLOSSARY.md, "Transition") choosing cut or dissolve for
    the next take. Decisions (a transition is a `take` parameter, not yet a
    `Shot`/`Preset` field; tick-counted duration; the crossfade lives behind the
    `ShotRenderer` seam; `activeShotID` tracks the incoming shot immediately)
    recorded in ARCHITECTURE.md, "Transitions: cut and dissolve". Tests:
    `TingraCompositionTests` (now 42 — `Transition` Codable round-trip +
    missing/unknown-kind decoding, dissolve progress ramping and completion, a
    zero-duration dissolve completing on its first tick, and the Core Image
    renderer's crossfade pixel output at progress 0/0.5/1) and app `TingraTests`
    (unchanged at 15 — the switcher toggle needs no new `ProgramLayout` coverage,
    it only chooses the transition `EngineModel.take(_:)` passes through).
  - [x] **Step 7, the layer-tree editor** *(code complete 2026-07-11)* — the
    third production-feature iteration, scoped to editing an existing shot's layer
    tree (per-layer effect chains are a later "Effect" iteration; the audio mixer
    and wipe/custom-shader transitions remain). `TingraComposition` gained
    `Compositor.updateShot(_:)`: it replaces the loaded preset's shot with the
    matching id in place, and when that shot is on program the next tick renders
    the edited layer tree — live, no separate "apply" step (CLOCK.md's live
    canvas); mid-dissolve, the dissolve continues toward the edited incoming
    tree; an unknown id is a recoverable `shot.update` error event; a successful
    update deliberately reports **no** event (a live editor drives it at gesture
    rate — per-update events would flood the control-plane bus; observability
    comes from the app's per-gesture `tap` events). Edits persist in the loaded
    preset and the app's session copy, surviving shot switches within the session;
    project-file save/load is still a later iteration, and an input-selection
    change still re-derives the built-in shots from `ProgramLayout`, discarding
    edits. `apps/tingra` gained the `LayerTreeEditor/` feature directory:
    `LayerTreeEdit` (the pure add/remove/reorder/frame/opacity operations over
    `Shot` — `Layer` unchanged, a plain `Codable` value addressed by its
    bottom-to-top index) and `LayerTreeEditorView` (a topmost-first layer list,
    an add-layer menu over every discovered camera and display, move up/down and
    remove buttons, and live frame/opacity sliders; new strings localized
    `de`/`es`). `EngineModel`'s reconfigure pass now distinguishes a selection
    change (rebuild the built-in shots) from a layer-tree edit (keep the edited
    shots) and starts/stops inputs referenced by edited layer trees on demand.
    Decisions recorded in ARCHITECTURE.md, "The layer-tree editor". Tests:
    `TingraCompositionTests` (now 47 — `updateShot` live-render, persistence
    across takes, inactive-shot pool update, unknown-id, and mid-dissolve
    semantics) and app `TingraTests` (now 25 — the `LayerTreeEdit` operations,
    their out-of-range behavior, and shot-identity preservation).
  - [x] **Step 7, project save/load** *(code complete 2026-07-12)* — the fourth
    production-feature iteration, scoped to persisting the preset the operator
    already has (shot management UI — add/duplicate/rename/remove shots — multiple
    presets in the UI, the audio mixer, and wipe/custom-shader transitions remain
    later iterations). `TingraComposition` gained `Project` — the saved document
    for a whole show (GLOSSARY.md), a plain `Codable` value type on the same
    project/scripting contract as `Preset`/`Shot`/`Layer` (stable camelCase keys,
    exact round-trip): a **required** `version` (decoding a document newer than
    the build understands throws, rather than silently loading fields the next
    save would clobber) and an optional `presets` array defaulting to empty (v1
    holds presets only; destinations and settings join with a version bump).
    `apps/tingra` gained `ProjectStore` (atomic, sorted-key JSON at
    `~/Library/Application Support/Tingra/Default.tingraproject`; an unreadable
    file is set aside as a `.unreadable` sibling and reported, never overwritten)
    and **autosave** — a debounced write one second after the last layer-tree
    edit, an immediate save when a fresh project is seeded, a flush on stop;
    explicit Save/Open menus wait for the document-based UI. At launch the app
    loads the document's first preset (further presets in the array are preserved
    verbatim across saves); the built-in `ProgramLayout` arrangement seeds a
    fresh project only. The layer-tree-editor caveat is resolved: a camera/display
    selection change now **rebinds, never rebuilds** — every layer bound to the
    previously cast device rebinds to the new choice (`LayerTreeEdit.rebindingLayers`),
    keeping frames and opacities; picking "None" parks the device (its layers
    keep their binding and contribute nothing — the existing disconnected-input
    semantic); a layer bound to an undiscovered input stays dormant until the
    device returns. Decisions recorded in ARCHITECTURE.md, "Project save/load".
    Tests: `TingraCompositionTests` (now 54 — `Project` round-trip, stable keys,
    missing-version and newer-version throwing, optional presets, equality) and
    app `TingraTests` (now 35 — `ProjectStore` save/load round-trip, missing-file,
    unreadable-file, and set-aside paths against a temporary directory, plus the
    rebind edit operation).
  - [x] **Step 7, shot management** *(code complete 2026-07-12)* — the fifth
    production-feature iteration, scoped to managing the shots of the preset the
    operator already has (multiple presets in the UI, shot reordering in the
    switcher, per-shot default transitions, the audio mixer, and wipe/custom-shader
    transitions remain later iterations). `TingraComposition`'s `Compositor` gained
    `addShot(_:at:)` and `removeShot(shotID:)` — granular pool edits beside
    `updateShot(_:)`, not a reload path, so the active shot and any in-progress
    dissolve survive by construction. Adding never changes the program (adding a
    shot is not taking it; a duplicate id is a recoverable `shot.add` error
    event); removing the shot on program **cuts to the adjacent shot** — its
    follower, or the new last shot — clearing any dissolve toward it, and removing
    the last remaining shot leaves the background-only live canvas, never a dead
    program; removing a dissolve's *outgoing* shot lets the dissolve finish from
    its snapshot. Both report success events (`shot.added`/`shot.removed` —
    discrete actions, not gesture-rate). `Preset`/`Shot`/`Layer` and the project
    document format are unchanged (no version bump). `apps/tingra` gained `ShotEdit`
    (the pure new/duplicate/rename operations — fresh UUIDs for user-authored
    shots, a new shot empty over black, a "<name> copy" duplicate, empty renames
    ignored) and the switcher grew an Add Shot button (available even with no
    shots) plus a per-shot context menu (Duplicate, Rename… via an alert with a
    text field, Remove Shot — immediate, destructive role); the seeded fixed-id
    shots are just shots now, renameable and removable like any other; every new
    button reports its `tap` first; new strings localized `de`/`es`. Edits persist
    through the existing debounced autosave. Decisions recorded in ARCHITECTURE.md,
    "Shot management". Tests: `TingraCompositionTests` (now 65 — add
    append/insert-at-index/clamping, duplicate-id and unknown-id recoverability,
    add-to-empty-pool not taking, remove-inactive, cut-to-follower and
    cut-to-previous, removing the only shot, and both mid-dissolve removal
    semantics) and app `TingraTests` (now 43 — the `ShotEdit` operations, fresh-id
    uniqueness, identity preservation, whitespace trimming, and empty-rename
    behavior).

## Decisions to settle

- [x] **Recording in the app — decided and recorded 2026-08-06, go-ahead given
  and built the same day** (the full record is in ARCHITECTURE.md, "Recording
  in the app"). The scoping call for the first iteration after step 9
  closed: the app can go live, fade to black, monitor, and multiview, and it
  cannot record the show. `--record` has shipped on the CLI's `stream` since
  step 5; `apps/tingra-app` never linked `TingraRecordingPlugIns`. **The last
  CLI-only capability.**

  **The shape, in one line each.** Recording in the app is a **second
  `StreamSession` carrying no destinations**, a leaf on the program tee beside
  the streaming session (the monitor path's tee shape) — not a recording bolted
  onto the streaming session, which would weld the two together so that ending
  the stream finalizes the file, and not a `RecordingService` the app drives
  itself, which would re-implement the `T0` rebase CLOCK.md says happens once.
  A session with **no destinations and a recording becomes legal** (the
  `connectLegs()` guard is a CLI-era artifact and the only code that assumes a
  leg exists); neither destinations nor recording stays an error. A **recording
  failure ends a record-only session**, the companion the "recording never ends
  the stream" rule has been missing, adding an `Outcome.recordingFailed` that
  appends one value to `stream.stopped`'s documented `reason` list. The folder
  is a **machine-local preference** defaulting to `~/Movies` (`MonitorPreferences`
  precedent; Desktop and Documents are TCC-protected and would prompt), with a
  date-stamped name that never overwrites an earlier take.

  **What it deliberately does not do.** No `TingraPlugInKit` change, no document
  change and so **no version bump**, and **no MCP surface** — the 2026-07-05
  deferral of `record_start`/`record_stop` stands, and this iteration is why it
  can: the app writes under the operator's identity, so the
  daemon-writes-files-under-its-own-identity consideration that deferral named
  stays untouched. The CLI still requires `--url`, so a record-only run is newly
  possible in the engine and deliberately not offered. `StreamSession` keeps its
  name (`OutputSession` is honest but not worth the diff — considered, declined,
  written down).

  **The open sub-question, answered 2026-08-06 — the free-space check is IN**
  (Larry's call, folded into the record before the build). A recording refuses
  to open when the volume cannot hold **five minutes** at the configured
  bitrate: a duration threshold rather than a gigabyte one, since the bitrate is
  known and duration is the unit an operator thinks in. It lives in the
  recording service's `start(to:)` so the CLI inherits it with no CLI change,
  reuses `RecordingServiceError.unwritableDestination` rather than adding an
  enum case (which would break exhaustive switches in third-party code), and
  puts `RecordingCapacity` in `TingraRecordingPlugIns` — so the promise that
  `TingraPlugInKit` gains nothing still holds.

  **Two things the record missed, found in the build and written back into it.**
  (1) **Two sessions had no way to be told apart.** Both emit `stream.started`
  and `stream.stopped`, which the record approved of — and then had the app run
  two at once, where the streaming panel would have read the recording's stop as
  the stream's and told the operator they were off air mid-broadcast.
  `StreamSession` gained an optional `label`, emitted as a `session` param on
  exactly those two events (every other session event already carries a
  `destination`, and a record-only session emits none). Nil for the CLI and the
  daemon, so `--json` output is byte-identical. (2) **Quitting needed the app's
  first AppKit hook.** `EngineModel.stop()` was never called at quit — harmless
  for a stream, fatal for a recording, since an unfinalized movie is an
  unplayable one. `TingraAppDelegate` answers `.terminateLater` while the file
  is closed.

  **Built and verified.** Engine: the `connectLegs()` guard, `Outcome.recordingFailed`,
  the record-only end rule (both **mutation-checked** — reverting either fails
  its test), and the free-space check behind the seam. App: `RecordingPanel`,
  `RecordingPreferences`, `RecordingFilename`, the second tee leaf, and the quit
  hook. Tests **843 across 13 targets** (TingraHost 93 → 98, TingraRecordingPlugIns
  11 → 24, `apps/tingra-app` 115 → 147), warning-clean, `check-format` clean.
  `integration-test.sh` **was re-run** — the record said it must not be skipped,
  because changing the `connectLegs()` guard edits a line every CLI stream
  executes. **Larry's run on the final state: "All integration scenarios
  passed", 37 `PASS` lines, no `FAIL` line — the 37-check / 11-scenario baseline
  exactly held**, recording included (ffprobe verifying an H.264 + AAC file of
  the expected duration). That is what proves the guard change is inert for the
  case that has always worked. *(An earlier count of 36 during this session was
  my own miscount — taken by grepping `PASS` without also grepping `FAIL`, on a
  run whose full output was never captured. The baseline was never actually in
  question; the lesson is to capture one run to a file and read it, rather than
  re-running the script per statistic.)*

  **Still deferred and named:** per-destination compression settings, a record
  button on the multiview window, and recording something other than program.

- [x] **The main window's input rows — built 2026-08-04, recorded after the
  fact (ARCHITECTURE.md, "The main window's input rows").** The top-left pane
  stopped being a strip of the multiview's grid and became its own surface: two
  rows of every **available** video input, every one of them live, each one
  clickable to stage on preview.

  **Recorded after the fact, against the decide-then-build rule the effect seam
  set, and that is the note worth keeping.** Three decisions recorded as settled
  were reversed by the code before anything was written down — the tiles being
  inert, monitoring never starting a device, and the grid being one shared view.
  Two of the three were reversals a reader of the docs alone would have had no
  way to see coming, which is exactly the failure mode the rule exists to
  prevent. The records are now narrowed in place rather than rewritten, so the
  original reasoning and what overturned it both stay readable.

  **What was reversed, and what answered each objection.** (1) *Inert tiles*:
  the multiview record refused a click because a tile is an **input** while
  preview stages a **shot**, and "synthesize the shot showing only this input"
  is a heuristic one click from air. Answered by inverting the bridge — **an
  authored shot wins**, and one is invented only when no authored shot shows
  the input at all, so the common case stages something the operator wrote.
  Nothing reaches program either way; Take is still the one step to air.
  (2) *Monitoring never starts a device*: the main window now runs every
  discovered video input, which the multiview window still does not. The rule
  was written for a window that can be **closed**, where the cost was
  avoidable; the main window cannot be, so the price is stated rather than
  absorbed — every camera holds its indicator light on and a Continuity Camera
  keeps its iPhone awake for as long as the app runs. Audio is untouched: a
  strip still starts its device on unmute. (3) *One extracted view*: superseded
  once the two surfaces stopped answering the same question (available versus
  running). They still share the `MultiviewTile` derivation, `MonitorTile`, and
  the newly extracted `Tally` tint pair — the layer that was actually carrying
  the anti-drift guarantee.

  **Also in the same change:** the column became a `ScrollView` — a plain
  `VStack` resolved a shortfall by collapsing the monitors *and* pushing the
  camera and display pickers past the bottom edge — which in turn forced the
  monitoring section's height to become arithmetic derived from the window's
  **width**, since a scroll view proposes an unbounded height that
  `maxHeight: .infinity` cannot resolve against.

  **The `DisplayInput` bug this iteration surfaced, which was not a UI bug at
  all.** `SCStream` retains neither its delegate nor an added stream output, so
  `DisplayStreamOutput` deallocated the moment `makeRunningStream` returned. The
  stream kept running and kept the screen-recording indicator lit while
  delivering **zero frames**: `start()` succeeded, nothing errored, and every
  display tile and display layer was silently black. This reached the program
  bus and anything streamed from it, not just the tiles — it was visible here
  only because the rows made every display live at once. Both are now held as
  `RunningStream` for the capture's lifetime.

  **Verification.** App build warning-clean, `apps/tingra-app` **133 tests in 14
  suites**, `TingraCapturePlugIns` **38 tests in 9 suites**, `check-format`
  clean. `integration-test.sh` **was** re-run — unlike the two step-9 iterations
  but like the fade-to-black one — because the `DisplayInput` fix changes what
  display capture delivers into the program and therefore what reaches a sink:
  **37 checks across 11 scenarios, all passing, the baseline unchanged.**

- [x] **Convert the app from an SPM executable to the Xcode project
  `apps/tingra-app` — planned 2026-07-29, built 2026-08-01.** Recorded nowhere in
  the repo until 2026-07-31, which is why it slipped. The plan had two parts, **Part A first so
  the UI work is built and verified once, in the app's final home**; Part B (the
  main window's two sections) was built first anyway and landed 2026-07-31, so
  Part A now inherits one extra file to move and nothing else changes.

  **Why.** `apps/tingra` is an SPM executable, so it has no bundle, no
  Info.plist, and an ad-hoc signature whose designated requirement is the
  binary's cdhash — which changes every build, so macOS TCC re-prompts for
  Screen Recording, Camera, and Microphone on every run.
  `scripts/run-app.sh` + `scripts/sign-app.sh` work around exactly this by
  wrapping the executable in a minimal `tingra.app` and re-signing it with a
  stable identity; a real app target makes the workaround unnecessary. It also
  makes the deferred packaging (signed, notarized `.app`) an ordinary build
  setting rather than a script, and it is the trigger the UI-package deferral
  named: once the app builds via `xcodebuild`, code in a package keeps fast
  `swift test` and full warning visibility (Xcode hides package warnings —
  CLAUDE.md, "Strict Compilation").

  **The shell already exists, unfinished.** `apps/tingra-app` was created
  2026-07-12 (Xcode 26.6, folder-synchronized groups, so files dropped into
  `apps/tingra-app/tingra-app/` join the target automatically) and has sat as a
  stub since: `TingraApp.swift` is an empty `WindowGroup` with `ContentView()`
  commented out. Use it as the base rather than regenerating it, and fix its
  defaults: `ENABLE_APP_SANDBOX = NO` (Tingra is not sandboxed; hardened runtime
  stays on — the `tingra-cameras` lesson, where the sandbox blocked the mach
  lookups CMIO camera extensions need), `MACOSX_DEPLOYMENT_TARGET = 15.0`
  (currently 26.5), `SWIFT_VERSION = 6.0` (currently 5.0, keeping
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`),
  `PRODUCT_BUNDLE_IDENTIFIER = com.moonwink.tingra.app` (currently
  `com.moonwink.tingra-app`), `PRODUCT_NAME = Tingra` with
  `PRODUCT_MODULE_NAME = TingraApp`, Info.plist `NSCameraUsageDescription` and
  `NSMicrophoneUsageDescription` plus copyright and app category, `de` and `es`
  added to `knownRegions`, and the empty `tingra-appUITests` target deleted
  (this repo is Swift Testing only).

  **The migration.** `git mv` `apps/tingra/Sources/Tingra/` into
  `apps/tingra-app/tingra-app/` keeping the flat layout and the
  `LayerTreeEditor/` subdirectory; carry `Localizable.xcstrings` across and
  verify the `de`/`es` entries survive; move `Tests/TingraTests/` onto the unit
  test target, where `@testable import Tingra` becomes `@testable import
  TingraApp`; replace the shell's two package references (`../tingra` and a lone
  `TingraAudio`) with the nine from CLAUDE.md's dependency graph and link their
  products; update `.github/workflows/ci.yml` so the app's step becomes
  `xcodebuild build`/`test` (scheme `tingra-app`,
  `-destination 'platform=macOS,arch=arm64'`, `CODE_SIGNING_ALLOWED=NO`) while
  the per-package `swift build` jobs stay; update `scripts/format-swift.sh` and
  `check-format.sh`; and delete `apps/tingra` once the project builds and tests
  green. **End state: one app folder, `apps/tingra-app`.**

  **Two loose ends to close in the same pass.** `apps/tingra-app` is an Xcode
  project missing from both README's listing and CLAUDE.md's project tree, and
  its Xcode user-state files (`UserInterfaceState.xcuserstate`,
  `xcschememanagement.plist`) are **tracked** — they need `git rm --cached`
  alongside the ignore rule, since ignoring a tracked file does nothing.

  **The open question, settled 2026-08-01: both scripts survive, repointed.**
  The recommendation was to delete `sign-app.sh` and slim `run-app.sh` down to a
  build-and-exec; Larry kept both. `run-app.sh` now drives `xcodebuild` into a
  fixed derived-data path under `apps/tingra-app/.build` (already git-ignored, so
  the product path is deterministic without parsing build settings) and execs
  `Tingra.app/Contents/MacOS/Tingra` in the foreground — the one thing the app
  target does not provide, since `xcodebuild` alone will not stream
  `ConsoleEventSink` to a terminal. `sign-app.sh` re-signs that bundle with the
  stable identity under `com.moonwink.tingra.app`, preserving the build's
  entitlements; on a configured Mac Xcode's automatic signing has already done
  the job, so it now earns its place only where automatic signing produces no
  usable signature — a `CODE_SIGNING_ALLOWED=NO` build, or a checkout on a Mac
  whose keychain holds no certificate for the team.

  **Built as recorded, with four things worth keeping.** (1) **The move really
  was a move**: the source diff is five mechanical categories and no logic —
  the header module line (`tingra` → `tingra-app`, matching the `tingra-cli`
  convention), `@testable import Tingra` → `TingraApp`, seven added imports,
  fifteen `bundle: .module` arguments dropped, and one `nonisolated`. (2) **Three
  build settings the shell already carried turned out to have teeth**, and each
  cost exactly one kind of edit: `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`
  wanted `import TingraEventBus` in the five views that call `eventBus.tap(...)`
  (plus `TingraAudio` in `MixerView` and `Foundation` in one test);
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` wanted `nonisolated` on
  `VideoEffectProviderBox`, the `Mutex`-guarded box the compositor's tick task
  reads off the main actor — one type, because the app is otherwise main-actor
  code all the way down, which is the trade the setting is meant to make; and
  `Bundle.module`, being SwiftPM-generated, does not exist in an app target at
  all, so localized-string call sites simply drop the argument and read the app's
  own catalog from `Bundle.main`. (3) **The hardened runtime needed an
  entitlements file the plan did not name.** Keeping `ENABLE_HARDENED_RUNTIME`
  while dropping the sandbox is not enough: the hardened runtime denies camera
  and microphone access unless the binary opts in, so
  `tingra-app/tingra-app.entitlements` carries the same three keys
  `apps/tingra-cli` and `apps/tingra-cameras` already needed —
  `device.camera`, `device.audio-input`, and `cs.disable-library-validation`
  (without the last, a camera's CMIOExtension never starts its graph). Verified
  on the built bundle: the designated requirement is certificate-based rather
  than cdhash-based, which is the whole point of the conversion. (4) **CI needed
  a job, not a matrix row.** The app leaves the per-package `swift build` matrix
  for its own `xcodebuild test` job, and its warning check excludes three things
  that are not our code: `SourcePackages` checkouts (the matrix already builds
  each package warning-clean), `appintentsmetadataprocessor`'s note that the app
  declares no App Intents, and the unsigned-build complaint about Apple's own
  `XCTAutomationSupport`/`XCUIAutomation` binaries. 131 tests in 14 suites, green.

  **Signing moved out of the tracked project files (2026-08-01, Larry's call as
  the repo heads for GitHub).** The conversion had carried
  a hard-coded `DEVELOPMENT_TEAM` into the `.pbxproj` six times, and
  `apps/tingra-cameras` already had it four times. A Team ID is not a credential
  — it is visible in any signed app — but it is an Apple Developer *account*
  identifier, and a tracked one makes every other contributor's build fail with
  "No signing certificate found for team …" against a file they must edit. Both
  projects now read `DEVELOPMENT_TEAM = $(TINGRA_DEVELOPMENT_TEAM)` from a
  committed `Tingra.xcconfig` whose first line is `#include? "Local.xcconfig"` —
  an *optional* include, so a checkout without the git-ignored `Local.xcconfig`
  still builds, which is exactly what CI does. `Local.xcconfig.example` is
  committed beside it. `sign-app.sh` no longer names a certificate holder. The
  policy is written into CLAUDE.md, "Signing: nothing personal in a tracked
  file", including the trap that Xcode silently re-adds `DEVELOPMENT_TEAM` to
  the `.pbxproj` whenever a team is picked in Signing & Capabilities. Audited
  the rest of the tree at the same time: no keys, no absolute home paths, no
  certificate hashes; `Package.resolved` is public dependencies only, and the
  `live_xxxx` strings in README/CLI.md are documentation placeholders. Verified
  three ways — the signed local build is byte-for-byte the same identity, an
  unsigned build with `Local.xcconfig` moved aside succeeds, and
  `tingra-cameras` still builds signed.

  **The conversion's premise proved on the machine (2026-08-05).** Everything
  above verifies the *signature*; whether a TCC grant actually survives a
  rebuild is a claim only the real Mac can settle, and it stayed unexercised
  for a week. Now closed, all four authorization-touching paths confirmed by
  hand: camera (tiles live), **microphone — granted, captured, then rebuilt
  and relaunched with no second prompt**, which is the conversion's whole
  reason for existing; multiview (⌥⌘M); and streaming from the app, verified
  server side against the local simulator. `integration-test.sh` passed in the
  same pass, which also covers the black generator — the one thing that had
  landed since its previous run. Recording the result here because the gate
  was tracked in no file: an unexercised TCC path leaves no trace in a build
  log, a test run, or a diff, so nothing in CI can ever close it.

- [x] **Live device lists in the app — decided 2026-07-28, go-ahead given
  with display hot-plug included, and built the same day.** The app never refreshes its device lists after boot: `cameras`,
  `displays`, `videoInputs`, and `audioInputs` are computed once in the boot
  pass, and `eventBus.events()` is consumed in exactly one place (stream
  status only), so the `device.connected`/`device.disconnected` events the
  capture plug-in has emitted since step 2 reach nothing. Hot-plugging does
  nothing until relaunch; unplugging leaves a stale picker entry. The engine
  already follows the rule the app breaks, and `devices --watch` already
  consumes these events correctly — the design follows it. Full record in
  ARCHITECTURE.md, "Live device lists in the app"; the shape in brief:
  - **One bus consumer, two handlers** — the refresh rides the existing
    `streamStatusTask`, which starts draining before the plug-ins activate, so
    no first-session device event is missed. A `device.*` event re-reads
    `registry.allInputs` (never the event's params — the plug-in updates the
    registry *before* emitting) and reruns the coalescing reconfigure passes.
    Never a poll loop.
  - **Dormancy everywhere, consistently**: a shot's layer, a channel strip,
    and a picker selection all keep their binding to a device that has gone
    away, exactly as they already do for a device that was never discovered.
    `applyConfiguration` stops such an input with `reason: "disconnected"`
    rather than today's blanket `"unreferenced"`.
  - **The seed becomes boot-only** — the point most worth a veto. Re-merging
    strips with `nil` authored channels re-runs `MixerStrip.seed`, which
    unmutes *and starts* the first non-generator strip; a hot-plugged
    microphone sorting first by name would go live on the program mix
    unasked. Syncing the active preset before the re-merge leaves the merge an
    authored list by construction, so a new device always appends **muted**.
    Same failure as the `Input` media capability's widened filter, arriving
    through a widened timeline.
  - **Display hot-plug joins the iteration** — the other veto point.
    `ScreenCaptureKitCapturePlugIn` emits no device events at all, so without
    it displays still need a relaunch. The addition mirrors
    `DeviceEventReporter` over `CGDisplayRegisterReconfigurationCallback`,
    reusing the existing event names with `kind=display` — no new vocabulary,
    but a second plug-in and a second OS notification source in one iteration.

- [x] **Filter macOS's private aggregate out of the monitor picker — decided
  and built 2026-07-28.** `CADefaultDeviceAggregate-<pid>-0` is
  created in our own process when `AVAudioEngineMonitor` starts, has output
  channels, and so joins `outputDevices()` and appears in the master strip's
  monitor picker moments after monitoring is turned on. **Instrumented before
  fixing** (five throwaway probes on the development Mac, since removed),
  which corrected the initial diagnosis: it is an **output** device, never
  reaches microphone discovery or the connect notification, and so cannot seed
  a channel strip — it is live today rather than latent behind the device-list
  gap above, and the fix belongs in `packages/TingraAudio`, not
  `TingraCapturePlugIns`. The discriminator is the composition dictionary's
  `private` flag, proven in both directions: macOS's aggregate carries
  `private = 1`, an Audio MIDI Setup-shaped aggregate carries no `private` key
  at all, so a user's authored aggregate stays visible. `deviceID(forUID:)`
  applies the same test as `outputDevices()`. Recorded in ARCHITECTURE.md,
  "Private aggregate audio devices in the monitor picker".

- [x] **UI components package — deferred (decided 2026-07-28).**
  ARCHITECTURE.md anticipates UI packages under `packages/` in phase 2;
  nothing requires one yet, and none exists. The app's reusable, model-free
  views (`MonitorTile`/`MonitorFrameSource`, `StripMeter`) stay in the app
  target until one of two triggers fires: the shared design-tokens file
  CLAUDE.md anticipates, or a second consuming surface. Extracting now would
  buy a package boundary with one consumer at the cost of the public-API and
  documentation burden a package carries; extracting at the trigger also
  restores fast `swift test` and full package-warning visibility for that
  code once the app builds via `xcodebuild` (Xcode hides package warnings —
  CLAUDE.md, "Strict Compilation"). Recorded in ARCHITECTURE.md,
  "Repository structure".

- [x] **Multiview: the buses-and-monitoring slice, third iteration — the one
  that closes step 9.** Decided and recorded 2026-07-27 (ARCHITECTURE.md,
  "Multiview"), **go-ahead given and built the same day** — the
  decide-then-build rule the effect seam set and the monitor path followed,
  applied because the shape here is genuinely open rather than queued
  plumbing. GLOSSARY.md already defines the thing ("a single view that tiles
  program, preview, and all inputs at once for monitoring"); what was undecided
  is whether it is engine surface at all, and where the per-input pixels come
  from.

  The seven approved decisions are in ARCHITECTURE.md; the shape in brief:
  - **Not a bus — a monitoring surface, and the first iteration of the slice
    that adds no bus at all.** The test is whether anything can be fed *from*
    it or promoted *out of* it: program feeds every sink, preview is promoted
    by `takePreview`, multiview does neither. GLOSSARY.md calls it a *view*,
    and the **Monitor** entry the last iteration added is its category. A bus
    would mean a third `ShotRenderer` pass compositing a mosaic at program
    resolution every tick for pixels one window reads. **Door left open:** a
    multiview *output* (sent to a second machine) is a real bus, just not
    this.
  - **Tiles are *pulled* from the compositor's existing latest-wins slots —
    one accessor, `latestFrame(forInput:)`.** A tile cannot drain
    `input.frames()` (that finishes the compositor's fill task and stops the
    program), and a per-input stream would be tick-rate work for a consumer
    that draws at display rate. The `MTKView`s pull on their own draws —
    CLOCK.md's preview-sampling rule one surface over. This is a **stronger**
    costs-nothing-unwatched than the preview bus itself: preview still tests a
    continuation every tick; a closed multiview window costs the engine
    nothing, and not one line of the tick task changes.
  - **The frame-ownership rule gains a fourth clause: read-only sharing for
    monitoring, never for delivery.** The compositor stays the one *holder*;
    a tile gets a retained, read-only reference for one draw — sound because
    rule 3 already makes the buffer immutable after transfer. Two obligations
    ride with it: a monitoring reader **draws and drops** (accumulating a
    history would starve `SCStream`'s pool), and a sink still gets ownership
    handed to it explicitly. Worth writing down precisely because the rule's
    value is that it has no quiet exceptions.
  - **Tally is derived and honest through a transition — the second accessor,
    `programInputIDs`.** Preview derives from the public `previewShot`
    (transitions are program-only). Program cannot derive from `programShot`:
    mid-dissolve that is the *incoming* shot, so an outgoing-only input would
    go dark while still visibly on air, and a tally that lies is worse than no
    tally. So the compositor computes the incoming shot's inputs **plus the
    outgoing shot's while a transition runs**, hiding the private
    `PendingTransition` rather than exposing it. Red wins over green.
  - **A separate window from a View-menu command, not a panel.** The main
    window already holds both monitors, both switcher rows, the layer editor,
    the mixer, and the destination list — a tile grid would compete with the
    two surfaces it duplicates. A window is also what makes the cost story
    *true*: a collapsed panel still exists.
  - **Tiles are inert — a decision, not an omission.** A tile is an *input*;
    preview stages a *shot*, and the bridge ("stage the shot that shows only
    this input") is a **heuristic one click from air** — exactly what the
    preview-bus record refused when it kept modifier-clicks off the program
    row. Synthesizing a shot on click would be a monitoring surface silently
    authoring the document. Named as what would make it free later: a
    canonical per-input full-frame shot, or drag-from-multiview.
  - **Multiview starts nothing, and one draw path serves every monitor.** A
    camera indicator lighting because a monitoring window opened is a defect;
    so it tiles only what is already running, and a started-but-silent input
    is a black named tile rather than one that pops in. `MonitorView`
    generalizes over a small `MonitorFrameSource` seam so program, preview,
    and every tile share one aspect-fit path and one `CIContext` — the
    `MeterCapsule` lesson, one media over.

  No engine event (a window is not engine state — the contrast is
  `monitor.started`, which opens a device); the menu command `tap`s.
  Strings localized `de`/`es`. **Deferred and named:** audio in multiview,
  a multiview *output*, and clicking to stage.

  **Two call-outs raised for the veto and both cleared:** the
  **ownership-rule clause** (it amends a 2026-07-04 rule whose worth is its
  lack of exceptions — the one thing here that outlives the iteration), and
  **inert tiles** (the most likely place to want more, and cheap to add later
  since nothing is designed against it).

  **Built as recorded, with three facts worth keeping.** (1) **Tally
  freshness was the one thing the record under-specified.** Every tally
  change follows an operator action the model already handles — except a
  transition *finishing*, which happens on a compositor tick with nothing
  observable attached, so a live-derived tally would have stayed unioned
  forever. A take now schedules **one** refresh for its own known duration
  plus a tick of margin (`EngineModel.scheduleTallyRefresh(after:)`),
  cancelled and replaced by a later take: not a poll (CLAUDE.md), one shot
  derived from the duration the take was made with. The margin is
  deliberate — a lamp lit a frame too long is honest, one that darkens early
  is not. (2) **Generalizing `MonitorView` over a `MonitorFrameSource` paid
  for itself at once**: program, preview, and every tile share one draw path
  *and* one `MonitorRenderContext` (device, queue, `CIContext`), where a
  context per view would mean one shader cache and texture pool per tile for
  one identical job; the framing collapsed into one `MonitorTile` used by
  both windows, so they cannot drift (the `MeterCapsule` lesson). (3) The two
  compositor accessors are read-only and lock-scoped, so **the tick task did
  not change** and `ShotRenderer` gained no requirement — the preview bus's
  record repeated one iteration on. `MultiviewView`/`MonitorView`/
  `MonitorTile` are seam-only and not unit-tested (the `MonitorView`
  precedent); the tests drive the pure derivation. **Tally** joined
  GLOSSARY.md with the build, and the **Multiview** entry gained the
  not-a-bus and starts-nothing properties. Tests: TingraComposition
  155 → 161, `apps/tingra` 107 → 115 — **718 across 13 targets**,
  warning-clean, `check-format` clean. `integration-test.sh` **not** re-run:
  no `StreamSession` change, no CLI change, and the compositor's addition is
  two accessors the tick task never calls. **With this the slice is complete
  and step 9 closes.**

- [x] **The monitor path: the buses-and-monitoring slice, second iteration.**
  Decided and recorded 2026-07-27 (ARCHITECTURE.md, "The monitor path"),
  **go-ahead given and built the same day** — the decide-then-build rule
  the effect seam set, applied because this iteration is design-shaped rather
  than queued plumbing. It is the slice's larger half and genuinely new
  subsystem territory: `TingraAudio` today only **mixes** and never plays
  anything out, so the engine's first audio *output* path is a new seam, not a
  method on the mixer; and **post-fader master metering** belongs here, where
  the per-strip meter record explicitly left it ("post-fader metering belongs
  to the master bus, a later monitoring slice").

  **The vocabulary call comes first, because it renames the item.** GLOSSARY.md's
  **preview** is the staging bus, and Tingra's audio is **not shot-scoped** —
  authored `AudioChannel`s live on the `Preset`, a `Shot` carries only layers —
  so staging a shot changes nothing about audio and there is no "audio of the
  staged shot" to preview. What the docs have called "audio preview" since the
  2026-07-19 monitoring ruling is the operator hearing the program mix on their
  own device: **monitoring**. Naming it preview would repeat exactly the error
  the preview-bus iteration corrected when it renamed `ProgramPreviewView` →
  `MonitorView`. GLOSSARY.md gains **Monitor** and **Master** (and a sentence
  on **Meter** splitting the pre-fader strip meter from the post-fader master
  meter) **with the build**, not before — the FTB record's own convention.

  The eight approved decisions are in ARCHITECTURE.md; the shape in brief:
  - **The seam is a `TingraAudio`-internal `AudioMonitor` protocol**, an
    `AVAudioEngine`-backed default behind it — **not** a `TingraPlugInKit`
    plug-in seam. `ShotRenderer` is the exact precedent, and the asymmetry
    decides it: promoting a package-internal protocol later is an additive
    *minor* on the stability contract, where a speculative seam shipped now and
    found wrong costs a **major** after 1.0.
  - **The monitor is a sink on the app's existing program-audio tee**, not a
    second bus and no new `AudioMixer` surface — routing v1's single bus makes
    a monitor-source selector a control with one entry. Two properties follow
    by construction: monitoring cannot alter the program mix (pinned in the pan
    record's byte-identical proof form), and nothing downstream of the monitor
    exists to reach.
  - **Bounded backlog, drop at the cap** — the mix tick and the output device
    are different clocks and *will* diverge, so the monitor caps its scheduled
    backlog at ≈85 ms and drops past it: the intake queue's one-second cap
    mirrored at the output, so drift costs a bounded glitch, never unbounded
    latency between what the operator sees and hears.
  - **Master metering rides the existing `MeterBlock`** (a `master:
    StereoMeterReading`), measured on the summed block — **stereo** where the
    strips are max-across-channels, because the master is where the stereo
    image is judged. Free interaction: any later master stage (FTB's gain) is
    upstream of the reading by construction, so the meter reads black as
    silence with no change — what the FTB record asked this slice to inherit.
  - **Mute-stops-device is unchanged, and the three-record deferral is
    *answered*.** The "future monitoring path may keep muted devices running"
    note was always about **PFL/solo**; monitoring the program mix hears
    nothing from a muted strip, so the honest-microphone posture stays. Solo is
    out of this iteration (no GLOSSARY channel-strip slot, and it is the first
    thing needing a second sum) and is what re-opens the question.
  - **A master strip at the trailing end of the mixer panel** carries the
    stereo master meter and the monitor controls. **No master fader** — no
    master gain exists, and inventing one would pre-empt FTB's master stage.
    `monitor.started`/`monitor.stopped` are the only events; the level is
    gesture-rate (`tap`s only). No CLI or MCP surface: the CLI never builds a
    mixer, and a headless daemon has no headphones.

  **Three call-outs were raised for veto and all three cleared:** the rename
  (it reclassifies a queued roadmap item), `UserDefaults` (a new mechanism in
  this repo — there had been no use of it anywhere), and solo/PFL deferred.

  **Built as recorded, with three facts worth keeping.** (1) The master meter
  needed **no second stream and no second walk** — `MeterBlock` gained
  `master: StereoMeterReading` with a `.floor` default, so every existing
  construction site kept compiling, and the reading comes off the `left`/
  `right` arrays the tick had already summed. (2) The seam's `play(_:)` takes
  `CapturedAudio`, the pipeline's own currency, which is what lets the monitor
  be a leaf on the existing tee instead of needing its own feed;
  `AVAudioEngineMonitor` is an **actor** rather than a `Mutex`-guarded
  `Sendable` class like `AudioMixer`, because `AVAudioEngine` and its nodes are
  non-`Sendable` reference types — actor isolation is the seam's mutual
  exclusion, so **no `@unchecked Sendable` escape was needed anywhere**.
  (3) The app's two meters now share one `MeterCapsule` view, so the scale,
  the zone boundaries, and the ballistics cannot drift between two meters an
  operator reads side by side. `AVAudioEngineMonitor` is **seam-only** and not
  unit-tested (the `CameraInput` policy); the tests drive a `RecordingMonitor`
  double. Tests: TingraAudio 31 → 48, `apps/tingra` 101 → 107 — **704 across
  13 targets**, warning-clean, `check-format` clean. `integration-test.sh` was
  **not** re-run: the CLI never builds a mixer and `programAudio()` is
  byte-for-byte what it was, so the streamed path is untouched.
  **Multiview remains** — the slice's last iteration.

- [x] **Fade to black (FTB): the program master stage.** Raised 2026-07-26 —
  nothing existed then: no `Transition` case, no compositor or mixer stage, no
  GLOSSARY.md term. Every switcher has it and Tingra had no way to take the
  program off air short of stopping the stream, so it was a real gap, but
  **not** a queued step-8 item: it needed a decision record first (the effect
  seam's decide-then-build rule), and it was scoped against the buses-and-
  monitoring slice rather than bolted onto it. **Decided and recorded
  2026-07-27** (ARCHITECTURE.md, "Fade to black"), **go-ahead given and built
  the same day** — the last unchecked item in "Decisions to settle".

  **Where it fits: a master stage on the program bus, not a transition.** A
  transition is the move from one shot to the next; FTB is a latching master
  state that holds the program black *across* shot switches, and it covers what
  viewers hear as well as what they see (GLOSSARY.md, "Program" — "what viewers
  see and hear"). Concretely, two insertion points on the same tick:
  - **Video** — the last stage in `Compositor`'s tick, downstream of the layer
    tree, the transition renderers, and any future program-level video effect,
    applied to the composited frame just before it is stamped and yielded on
    `programFrames()`. A `ShotRenderer` seam requirement (the `renderWipe`/
    `renderShader` precedent) keeps the compositor pixel-agnostic; the ramp
    itself rides the existing tick-counted `PendingTransition` spine, which
    already knows how to count a duration in ticks.
  - **Audio** — a master gain applied in `AudioMixer.mixBlock` after the mix
    walk, downstream of every channel strip's level/pan/mute, so it is the
    first thing that exists at Tingra's **master** (v1 has one bus, the program
    mix — GLOSSARY.md, "Routing"). It therefore lands adjacent to the deferred
    master-bus work (post-fader master metering, the monitoring path) and
    should be designed so that slice inherits the stage rather than replacing it.

  Both ramps are paced off the master clock (CLOCK.md), so video and audio
  reach black and silence together. Everything fed from program inherits it by
  construction — streaming legs and recording. Preview is untouched. Whether
  the *app's own program monitor* also goes black is an open question, not a
  given — see the prior art below.

  **Prior art (checked 2026-07-26 — vMix, TriCaster, ATEM).** All three
  implement FTB as a master stage, not a transition, which settles the shape:
  - **TriCaster** calls FTB "a final overlay layer – one that obscures all
    other layers when applied," composed above its DSK 1/DSK 2 overlay layers;
    the button *pulses while active*, confirming the latching model. Unlike
    DSK 1–4 it gets no local Take/Auto.
  - **ATEM** puts fade to black "at the extreme end of the processing chain,"
    explicitly so an operator "doesn't miss a layer."
  - **vMix** fades its output destinations (recordings, external output,
    fullscreen) rather than compositing a layer, and diverges from the
    recommendation below on three points worth deciding deliberately:
    audio fades only if a **"Fade To Black includes Audio"** setting is
    ticked (opt-in, not coupled); the duration is **not adjustable at all**
    (a standing user request — the one place to stay ahead of it); and the
    operator's own Output window is **deliberately not faded**, "in order to
    make it easier to queue up a source for later."

  **The decisions, in brief — the full record is in ARCHITECTURE.md:**
  - **One control fades video and audio together** (the point flagged as most
    likely to draw a veto; **confirmed** 2026-07-27). Tingra's operator is one
    person and its program is defined as picture *and* sound — a black picture
    over live room audio is dead air, the thing the control exists to avoid.
    Video-only stays a later per-invocation choice and costs one line, because
    the two engine surfaces are separately named and addressable.
  - **Two engine surfaces, one app control — structural, not a preference.**
    `TingraComposition` and `TingraAudio` depend on each other in neither
    direction, so there is no place *in the engine* for one object owning
    "faded to black": `Compositor.setFadeToBlack(_:duration:)` and
    `AudioMixer.setMasterFade(_:duration:)`, with `EngineModel` coordinating
    them as it already does for `reconfigure`. The audio surface is not called
    "fade to black" — at the master there is no black, only silence.
  - **The video stage is a pass over whatever the tick rendered — so a fade
    and a transition run at once.** The draft here had the ramp riding the
    `PendingTransition` spine; **it cannot**, because that struct carries an
    outgoing `Shot` and a `BlendKind` FTB has neither of, and occupying the
    slot would forbid hitting FTB *during* a dissolve — exactly when an
    operator reaches for it. FTB keeps its own ramp state beside the
    transition slot and reuses only the `tickCount(for:frameRate:)` helper.
  - **One new `ShotRenderer` requirement, and held black costs less than
    running clear.** `renderFaded(_:toBlack:format:time:)` runs only mid-ramp;
    at full black the compositor skips the layer-tree render entirely and
    renders an empty `Shot()` (already empty over opaque black). No default
    implementation, the settled `renderWipe`/`renderShader` precedent for this
    package-internal seam. `TingraPlugInKit` untouched.
  - **The audio stage lands upstream of the master meter for free**, as the
    monitor path promised: the gain applies to the summed `left`/`right`
    before `masterReading` reads those same arrays, so the master meter shows
    silence with no metering change at all. Strip meters stay **pre-fader** —
    the right asymmetry, since the operator can then see their microphone is
    live *and* see that nobody can hear it.
  - **Both ramps are constant-slope and tick-counted on their own cadence**
    (program ticks; mix blocks) from one requested duration, so they land
    within a tick of each other. An interrupted fade reverses at the same rate
    from where it is, rescaling its position if the ramp length changed. The
    audio ramp interpolates **per sample** within the block — a hand-ridden
    fader tolerates per-block steps, a scripted half-second ramp stepping
    once per block is a zipper. Both store an **integer position over an
    integer total** and divide, rather than accumulating a float step: an
    accumulated step leaves a residue on any ramp length that does not divide
    evenly (the default half second is 15 ticks and 23 blocks — neither
    does), the ramp then never tests equal to its endpoint, and the fade
    stage runs forever after one fade cycle. Found by a test; see the "built"
    note below.
  - **Latching session state that starts and stops nothing** — no
    `Preset`/`Project` field, no document version bump (the pre-release rule),
    and no device lifecycle change: fading down must not kill a camera
    indicator or drop a microphone.
  - **The app's program monitor goes black too, with a badge** (the second
    open question; **confirmed** 2026-07-27). vMix keeps its Output window
    live "to make it easier to queue up a source for later" — a reason that
    does not transplant, because preview and multiview are what queue up a
    source in Tingra and both stay live. A monitor showing what viewers are
    not seeing would contradict the GLOSSARY.md **Monitor** definition, and
    keeping it live would cost a second program render every tick.
  - **A 0.5 s default duration, as an engine parameter with no UI** — matching
    `Transition.defaultDissolveDuration`. vMix's real mistake is that the
    duration is not adjustable *at all*; Tingra's is a parameter from day one.
    No picker, because transitions have none either — exposing durations is
    one later call for all of them.
  - **One event per engine surface**: `composition/program.fadeToBlack` and
    `audio/master.fade`, each carrying `state` and `durationSeconds`, tied
    together by the app's single `fadeToBlack.button` tap. Each service
    reports what *it* did, so a later video-only fade reads correctly in the
    log without a param.
  - **Rejected as the *implementation*: modeling black as a special shot**
    taken with a dissolve. It clobbers `activeShotID` (the operator loses what
    they were on), covers no audio, and does not survive a shot switch
    underneath — three symptoms of a master stage wearing a shot's clothes.
    (The empty black `Shot()` the full-black shortcut renders is not that: a
    private render target inside the tick, never in the pool.)

  **A black *source* is a separate, complementary feature — not the rejected
  alternative.** TriCaster carries **BLACK** as a selectable source on its
  Program/Preview rows (beside the cameras, NET 1/2, DDR 1/2, GFX 1/2, FRM BFR,
  and M/E 1–8), and ATEM the same on its M/E bus — *while also* shipping FTB.
  The two are not redundant: a black source is **upstream**, so overlays and
  keys still composite over it (cut the background to black and keep a title
  up), whereas FTB is downstream and obscures everything. Tingra has neither
  today; a black source is a smaller, independent item — arguably just a
  first-party solid-colour **generator** in `TingraGeneratorPlugIns` beside
  bars and tone, bound into a layer like any other input, needing no new seam.
  Worth queuing separately (see "A black source" below); it is not a
  prerequisite for FTB and FTB is not a substitute for it.

  **The CLI/MCP surface stays a separate later call** (a `fade_to_black` tool,
  a `tingra-cli` verb): the CLI never builds a compositor or a mixer — it
  streams a single input through `StreamSession`'s `.input` source — so there
  is nothing for either to act on until that changes, the same reason the
  monitor path took no CLI surface.

  **Built as recorded, with five facts worth keeping.** (1) **The full-black
  shortcut turned out to be the cheap half of the iteration, not an
  optimization needing justification.** Because `Shot()` is already empty over
  opaque black, "composite nothing" is the *existing* seam call with an empty
  shot — so a held-black program does no layer compositing, no effect chains,
  and no fade pass, in a six-line branch. The one new `ShotRenderer`
  requirement runs only during the ramp. (2) **The audio side needed no new
  plumbing beyond the ramp itself**: the gain is a single pass over the
  `left`/`right` arrays `mixBlock` had already summed, inserted between the
  channel walk and the two things that read them, so the program yield *and*
  the master meter both picked it up with no change to either — the whole
  `AudioMixer` diff is the ramp state, the pass, and one event. (3)
  **Fade-and-transition-at-once is the case that justified the whole shape**,
  and the mock renderer proves it directly: a dissolve under a fade calls
  `renderDissolve` then `renderFaded`, in that order, on the same tick. (4)
  **The fade *tracks* a dissolve toward black rather than matching it
  exactly**, and the gap is inherent to a master stage rather than a defect:
  the fade darkens the already-composited, BT.709-tagged program frame where a
  dissolve blends the source images in one pass, so its input has been through
  one more encode/decode of the 8-bit working format — a handful of code values
  at the midpoint, none at either endpoint. A renderer test pins the tracking
  and records the reason, having first been written (wrongly) as an equality.
  (5) **Both ramps were first written as accumulating float steps, and a test
  caught it — the one real bug of the iteration.** Asking whether the master
  returns to its original setting after FTB is lifted turned out to have the
  answer "very nearly, forever": `max(target, gain - step)` clamps overshoot
  but not an undershoot of `1.1e-16`, so on any ramp length that does not
  divide evenly — including *both* defaults, 15 ticks at 30 fps and 23 blocks
  at 48 kHz — the ramp never reached its endpoint, the "is it active" test
  never went false again, and **the fade stage would have run on every tick
  and every block for the rest of the session** after a single fade cycle: a
  permanent extra Core Image pass darkening a frame by nothing, and a mix
  permanently scaled by `0.9999999999999999`. The fix is the integer
  position/total the `PendingTransition` spine already used and this should
  have started from. Pinned now by parameterized round-trip tests over the
  tick counts real durations actually produce.

  **The app side is a latch and two delegations, with no pure derivation to
  unit-test** — the `MonitorView`/`MultiviewView` seam-only precedent — so
  `apps/tingra` gained no tests; the behavior is pinned in both engine
  packages instead. Tests: TingraComposition 161 → 179 (the clear program
  running no stage at all, the ramp's amounts, full black compositing nothing,
  fade-under-transition and its ordering, the latch across a shot switch,
  preview never faded, the zero duration, `stop()` clearing it, and the event;
  plus four renderer tests for the pixels — the endpoints, the midpoint, the
  dissolve tracking, and the stamp and BT.709 tags; plus the ramp's own round
  trip, its uneven-length cases, and its rescale on a length change) and
  TingraAudio 48 → 61
  (the byte-identical open master in the pan record's proof form, the ramp to
  silence, the per-sample interpolation a per-block step would fail, the
  faded-master-silent/strips-still-reading asymmetry, the latch, the restore,
  `stop()`, the event, the block-count rule, the fade pass itself, and the
  same three ramp tests) —
  **749 across 13 targets**, warning-clean, `check-format` clean.
  `integration-test.sh` **was** re-run, unlike the two step-9 iterations before
  it, because this one does change what `programFrames()` yields to a sink:
  **37 checks across 11 scenarios, all passing**, the baseline unchanged.

- [x] **The black generator** *(queued 2026-07-27 as "a black source"; decided
  and built 2026-08-04; recorded in ARCHITECTURE.md, "The black generator")*.
  Queued 2026-07-27 by the fade-to-black record, which is careful that the two are
  **complementary, not alternatives**: a black source is **upstream**, so
  overlays, keys, and titles composite over it (cut the background to black and
  keep a lower third up), where FTB is a downstream master stage that obscures
  everything. TriCaster carries **BLACK** as a selectable source on its
  Program/Preview rows and ATEM the same on its M/E bus *while also* shipping
  FTB; Tingra now has FTB and still has no black source.

  **Shape:** a solid-colour generator in `TingraGeneratorPlugIns` beside bars
  and tone, bound into a layer like any other input — **no new seam, no new
  engine surface, and no document change**, which is what makes it small.

  **The blocker is gone, and it was the whole of the work.** This item was
  queued behind the layer-tree editor excluding `InputKind.generator` from its
  add-layer choices, on the grounds that `InputKind` cannot say whether a
  generator produces video or audio — and that protocol question, not the
  generator, was named as the real work. It was taken up first and separately
  (see "The `Input` media capability" above) and it landed: `EngineModel`'s
  add-layer choices now come from `videoInputs`, filtered on
  `media.contains(.video)`, and the Add Layer menu lists every video input,
  generators included. **Verified 2026-08-04** in code and in the running app.
  What remains is the generator itself, which the media record predicted would
  be the cheap part.

  **GLOSSARY.md needs no new entry — but this item's own name breaks the
  vocabulary rule.** **Generator** already reads "an input that synthesizes its
  content rather than capturing it: test patterns, color bars, **solids**,
  counters, placeholder frames", so a solid-colour generator is a thing the
  glossary already names and a "black source" entry would only duplicate it.
  The problem is the word *source*, which is on the "Words Tingra does not use"
  list with **input** as its replacement — the TriCaster/ATEM phrasing above is
  a boundary reference to those products' vocabulary, which is legitimate when
  describing *them*, but Tingra's own feature cannot be called a black source.
  It is a **black generator** (or a **solid generator**, if it takes a colour).
  Renaming this item is the fix; the title is kept here only so the queue stays
  searchable against the fade-to-black record that queued it.

  **Settled: BLACK-ONLY, registered `black`** — Larry's call 2026-08-04, taking
  a reversal of the previous session's colour-with-parameter recommendation.
  **The code decided it.** `Layer` carries an input, a frame, an opacity, and an
  effect chain and **has no per-layer parameter dictionary**, so a settable
  colour needs a new persisted document key — the one cost this item was scoped
  to avoid. Hanging the colour off the single registered instance is worse, not
  cheaper: every layer bound to it would share one value, so setting it in one
  shot silently changes every other shot using it. And **arbitrary solids
  already exist** — `Shot.background` is a full persisted RGBA defaulting to
  opaque black — so what was genuinely missing was never a colour but **a solid
  that can be stacked as a layer**. If white or grey are ever wanted, the shape
  is more registered generators beside this one: additive, no seam, no document
  change, no shared-mutable state.

  **Built as recorded, and it landed as small as promised.** One generator file
  (`BlackGenerator` + a private `BlackRenderer`), one line in `GeneratorPlugIn`,
  one `VideoGeneratorKind` case, and the docs. **It cost the app nothing**: the
  main window's second input row and the layer editor's Add Layer menu both come
  from `videoInputs` filtered on `media.contains(.video)` and sorted by name, so
  `black` appears in both the moment it is registered — the media capability's
  demonstration paying a second time. **GLOSSARY.md needed no entry** (see
  above), and the item's name changed from "black source" to "black generator"
  to stop breaking the vocabulary rule.

  **Two things worth keeping.** (1) **The fill runs every tick, not once**:
  `CVPixelBufferPool` recycles buffers and guarantees nothing about their
  contents, and the **alpha matters as much as the colour** — a layer
  composites with it, so a transparent "black" frame would reveal the layers
  beneath instead of hiding them. (2) **The CLI agreement test fired for the
  first time and in the direction it was built for**: it checks that every
  *registered* video generator is *offered* by `--video-generator`, so
  registering `black` without adding the enum case is a test failure rather
  than a silent gap — exactly the case the media-capability record said it
  existed to catch.

  **Verification.** `TingraGeneratorPlugIns` **37 → 46 tests in 7 suites**
  (a new `BlackGenerator` suite: tick/PTS pairing, working format, BT.709
  attachments, every pixel opaque black, all four corners, opacity across a
  long run including pool-recycled buffers, distinct buffer per frame,
  `stop()`, and identity/media), `tingra-cli` **85 tests** still green with the
  agreement test now covering `black`. The suite was **mutation-checked**:
  removing the fill makes it fail with 29 issues, so the tests have teeth
  rather than merely passing.

- [x] **The `Input` media capability** *(decided 2026-07-28, go-ahead given and
  built the same day; recorded in ARCHITECTURE.md, "The `Input` media
  capability", under Capture)*. Chosen as
  the next production iteration over the plug-in API 1.0.0 / bundle loader, a
  multiview output, and the `tingra-cli` version call, because it is the actual
  blocker under three separate queued things rather than a feature in its own
  right.

  **The problem is a modeling error, not a missing feature.** `InputKind` is a
  *provenance* category (what a thing is, and whether it captures or
  synthesizes); three places read it as a *media* category (what a thing
  produces) and survive only because camera→video and microphone→audio
  coincide. `generator` is where the two come apart, so today **tone can never
  become a channel strip and bars can never become a layer**, and a media-file
  input would ask the same question and get the same non-answer.

  **The shape:** one additive `var media: InputMedia` on `Input` — an
  `OptionSet` of `.video`/`.audio` — defaulting to `[]` (the only default
  consistent with the seam's existing already-finished `frames()`/`audio()`
  defaults), documented as a declaration of intent rather than a guarantee so a
  future network feed stays offerable. `InputKind` is untouched. In
  `TingraPlugInKit`, so the stability contract applies — but the package has
  **no first tag yet**, which is what makes this the cheapest moment it will
  ever have, and an argument for settling it *before* 1.0.0 rather than after.

  **Scope, deliberately narrow:** the seam, every first-party conformance
  (which the `[]` default makes mandatory in the same change), and the **three**
  app-side media-role filters — multiview tiles, the layer editor's add-layer
  choices, and the mixer's strip discovery. The camera/display/microphone
  **device pickers** stay on `kind`; an over-broad sweep of every `$0.kind ==`
  in the repo would be the wrong change. No JSON contract change (`devices`
  output is sectioned by kind already, and generators appear in neither
  listing), no `Codable` on `InputMedia`, and the CLI's hand-synced
  `VideoGeneratorKind`/`AudioGeneratorKind` enums stay — they give `--help` its
  value list — gaining a test that they agree with what the registry declares.

  **The demonstration is the point:** the moment it lands, bars/alignment/pluge
  become legal layers and tone becomes a strip, with **no new plug-in code** —
  which is why the black source above ships separately rather than bundled.

  **Built as recorded.** Six `media` declarations (four video generators, tone,
  and the three capture inputs) were the whole plug-in-side change; the app
  side is `microphones` → `audioInputs` plus a new `videoInputs`, both through
  one `mediaChoices(from:producing:)` helper that also **sorts by name** — the
  kind-based filters never did, so the add-layer menu had been in an order that
  could change between launches (`InputRegistry.allInputs` is
  dictionary-ordered). The `[]` default bit exactly once, and in test fixtures
  rather than production code, which is the case the `input.noMedia` diagnostic
  exists for.

  **The one real bug the iteration produced, and it was in the app, not the
  seam:** admitting audio generators to the strip roster also fed them to
  `MixerStrip.seed(from:)`, whose fallback unmutes the *first* strip — and
  unmuting **starts** the input. `440 Hz Tone` sorts ahead of every microphone
  by name, so a fresh project would have opened with a test tone live on the
  program mix and on any stream. Fixed by changing the seed's predicate rather
  than the ordering: it unmutes the first input whose kind is **not**
  `.generator`, and seeds everything muted when only generators are present.
  This is why `InputChoice` carries `kind` beside the media-filtered lists —
  the roster is a media question, "what should be live out of the box" is a
  provenance one. **General lesson: widening a filter is a policy change
  wherever a list's first element means something.**

  Tests: TingraPlugInKit 26 → 33, TingraHost 90 → 93,
  TingraGeneratorPlugIns 36 → 37, `apps/tingra` 115 → 123, `tingra-cli` 81 → 85
  — **772 across 13 targets**, warning-clean, `check-format` clean. *(The
  multi-channel microphone fix that landed in the same commit added two
  `tapFormat` cases to `TingraCapturePlugIns`, so the tree stood at 774 when
  this iteration closed.)*
  `integration-test.sh` **not** re-run: the streamed path is untouched
  (`StreamSession`, the pacer, and the providers all unchanged, and the CLI's
  generator resolution still goes through the same
  `resolveInput(selector:ofKind:)` call).

  **One build hazard worth remembering:** adding a member to a public protocol
  in `TingraPlugInKit` changes its module ABI, and SwiftPM's *incremental*
  build across path dependencies did not fully invalidate — TingraComposition
  reported three genuine-looking test failures, TingraAudio crashed with signal
  4, and TingraMCP failed to link (`CoreAudioTypes` not found). All three were
  stale artifacts: `rm -rf .build` and every one passed unchanged. When a seam
  in the protocol package changes, clean-build the dependents before believing
  a failure.

- [x] **The preview bus: the buses-and-monitoring slice, first iteration.**
  Decided 2026-07-26 (recorded in ARCHITECTURE.md, "The preview bus"),
  **go-ahead given and built the same day** — the decide-then-build rule the
  effect seam set. Step 8's two named deliverables are done and
  WHIP/WHEP is ungated on `RTCHaishinKit` leaving alpha, so the next slice is
  the one the 2026-07-19 monitoring ruling sequenced "after step 8": **buses and
  monitoring** (GLOSSARY.md). It closes the largest gap left — `Compositor` has
  exactly one bus (`programFrames()`) and `take(shotID:)` cuts straight to air,
  so the only way to check a shot today is to broadcast it, while GLOSSARY.md
  defines **preview** as core vocabulary ("the staging bus… Nothing on preview
  is visible to viewers") and ARCHITECTURE.md's "UI layer" already promises
  program/preview monitoring. This is closing a claim the docs already make.

  **The slice splits into three iterations; this decision covers only the first,
  the video preview bus.** Audio preview is not a sibling — it needs the
  engine's first audio *output* path (a monitoring device, headphone routing)
  plus post-fader master metering, and the engine today only mixes, never
  playing anything out. Multiview (tiling program, preview, and every input) is
  a third concern again. Bundling them would make the slice unshippable; each
  gets its own iteration and its own record.

  The approved shape, five decisions:
  - **A second render pass on the same tick, and free when unwatched.** Preview
    is a second `ShotRenderer` walk over the same tick's input slots — one
    clock, two buses, so CLOCK.md's "output pacing independent of inputs" holds
    unchanged and preview shares program's latest-wins snapshot rather than
    racing it. The pass runs **only when a preview shot is selected and a
    consumer is attached**, so a session nobody is previewing pays nothing.
  - **`take` promotes preview to program as a swap**, the console convention:
    what was on program lands on preview, ready to be taken back. Today's
    direct `take(shotID:transition:)` stays — the shot switcher's take-by-ID is
    the working path and is not being replaced — so the two coexist: select a
    shot into preview, then take it.
  - **Preview selection is session state, not persisted.** Nothing enters
    `Preset`/`Project`; **no document version bump** (the pre-release rule). It
    is the same call the mixer made for level/mute before routing landed —
    what is staged when the app quits is not part of the show.
  - **Transitions stay program-only.** A transition is the move *to air*; there
    is no such thing as transitioning on the staging bus, and the tick-counted
    `PendingTransition` spine is untouched.
  - **No engine event for preview selection** — it is a gesture-rate operator
    action, the `updateShot` rule; the app's `tap` events carry the
    observability. The bus keeps its existing control-plane vocabulary.

  **Built as recorded, with two facts worth keeping.** (1) The preview bus
  **added no `ShotRenderer` requirement** — it reuses the seam's existing
  plain `render(shot:frames:format:time:)`, so no conformer changed and the
  seam is no closer to a breaking edit than it was. (2) Staging needed **no
  reconfigure work**: `applyConfiguration()` already references every shot of
  the active preset, so a staged shot's inputs are running by construction.
  Two operations keep the staged id honest against the pool — `removeShot`
  empties preview when the removed shot was staged, and `loadPreset` keeps a
  staged shot only on an id match with the incoming preset. `ProgramPreviewView`
  became **`MonitorView`** (bus-agnostic over the relay it is handed): with
  "preview" now naming the staging bus, a `…PreviewView` rendering *program*
  read as exactly the wrong thing. Tests: TingraComposition 141 → 155 (a
  `The preview bus` block covering the second pass from both sides — staged
  but unwatched, watched but unstaged — the swap, the outside-the-pool empty,
  program-only blending, and both recoverable misses), `apps/tingra` 99 → 101
  (the per-control preview tap names) — **681 across 13 targets**,
  warning-clean, `check-format` clean, and `integration-test.sh` re-run green
  at **37 checks across 11 scenarios** (the streamed path is untouched: the
  CLI paces with `ProgramPacer`, not the compositor).
  **Audio preview and multiview remain** — the slice's other two iterations.
  *(The second was decided 2026-07-27 and renamed in the doing: it is **the
  monitor path**, not "audio preview" — see the entry at the top of this
  section and ARCHITECTURE.md, "The monitor path".)*

- [x] **The effect seam shape: one seam, two media protocols.** Decided
  2026-07-19 (recorded in ARCHITECTURE.md, "The effect seam"; **flagged for
  Larry's veto before any conformance code lands** — the seam joins the
  `TingraPlugInKit` stability contract, so the shape is settled before the
  build): one registration surface (`EffectRegistering`), identity model,
  provider/instance split (the `StreamingServiceProvider` pattern), and
  persisted parameter shape — with **two processing protocols**,
  `AudioEffect` (deinterleaved float32 blocks at the mix tick) and
  `VideoEffect` (`CIImage → CIImage`, so a chain fuses into one render
  pass), never one protocol straddling both (the recording-seam precedent).
  Chains persist as optional `effects` arrays on `AudioChannel` and `Layer`
  within v1; first-party effects land in a new `TingraEffectPlugIns`
  package as two iterations — audio chains first, then per-layer video.

- [x] **OSLog sink attachment in `tingra-cli`.** Decided 2026-07-04: skip
  attaching `OSLogSink` when standard error is a terminal, since macOS's own
  unified-logging terminal mirror already echoes the process's events there and
  attaching would double every line. Interactive runs lose nothing (the console
  sink already covers the human); non-interactive runs (scripts, launchd,
  redirected/piped output) keep OSLog as the system of record. Recorded in
  EVENTS.md, "OSLog sink"; a `tingra-cli`-level policy (`OSLogAttachment`), not
  a change to the sink itself.

- [x] **MCP implementation dependency.** Decided 2026-07-05 (recorded in MCP.md,
  "Implementation: a hand-rolled JSON-RPC layer", and CLAUDE.md's dependency
  paragraph): **hand-roll** the JSON-RPC/MCP layer in `packages/TingraMCP` rather
  than adopt the official `modelcontextprotocol/swift-sdk`. The SDK is
  license-compatible (Apache-2.0/MIT) and Swift 6 strict-concurrency clean, but
  it pulls SwiftNIO, swift-log, swift-system, and an SSE `eventsource` client
  transitively — a server-side stack for a Mac-only app, reintroducing the
  swift-log dependency EVENTS.md rejected by name. The v1 subset (newline-delimited
  JSON-RPC 2.0 over a UDS: `initialize`, `tools/list`, `tools/call`, one
  notification) is a few hundred lines behind the MCP/Control seam, must be
  documented for direct socket clients anyway, and stays fully under our
  strict-concurrency/warning-clean rules. Revisit the SDK behind the same seam
  if the protocol layer ever grows past comfortable hand-maintenance (Streamable
  HTTP, resource subscriptions, sampling).

- [x] **Sanction `swift-argument-parser` explicitly.** Done 2026-07-04: added to
  CLAUDE.md's sanctioned third-party dependency list (Apple-authored, effectively
  first party; confined to the CLI target, no seam required). CLI.md already
  committed to it.

- [x] **Finalize package names.** Approved as scaffolded (2026-07-03):
  `TingraEventBus`, `TingraPlugInKit`, `TingraHost` under `packages/`,
  `apps/tingra-cli`. Recorded in ARCHITECTURE.md "Repository structure" and
  CLAUDE.md "Project Structure".

- [x] **EventBusBasics identity — decided 2026-08-05** (recorded in EVENTS.md,
  "Package and porting notes"). **Keep the Tingra-named port**; do not evolve
  the shared personal `EventBusBasics` package upstream and depend on it.

  The scaffold started `TingraEventBus` as a port on the reading that the
  deltas were "generic enough to upstream later" — and they are, individually.
  What that framing missed is that there are no deltas *left*: the port
  replaced every implementation choice in the original (Combine →
  `AsyncStream`, `[String: Any]` → `[String: EventValue]`, unisolated class →
  `Sendable`, `Thread.callStackSymbols` → `#fileID`, `DateFormatter` →
  `FormatStyle`, one `EventBusLogger` → sinks behind a protocol, plus a new
  `domain` axis and a narrowing to macOS). What the two share is the pattern
  and the six group names, not code, so "upstream the diff" has no diff to
  apply — it would be a rewrite of `EventBusBasics` that breaks its existing
  consumers, since dropping `[String: Any]` and leaving Combine changes every
  call site.

  The cost on Tingra's side is the decisive one: it would convert a **zero
  dependency leaf package** into an external dependency of a public, notarized
  product whose CLAUDE.md sanctions exactly three third-party dependencies, and
  put a coordinated two-repository release in front of every plug-in API
  change. The SemVer/API-diff obligation lands on `TingraEventBus`, which is
  where CI already points it. A corroborating signal: `EventBusBasics` already
  exists in Dart as well as Swift, so the pattern is what travels between
  Larry's projects, not the package.

  **Not folded in:** porting the Swift 6 lessons *back* into `EventBusBasics`
  is worth doing and is that package's own work, on its own schedule, with no
  coupling to Tingra.

- [x] **Frame ownership rule for the `Input` seam.** Decided 2026-07-04: the draft
  rule stands — transfer at yield, one holder at a time, immutable after transfer
  — extended to audio buffers, with `CapturedFrame` and `CapturedAudio` as the
  only sanctioned `@unchecked Sendable` in the codebase. Permanent home:
  ARCHITECTURE.md, "Frame ownership across the `Input` seam"; the wrapper types
  restate it briefly. *(Flagged for Larry's veto in the step-2 summary before
  more work stacks on it.)*

- [x] **Stream-key retention policy in the daemon — decided 2026-08-05**
  (recorded in MCP.md, "Sessions and concurrency"). **Transient**, which
  ratifies the behavior the daemon already has rather than changing it.

  The item was raised as "MCP.md says keys pass through tool input into
  Keychain-backed secure storage, but not whether they persist." Reading the
  code first turned that premise around: **the daemon never writes a key to
  secure storage at all** — `TingraMCP` does not reference `SecureStorage`
  anywhere. A key arrives as `stream_start` input, becomes
  `RequestedDestination.streamKey`, is copied into each leg's
  `Destination(url:streamKey:)`, and is retained in `StreamCoordinator.Active`
  only because `stream_status` needs the leg list. `clear(id:)` drops it, and
  the run task calls that on **every** teardown path — stop, duration elapse,
  connection loss, and a start that never went live — not merely on the
  explicit stop. So the sentence in MCP.md was not vague about persistence; it
  asserted a Keychain write that does not happen, in the document that
  specifies the daemon.

  The policy is therefore what the code does, now stated: key required per
  `stream_start`, held for the session, released on every teardown path, never
  written to secure storage, and supplied again by the next call. Durable keys
  arrive with the destination model.

  **Why the app is deliberately the other way.** The app persists keys in
  secure storage keyed by destination id because an operator authors a
  destination once and returns to it — the secret belongs to a document with
  an owner. The daemon's caller is an agent already holding the key it passes,
  so persisting there would create a secret at rest with no owner and no
  lifecycle. The asymmetry is the decision, not an inconsistency to resolve
  later.

  Work: the MCP.md correction above, the lifetime stated on the three types
  that hold or drop the key (`RequestedDestination.streamKey`,
  `Active.destinations`, `clear(id:)`), and two regression tests —
  a stopped session is *forgotten entirely* (its `statusReport` throws, which
  is the observable form of "the legs are gone"; asserting `isStreaming`
  alone would pin only the flag), and a refused start retains nothing and
  leaves the coordinator usable rather than wedged. `TingraMCP` 56 → 58.

  **All four teardown paths are now tested** (`TingraMCP` 59 → 61). The two
  that are not an explicit stop — a duration elapse and a lost connection —
  were initially left to inspection because `clear(id:)` runs an actor hop
  *after* `stream.stopped` reaches the bus, so a test awaiting the event
  cannot know the release has landed. The fix was one seam rather than the
  controllable clock first imagined: **`waitForEnd(sessionId:)`, which awaits
  the session's run task** — `clear` runs inside that task, which is the same
  guarantee `stop(sessionId:)` already relied on, so the gap closes with no
  new timing machinery. The finishing clock elapses a duration at once, and
  `MockStreamingService.reportConnectionLoss()` plus `reconnectAttempts: 0`
  produces the accept-then-drop shape, so both run without a wall-clock wait.
  Each asserts release the same three ways through a shared helper: nothing
  streaming, the id resolving to nothing (so the legs holding the key are
  gone), and a fresh start accepted rather than refused. **Mutation-checked**
  — with `clear(id:)` neutered both report `isStreaming == false` violated
  and then "A stream is already active (session 'stream-af0e37ca')".

  **A window where a key was retained forever — found while reading, fixed
  2026-08-05 on Larry's go-ahead.** `start` installed `active` *after*
  `await gate.wait()`, while the run task's `clear(id:)` could run during
  that suspension. A session ending between emitting `stream.started` and the
  waiter resuming was therefore cleared before it was ever installed: the
  clear no-oped on a nil `active`, and the install then resurrected a dead
  session. The stream key stayed for the life of the daemon (contradicting
  the policy above), every later `stream_start` was refused as a conflict
  with a session that was over, and `isStreaming` stayed true so the
  idle-exit guard could never fire. The window was microseconds, but the
  shape that reaches it is documented: a destination that accepts the publish
  and drops it moments later (MediaMTX's bad-key behavior, SIMULATOR.md) with
  reconnect disabled.

  **The fix is the ordering, and it closes rather than narrows the window.**
  `active` is installed before the gate wait, and the failure path clears it
  (both clears are id-matched, so whichever runs second is a no-op). What
  makes it airtight is that **there is no suspension point between the run
  task's creation and the install**, so the run task cannot reach the actor
  until `start` suspends at the gate — by which time the install has
  happened. A session that goes live and ends inside that window is now
  simply already cleared, and stays that way: `stream_status`/`stream_stop`
  on the returned id report an unknown session, which is the defined answer
  for a session that is not active, with `stream.stopped` on the bus carrying
  the reason.

  **This one stays untested, and it is the only one that does.** Its race is
  decided by actor *scheduling* — whether the run task reaches the actor
  before the install — so any test would be timing-dependent, and a
  probabilistically-passing test is worse than none. Contrast the two races
  fixed around it, both of which are decided by the actor's own
  *serialization* and are therefore deterministic in outcome even when the
  winner varies: the concurrent-start hole below, and the teardown paths
  above. That distinction is the rule to apply next time — serialization is
  testable, scheduling is not. Regression cover here is the surrounding
  suite plus repeat runs (12× clean at the time of the change).

- [x] **A second `stream_start` hole in the same guard — found 2026-08-05
  while fixing the one above, fixed the same day.** The "one active stream"
  check read `active` at the top of `start`, but the next three statements
  (`makeDestinationLegs` and the two `resolve` calls) are `await`s. Two
  concurrent `stream_start` calls therefore *both* passed the check while
  `active` was still nil, both built a session, and both installed — the
  second overwriting the first. The first was then never stopped and never
  reachable: its destinations kept publishing, its stream key stayed retained
  under an id that resolved to nothing, and `stream_stop` could only take
  down the second. Distinct from the ordering gap above, and not fixed by it:
  installing early narrows the window to the resolution `await`s but cannot
  close it, because the conflict has to be rejected *before* the first
  suspension. Reachable because MCP.md contemplates many MCP sessions onto
  one engine, so two agents can call at once.

  **Fix:** a `startInProgress` flag claimed synchronously right after the
  check and released in a `defer`, with a second check testing it — so the
  one-active-stream rule covers the whole of startup rather than only its
  tail. The refusal names the situation rather than a session id, since the
  in-flight start has not minted one yet.

  **Tested, and mutation-checked** (`TingraMCP` 58 → 59): two concurrent
  starts must leave exactly one installed session, one `invalidArgument`
  refusal, and a survivor that is live and stoppable. With the claim disabled
  the test reports `started.count → 2` and the stop then reports *"No active
  stream has the id 'stream-072d297e' (the active stream is
  'stream-bf2c2514')"* — the orphaned session, reproduced exactly. Unlike the
  ordering gap, this race is decided by the actor's own serialization rather
  than by scheduling luck, which is why it takes a real test: whichever call
  wins, exactly one wins. Suite run 10× clean.

- [ ] **Bundled plug-in shipping next to a bare binary** (referenced from CLI.md
  "Distribution"). ARCHITECTURE.md settles the CLI era — first-party plug-ins are
  compiled in, registering through the same code path the external bundle loader
  will use. Open for when the loader ships: app bundle style layout, staying
  compiled in, or a plug-ins directory installed by the Homebrew formula.

- [x] **Error-identifier registry.** Decided 2026-07-04, before the first `--json`
  error event shipped: the registry lives in CLI.md ("Error identifiers", next to
  the exit codes); the shape is bare lowerCamelCase (`authorizationDenied`,
  `inputNotFound`, `inputAmbiguous`, `invalidArgument`, `pipelineError`,
  `connectionFailed`, `connectionLost`), append-only, never renamed or reused.
  Error events carry `identifier` + human `message` params. Swift constants:
  `ErrorIdentifier` in `TingraPlugInKit` under the stability contract, with a
  test pinning every raw value.

- [x] **The output registration seam.** Decided 2026-07-04 (recorded in
  ARCHITECTURE.md, "How HaishinKit is incorporated"): plug-ins register a
  `StreamingServiceProvider` — a factory keyed by destination URL scheme that
  creates a configured `StreamingService` per stream — through an `OutputRegistering`
  seam in the plug-in protocol package; the host's `OutputRegistry` conforms and
  arrives via `PlugInContext.outputs`, mirroring the input seam exactly. One
  provider per scheme; recording joins through the same seam at step 5.

- [x] **How recording fits the output seam.** Decided 2026-07-05 (recorded in
  ARCHITECTURE.md, "The output registration seam"): recording registers through
  the same `OutputRegistering` seam and lives in the same `OutputRegistry` as
  streaming — one registry, two provider kinds — but as a **narrower
  `RecordingService`/`RecordingServiceProvider` pair, not a "file"-scheme
  `StreamingServiceProvider`**. A recording has no `Destination` (no stream key),
  no `connectionLost`/reconnect (a write failure is terminal), and is resolved by
  the `--record` path's file extension (`mov`/`mp4`), not a URL scheme — because
  it runs *alongside* streaming rather than being the single scheme-resolved
  destination. Reusing `StreamingService` would carry a meaningless secret and
  drag the reconnect machinery onto a connectionless sink. `StreamSession` feeds
  both sinks the same rebased program media; the recording is finalized on every
  teardown path, and a mid-recording failure is reported (`recordingFailed`)
  without ending the stream.

- [x] **Recording MCP control.** Decided 2026-07-05 (recorded in MCP.md, "Tool
  surface", and CLI.md): **deferred.** `--record` ships on the CLI's `stream`
  only; the MCP tools gain no `record_start`/`record_stop` and `stream_start`
  gains no `record` option in step 5. Keeps the agent contract minimal until an
  agent needs recording (and until the daemon-writes-files-under-its-own-identity
  path is thought through); when it lands it is additive — a `record` field on
  `stream_start`'s input schema, reusing the same `RecordingService` — and
  `stream_stop` already promises to "finalize any recording," so the tool table
  is forward-compatible.

- [x] **How the program tick applies before composition exists.** Decided
  2026-07-04 (recorded in CLOCK.md, "The tick before composition exists"):
  tick-paced latest-wins, not capture-cadence pass-through — the host pacer
  restamps the latest video frame on each program tick (re-sending the previous
  frame across a stall), audio passes through at capture cadence with true
  host-time PTS. Keeps CLOCK.md design principle 2 (output pacing independent of
  inputs) true from v1 and makes the compositor a drop-in replacement at step 6.
  *(Flagged for Larry's veto in the step-3 summary before more work stacks on
  it.)*

- [x] **SRT stays at roadmap step 8 despite `srt://` in CLI.md's grammar.**
  Decided 2026-07-04: v1 ships RTMP/RTMPS only — ARCHITECTURE.md sequences SRT
  at step 8 ("core + RTMP first, SRT when added") and an RTMP-only build stays
  fully source (no prebuilt libsrt in the binary). `--url srt://…` still parses
  (the grammar is stable), but resolves no output provider and reports a clear
  `invalidArgument` error naming the roadmap step. CLI.md "Destination" notes the
  v1 scope. **Resolved 2026-07-24 — SRT landed (see the step-8 SRT record under
  "Roadmap progress").** The deferral's "stays fully source" rationale is
  retired: Tingra now ships the prebuilt libsrt xcframework (decision below).

- [x] **SRT ships the prebuilt libsrt; the key composes into `streamid`; no
  mid-stream loss push.** Decided/landed 2026-07-24 (roadmap step 8; recorded
  in ARCHITECTURE.md, "How HaishinKit is incorporated", and CLI.md,
  "Destination"/"Reconnect semantics"). Three calls, all as recommended and
  approved: **(a) accept the prebuilt libsrt** — SRT is table stakes, and one
  build configuration beats source-only purity; the xcframework is embedded and
  signed for notarization (CLI.md "Distribution" gains the libsrt step when the
  packaging recipe is next touched). **(b) `--key` → `streamid`** — appended
  when the SRT URL has no `streamid`, an `invalidArgument` when the URL already
  carries one (ambiguous), placed literally (no percent-encoding, matching
  HaishinKit's raw-split reader). **(c) frame rate counted from appends** — SRT
  exposes no `currentFPS`; bytes come from `SRTConnection.performanceData`.
  **Deferral (recorded, not a bug):** HaishinKit 2.x's SRT publish path exposes
  no mid-stream connection-loss push, so SRT reports start-time failures but not
  `connectionLost`; loss-driven SRT reconnect waits for either a HaishinKit
  surface that pushes the loss or a sanctioned liveness read — **never** a poll
  loop. SRT's own ARQ handles ordinary packet loss below this layer, so the gap
  is only the hard-timeout case.

- [x] **Multiple destinations: one program fanned out to N legs (design
  decided 2026-07-24, **veto cleared and built 2026-07-26**).** The rest of
  step 8. The design below was approved as recorded, with **two amendments
  settled at the veto** and one consequence worth knowing:
  - **Start is best effort, not all-or-nothing** (Larry's call, 2026-07-26,
    over the initial recommendation). Every leg is connected at start; a
    refused one is reported (`stream.destination.rejected`, identifier
    `connectionFailed`) and skipped while the rest go live; `run()` throws only
    when *every* leg is refused, so a single-destination session is unchanged.
    Refinement that falls out: a leg refused **at start does not enter the
    reconnect budget** (that governs mid-stream losses only), which keeps a
    one-destination run byte-identical to before — rejected, throw, exit 75, no
    retries — and avoids `stream.reconnecting` firing before a stream has ever
    connected.
  - **The CLI gets the surface too** (Larry's call, 2026-07-26): `--url` and
    `--key`/`--key-env` are repeatable, paired by position, zero keys or
    exactly one per URL, an unequal count a usage error naming both counts;
    `--key-stdin` stays single-destination. This is what makes fan-out testable
    end to end — `integration-test.sh` gained three scenarios that read *both*
    destinations back off the simulator.
  - **Consequence recorded, not a defect:** the last-live-leg rule inherits
    SRT's blind spot (the deferral above). An SRT leg never reports a
    mid-stream loss, so it counts as healthy for the whole run — a mixed
    RTMP + SRT run whose RTMP leg dies keeps going and exits 0 on the strength
    of an SRT leg that may already be dead. Recorded in CLI.md, "Reconnect
    semantics".
  - **Also surfaced by the build, now fixed:** CLI.md's SRT paragraph claimed
    `--reconnect` governs start-time retries. It never has, on any transport —
    `StreamSession.run()` calls `service.start(to:)` once and rethrows; the
    reconnect loop only runs after a mid-stream `connectionLost`. The clause is
    gone and the true rule is stated.

  The approved design, as built: **one `StreamSession`
  fanning the single tick-paced program out to N destination legs, not N
  sessions** — the program is already one stream with one `T0`; N sessions would
  each re-pick `T0` and carry different PTS per destination for no benefit, and
  encoder cost (one per destination) is identical either way. What changes:
  **(1) reconnect state becomes per-leg** — the attempt budget and stability
  window move from session-wide to leg-local, so one destination dropping never
  takes another down (the crux). **(2) status events gain a destination
  identity** — `stream.stats`/`stream.reconnecting`/`stream.reconnected` become
  per-leg, an additive `--json` field (stable-contract safe). **(3) the "one
  active stream" MCP contract survives, redefined as one session / N legs** —
  `stream_start` takes N destinations, still returns one session id;
  `stream_status` reports legs; `StreamCoordinator`'s shape and the idle-exit
  guard are unchanged (N concurrent sessions would break both). **(4) partial
  leg loss** — a run continues and exits 0 when at least one leg is healthy; a
  dead leg is reported (its budget exhausted) but does not end the run; exit 75
  only when the last live leg is lost (a `--json`/exit-code contract line for
  CLI.md). **Document:** add `Project.destinations: [ProjectDestination]?`,
  keep the single `destination` decode-only and fold it in as the first element
  (the `Preset.audioChannels` merge precedent — no version bump, pre-release
  rule); `ProjectDestination` grows a stable `id`, a user-facing `name`, and an
  `enabled` flag. **Secure storage:** stream keys are keyed by destination `id`,
  not URL — the current URL keying does not survive two destinations or a URL
  edit; a clean pre-release change (**no migration**: pre-release, an existing
  URL-keyed Keychain item is simply orphaned and the operator retypes the key
  once). Per-destination compression settings **remain deferred** to keep the
  first cut contained — every leg encodes with the run's settings, which also
  means fan-out costs one encoder per destination (the seam has no
  one-encode/N-muxer split to exploit). Full record in ARCHITECTURE.md,
  "Multiple destinations"; CLI.md, "Destination"/"Status events"/"Exit codes";
  MCP.md, "Sessions and concurrency".

- [x] **Reconnect stability window.** Decided 2026-07-05 (recorded in CLI.md,
  "Reconnect semantics"): a reconnected stream must survive 10 seconds before it
  counts as recovered; a loss inside the window is the same outage and keeps
  draining the `--reconnect` budget. Without it, a destination that accepts every
  publish and closes moments later — how services reject a bad stream key,
  MediaMTX included — would reconnect forever instead of exiting 75. The window
  is session policy (`StreamSession.Policy.stabilitySeconds`), not a CLI flag,
  until someone needs to tune it.

- [x] **`stream --dry-run` scope in v1.** Decided 2026-07-04 (recorded in
  CLI.md, "Dry run"): dry-run validates the full flag surface and resolves inputs
  against the registry, but performs no network I/O, no TCC authorization check
  (checking would be the first prompt-triggering step on some paths, and
  authorization belongs to `start()`), and never reads the stream key
  (`--key-stdin` is validated for exclusivity only). Syntactic/cross-flag failures
  are argument-parser usage errors (exit 64, stderr); only registry resolution
  failures flow through the bus as `error` events with identifiers (exit 69).
  `--record` is excluded from the surface until roadmap step 5 adds it.

- [x] **Where the compositor lives.** Decided 2026-07-06 (recorded in
  ARCHITECTURE.md, "Repository structure" and "Composition"): a new
  `packages/TingraComposition`, a **host-side engine library** (a sibling of
  `TingraHost`, depending only on `TingraPlugInKit` + `TingraEventBus`), not a
  plug-in and not folded into `TingraHost`. It is not a plug-in — effects and
  transitions plug *into* it — but it is also a large, distinct concern
  (renderer, layer tree, shots) that would bloat the minimal host; the
  protocol-package-only dependency keeps it testable in isolation with a
  synthetic clock and a mock renderer, exactly like the generator plug-ins. The
  CLI's single-input `StreamSession` keeps using `ProgramPacer` for now; wiring
  the compositor into the stream path is a step-7 concern (multi-input streaming),
  so step 6 leaves the shipped CLI path untouched.

- [x] **Composition renderer technology.** Decided 2026-07-06 (recorded in
  ARCHITECTURE.md, "Composition"): the compositor renders through an internal
  `ShotRenderer` seam whose default is a **Metal-backed Core Image** renderer
  (`CoreImageShotRenderer`) — hand-written Metal shaders wait for the
  effects/transitions step where custom work demands them (ARCHITECTURE.md already
  sequenced it this way). The seam is created and used task-confined (like
  `BarsRenderer`), so it needs no `Sendable`/`@unchecked Sendable`, and a
  software `CIContext` makes the compositing math (placement, Y-flip, opacity,
  tagging) deterministically unit-testable with no GPU.

- [x] **The compositor renders a live canvas from the first tick.** Decided
  2026-07-06 (recorded in CLOCK.md, "The program tick"): unlike the single-input
  `ProgramPacer` (which sent nothing before the first frame arrived), the
  compositor renders on every tick once started, showing the shot's background
  before any input delivers. A broadcast program is always live at the tick rate;
  this is the layer-tree generalization of the pacer's rule, not a departure from
  it, and design principle 2 (output pacing independent of any input) still holds.

- [x] **`InputKind.display` + a separate ScreenCaptureKit plug-in.** Decided
  2026-07-06 (recorded in ARCHITECTURE.md, "Capture"): displays are a new
  `InputKind.display` (a pre-1.0 additive case) contributed by a **separate
  `ScreenCaptureKitCapturePlugIn`**, not folded into `AVFoundationCapturePlugIn`
  — a different framework and a different TCC permission (Screen Recording, not
  Camera), matching the capture-services split. Discovery reads CoreGraphics (no
  Screen Recording prompt; stable `CGDisplayCreateUUIDFromDisplayID` identifiers
  that survive reconnection), capture uses `SCStream`. Displays are not yet in
  the CLI's `devices` listing — they are an app-era surface (CLI.md non-goals);
  the CLI still loads only the AVFoundation plug-in.

- [x] **Phase-3 app scaffolding shape.** Decided 2026-07-06: `apps/tingra` is
  scaffolded as an **SPM executable** (SwiftUI `@main`, an `@Observable
  @MainActor` engine model, an `MTKView` preview), building warning-clean under
  `swift build`. Bundling it into a signed, notarized `.app` with an embedded
  Info.plist (Camera/Microphone usage descriptions, Screen Recording) is deferred
  packaging, tracked alongside the CLI's distribution recipe (CLI.md,
  "Distribution") — the same "packaging is a later gate" posture the CLI takes.

## CI follow-ups

Jobs promised in CLAUDE.md "Toolchain & CI" that were deliberately left out of
the first `.github/workflows/ci.yml` because their prerequisites don't exist yet.
Each lists its trigger condition:

- [x] **Integration-test job** against the local ingest simulator (SIMULATOR.md)
  — added 2026-07-05 as `.github/workflows/integration.yml`, a separate workflow
  running `scripts/integration-test.sh` on streaming/output path changes (plus
  `workflow_dispatch`), not blocking every PR.

- [x] **Packaging job** (Developer ID signing, hardened runtime, notarization,
  zip + stapled `.pkg`) — added 2026-07-09 as `.github/workflows/packaging.yml`,
  a tag-triggered release job that builds and verifies unsigned without secrets
  and signs + notarizes + attaches to the release with them (CLI.md
  "Distribution"). *(Checkbox corrected 2026-07-26: this had been left unticked
  while the "Release mechanics" entry below recorded the same workflow as
  landed, and `v0.1.0` shipped through it — signed, notarized, and installable
  from the tap. It was never the outstanding gate it read as.)*

- [ ] **API-diff job** (`swift package diagnose-api-breaking-changes` on
  `TingraPlugInKit` and `TingraEventBus`) — add when those packages get their
  first tag; the check diffs against the latest tag, so it has nothing to
  compare until then.

## De-risking

- [x] **HaishinKit seam spike, before roadmap step 3 work stacks up.** The "clean
  seam" story rests on the assumption that HaishinKit 2.x accepts externally
  produced video buffers and audio with Tingra's PTS, compresses internally, and
  honors that timeline without its `MediaMixer`. A half-day throwaway spike (bars
  generator → HaishinKit → MediaMTX, verify with `ffprobe`) validates the append
  API before capture and composition work stacks on top of it.

  **Findings (verified 2026-07-04, HaishinKit 2.2.5 + MediaMTX v1.19.2; spike
  deleted after):** the seam holds. Bars + tone appended to a bare `RTMPStream`
  (no `MediaMixer`) with session-timeline PTS (`hostTime − T0` per CLOCK.md)
  arrived at MediaMTX as H.264 + AAC-LC; the `ffprobe` readback showed exactly
  30 fps with 33.3 ms PTS deltas — the external timeline is honored and
  compression happens inside HaishinKit (VideoToolbox). Three facts the output
  plug-in builds on:

  1. **Video** enters as an uncompressed `CMSampleBuffer` (wrapping the
     `IOSurface`-backed pixel buffer) via `append(_:)`; its PTS survives through
     the encoder — the RTMP track's timestamps are the deltas of ours.

  2. **Audio must enter as `AVAudioPCMBuffer` + `AVAudioTime`** (host time carries
     the PTS): HaishinKit's `append(CMSampleBuffer)` audio path handles only
     pass-through PCM output and **silently drops LPCM when the output codec is
     AAC** — so the plug-in converts `CapturedAudio`'s sample buffer at the seam.
     After the first buffer anchors the audio timeline, HaishinKit extrapolates
     from the accumulated sample position (micro drift between the audio and host
     clocks is flattened inside the library; the seam still passes true host
     times, so a future implementation can preserve them).

  3. **RTMP timestamps are per-track deltas** baselined at each track's first
     buffer (`RTMPTimestamp`), so an initial A/V offset smaller than one buffer
     duration is absorbed at session start; both tracks must simply start
     promptly at `T0`.

  The default H.264 profile is Baseline — the implementation sets the profile,
  keyframe interval, bitrate, and expected frame rate explicitly through
  `VideoCodecSettings`/`AudioCodecSettings`.

## Release mechanics

- [x] **Ship the launchd LaunchAgent for the daemon** (`serve --install/--uninstall`,
  label `com.moonwink.tingra.serve`) *(code complete 2026-07-09)*. `serve --install`
  writes/loads `~/Library/LaunchAgents/com.moonwink.tingra.serve.plist`
  (`launchctl bootstrap gui/$UID`), `--uninstall` reverses it, and `serve` under
  launchd adopts the socket via `launch_activate_socket` (the `CTingraLaunchd` C
  shim → `LaunchdSocket.activate()`), falling back to manual mode otherwise.
  Types: `LaunchAgent`, `LaunchAgentError`, `LaunchdSocket` in `TingraMCP`; 6
  unit tests pin the plist shape and the manual-mode fallback. The TCC-attribution
  rationale and the plist design are in MCP.md, "Lifecycle".

- [x] **Packaging pipeline for `tingra-cli`** *(2026-07-09)*: the embedded
  `__TEXT,__info_plist` section (via `Package.swift` linker flags over
  `apps/tingra-cli/Info.plist`, carrying the bundle id, version keys, and
  Camera/Microphone usage descriptions), the signing entitlements
  (`apps/tingra-cli/tingra-cli.entitlements`), `scripts/package-cli.sh` (release
  build → Developer ID sign + hardened runtime → verify identity/entitlements/plist
  → notarized zip + stapled `.pkg` → sha256), the Homebrew formula template
  (`packaging/homebrew/tingra-cli.rb` + `packaging/README.md`), the
  `.github/workflows/packaging.yml` release job (tag-triggered; builds/verifies
  unsigned without secrets, signs+notarizes+attaches to the release with them),
  and `scripts/release.sh` — the one-command local release (build → tag →
  `gh release create` → render the formula into the tap and push).

- [x] **Define the product versioning scheme** *(decided 2026-07-09, recorded in
  CLI.md "Distribution" and `Version.swift`)*: product releases tag
  `v<MAJOR>.<MINOR>.<PATCH>`; `tingra-cli version` prints the number (no `v`),
  kept in sync with the embedded Info.plist and asserted by `package-cli.sh`.
  The plug-in protocol package and the event bus SemVer independently under
  prefixed tags (`plugin-kit-<x.y.z>`, `event-bus-<x.y.z>`) so the API-diff job
  pins the right baseline. Between releases `main` carries the next version with
  a `-dev` suffix. First tester release: `0.1.0`.

- [x] **Create the Homebrew tap repo** `larryaasen/homebrew-tingra` *(done
  2026-07-11)* — lives outside the monorepo; holds `Formula/tingra-cli.rb` + a
  `README.md` (with a Claude Desktop/Code verify step). First release `v0.1.0`
  shipped: signed + notarized zip and `.pkg` attached to the GitHub release,
  formula sha256 verified against the uploaded zip,
  `brew install larryaasen/tingra/tingra-cli` working. `scripts/release.sh`
  renders + pushes the formula per release.

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

- [x] **Decided 2026-07-11: `Tingra.app` bundles the CLI — one Homebrew cask,
  not a separate formula + cask.** Homebrew splits **formulae** (CLI/libs into
  the prefix) from **casks** (GUI `.app` bundles into `/Applications`);
  `tingra-cli` is a formula today. At phase 3, `Tingra.app` ships `tingra-cli`
  inside it (e.g. `Contents/MacOS/tingra-cli`), and the cask (`brew install
  --cask tingra`) symlinks the binary onto the `PATH` — one install gives both
  the app and a working `tingra-cli`/`tingra-cli mcp`, and the daemon is
  naturally associated with the app bundle (resolving the item above). The
  existing `larryaasen/homebrew-tingra` formula stays as the headless/server/CI
  install path (no `Applications`, no GUI) rather than being removed; it just
  stops being the only path. Implementation (deferred to phase 3): fold
  `apps/tingra-cli`'s build output into the `Tingra.app` bundle step
  (`scripts/run-app.sh`/`sign-app.sh` territory), add the cask to the tap, and
  decide whether the formula rebuilds from the same signed CLI binary the app
  embeds or is packaged independently (`scripts/package-cli.sh` as today) —
  leaning toward the latter so the formula has no app-bundle dependency.

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
  existing packaging pipeline (`scripts/package-cli.sh`/`release.sh`). Worth
  revisiting once `Tingra.app` exists (previous item) — the extension could point
  at the app-bundled CLI rather than a separate artifact. Not started; a real
  scoped project, not a quick add.

- [x] **Verify GitHub Actions macOS runners offer Xcode 26.6** before CI lands —
  runner images lag Xcode releases. Verified 2026-07-04: the `macos-26` arm64
  image (version 20260630.0213.1) ships Xcode 26.6 (17F113) alongside
  26.0.1–26.5, but defaults to 26.5 — so `.github/workflows/ci.yml` runs on
  `macos-26` and pins `DEVELOPER_DIR` to `/Applications/Xcode_26.6.app` rather
  than relying on the image default.

## Generator plug-ins

Issues found in a 2026-07-07 review of `packages/TingraGeneratorPlugIns` (see
GeneratorPlugIn.swift and the Bars/Alignment/Pluge/Tone generators). All three
fixed together on 2026-08-06.

- [x] **Synthesis failures are silently dropped, never reported** *(fixed
  2026-08-06)*. `CVPixelBufferPoolCreate`, `CVPixelBufferPoolCreatePixelBuffer`,
  `CMAudioFormatDescriptionCreate`, and the `CMBlockBuffer`/`CMSampleBuffer`
  calls all discarded their `OSStatus` and returned nil, skipping the frame or
  buffer (correctly, per ARCHITECTURE.md — a generator problem must never take
  down the pipeline) with nothing on the bus, so a persistently broken generator
  produced zero output and no signal: a hang, not a reported failure.

  The reporting rule was **settled in EVENTS.md before any code** ("Reporting a
  repeating failure"), because the naive fix collides head-on with principle 3:
  a failure on the frame path repeats every tick, so reporting occurrences is
  exactly the flood the control-plane rule forbids. The rule reports the
  **episode** instead — one `error` (`generator.stalled`) on the first tick that
  produces nothing, one `event` (`generator.resumed`) on the first tick that
  recovers, carrying the count of ticks lost. Two events per episode however
  long it runs; an episode that never resolves emits its one error and the
  missing resume line is the standing signal. A second cause inside an open
  episode is deliberately not re-reported — that would reopen the unbounded
  case. The rule is written generically for any tick-paced producer, not for
  generators specifically.

  Implementation: a typed `GeneratorSynthesisFailure` (internal — it reaches the
  world only as `reason` and `status` params, never as API) that every renderer
  now throws instead of returning nil, carrying the framework status the call
  actually returned; `StallReporter`, which holds the episode state and is
  task-local because the failing resource belongs to one consumer's renderer;
  and `GeneratorPixelBufferPool`, which exists so a pool refused in a renderer's
  initializer — where there is nothing to report to yet — can still say *why* on
  the first tick that skips. Every generator gained an optional `eventBus:`
  parameter, matching `MicrophoneInput`'s existing idiom.

- [x] **`GeneratorPlugIn.activate` has no rollback on partial registration**
  *(fixed 2026-08-06)*. Registration is now all or nothing: the identifiers that
  landed are unregistered in reverse before the error propagates, and the
  rollback is itself reported (`input.registrationRolledBack`) so the loader's
  error is not the only record that something half-activated. Rollback cannot
  mask the original error — `InputRegistering.unregister` is non-throwing and
  removing an unregistered identifier is harmless by contract.

- [x] **`BarsRenderer.timecode(at:)`'s hours modulus** *(settled 2026-08-06:
  `% 24`)*. It used `% 100`. A two-digit hours field in `HH:MM:SS:FF` has one
  established meaning — SMPTE 12M — and wrapping at 100 matched neither that nor
  a true elapsed run time; it just moved the wrap to a point no reader expects.
  A run longer than a day is a legitimate thing to want to see, but it wants a
  display that says so. Extracted as `BarsTimecode.string(at:frameRate:)` — pure,
  so the wraparound is verifiable without drawing a frame.

  Tests: `TingraGeneratorPlugIns` 46 → 77 (the new `StallReporter`,
  `GeneratorSynthesisFailure`, coordinator-stall, rollback, and timecode suites)
  — **874 across 13 targets**, warning-clean, format clean. The stall path is
  covered by a scripted renderer through `GeneratorStreamCoordinator`, since a
  real Core Video allocation failure is the one condition a unit test cannot
  arrange on demand — which is why this went unreported as long as it did.
  `integration-test.sh` not re-run: the generators' output path is unchanged on
  every tick that succeeds, which is every tick the simulator ever sees.

## Housekeeping

- [ ] **Commit the doc baseline** (the full doc set plus the LICENSE change is
  staged but uncommitted) so scaffolding diffs cleanly.

- [x] **Fix the dangling "the Tingra plan" references in CLI.md** ("decided in
  the Tingra plan", "tracked in the plan") — done 2026-07-04: the pre-repo
  planning document is never referenced from this repo (rule recorded in
  CLAUDE.md "Documentation"); the two sentences now point at MCP.md and this
  file's "Decisions to settle".
