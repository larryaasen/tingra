# TODO

Open decisions and roadmap progress. The authoritative step sequencing is
ARCHITECTURE.md, "Roadmap sequencing"; the progress section here tracks where
the work actually stands. Decision items (below) should each end as a sentence
or two in the doc that owns them — none need a rewrite.

## Roadmap progress

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

- [ ] **Steps 7–8** — app era: production features (presets, shots, layers,
  transitions, audio mixer), SRT/multiple destinations.
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

- [ ] **EventBusBasics identity.** Decide: evolve the shared personal
  `EventBusBasics` package upstream, or keep the Tingra-named port. The scaffold
  starts `TingraEventBus` as a port; the deltas in EVENTS.md are generic enough
  to upstream later. The SemVer/API-diff CI obligation from ARCHITECTURE.md lands
  on whichever package wins.

- [x] **Frame ownership rule for the `Input` seam.** Decided 2026-07-04: the draft
  rule stands — transfer at yield, one holder at a time, immutable after transfer
  — extended to audio buffers, with `CapturedFrame` and `CapturedAudio` as the
  only sanctioned `@unchecked Sendable` in the codebase. Permanent home:
  ARCHITECTURE.md, "Frame ownership across the `Input` seam"; the wrapper types
  restate it briefly. *(Flagged for Larry's veto in the step-2 summary before
  more work stacks on it.)*

- [ ] **Stream-key retention policy in the daemon.** MCP.md says keys pass through
  tool input into Keychain-backed secure storage, but not whether they persist.
  Recommendation: transient in v1 (key required per `stream_start`, deleted when
  the stream stops); persistence arrives with the destination model. One sentence
  in MCP.md.

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
  v1 scope.

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

- [ ] **Packaging job** (Developer ID signing, hardened runtime, notarization,
  zip + stapled `.pkg`) — add when the release tooling and signing secrets exist
  (CLI.md "Distribution"; the last gate before `tingra-cli` v1 actually ships).

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
GeneratorPlugIn.swift and the Bars/Alignment/Pluge/Tone generators).

- [ ] **Synthesis failures are silently dropped, never reported.**
  `CVPixelBufferPoolCreate` (now in `GeneratorPixelBuffer.makePool`),
  `CVPixelBufferPoolCreatePixelBuffer`, `CMAudioFormatDescriptionCreate`, and
  the `CMBlockBuffer`/`CMSampleBuffer` calls in `BarsRenderer`, `AlignmentRenderer`,
  `PlugeRenderer`, and `ToneSynthesizer` all discard their `OSStatus`/failure and
  just return nil, skipping the frame or buffer (correctly, per ARCHITECTURE.md
  — a generator problem must never take down the pipeline). But nothing reports it
  as an `error` event on the bus (EVENTS.md), so a persistently failing generator
  (e.g., pool exhaustion) would silently produce zero output with no diagnosable
  signal — it would look like a hang rather than a reported failure.

- [ ] **`GeneratorPlugIn.activate` has no rollback on partial registration.** If
  any generator in its array throws from `context.inputs.register(_:)` partway
  through the loop (e.g., a duplicate identifier), the generators registered
  earlier in the same call stay registered while the rest are never attempted.
  The host's loader reports the throw as an `error` event and keeps running, but
  the partially-registered state persists silently.

- [ ] **Confirm `BarsRenderer.timecode(at:)`'s hours modulus.** It uses `% 100`
  for the hours component rather than the conventional `% 24` for burned-in
  `HH:MM:SS:FF` timecode. Confirm whether supporting runs beyond 24 hours is
  intentional, or whether it should match standard SMPTE timecode wraparound.

## Housekeeping

- [ ] **Commit the doc baseline** (the full doc set plus the LICENSE change is
  staged but uncommitted) so scaffolding diffs cleanly.

- [x] **Fix the dangling "the Tingra plan" references in CLI.md** ("decided in
  the Tingra plan", "tracked in the plan") — done 2026-07-04: the pre-repo
  planning document is never referenced from this repo (rule recorded in
  CLAUDE.md "Documentation"); the two sentences now point at MCP.md and this
  file's "Decisions to settle".
