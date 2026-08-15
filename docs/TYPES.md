# Tingra Types

Every public type in the Tingra monorepo, package by package, each with a
one-liner saying what it is and why it exists. It is an index, not an API
reference: the authoritative documentation for a type is its `///` doc comment
in the source, and the design behind each piece is in
[ARCHITECTURE.md](ARCHITECTURE.md).

[README.md](../README.md) says what each package and app *is*; this file says
what is *in* it. The order matches the README's, and the two are updated
together — a type added, renamed, or removed lands here in the same change as
the code.

Apps expose no public API beyond their entry point, so their entries list the
internal surface a reader needs to navigate the target instead.

## `packages/TingraEventBus`

- `EventBus` — publishes structured events to subscribing sinks; includes
  per-group conveniences (`app`, `error`, `event`, `network`, `tap`, `trace`).
- `EventBusEvent` — one structured event: date, group, domain, name, params,
  and the emitting call site.
- `EventGroup` — the closed routing axis: what kind of event it is (`app`,
  `error`, `event`, `network`, `tap`, `trace`).
- `EventDomain` — the open attribution axis: which engine service or plug-in
  emitted the event.
- `EventValue` — a small `Sendable`, `Codable` param value (string, int,
  double, bool) that serializes as a bare JSON value and renders as bare
  text in human formats.
- `EventSink` — the subscriber protocol every sink conforms to;
  `EventBus.attach(_:)` runs a sink over its own stream, and
  `EventBus.shutdown()` drains all sinks at orderly teardown.

## `packages/TingraPlugInKit`

- `Input` — the protocol for anything producing video or audio frames: cameras,
  displays, microphones, media, generators; carries the stable identifier,
  user-facing name, kind, and declared media that discovery lists, with
  `frames()` and `audio()` streams (each defaulting to an already-finished
  stream for the media the input does not produce).
- `InputID` — the stable identifier for an input, as surfaced by input
  discovery.
- `InputKind` — the kind of input (camera, microphone, display, generator) —
  its *provenance* — driving discovery grouping and selector resolution.
- `InputMedia` — the media an input produces (`.video`, `.audio`, both, or
  neither): the *media* axis beside `InputKind`'s provenance axis, and what
  decides whether an input is offered as a layer, a channel strip, or a
  multiview tile. Defaults to empty, and is a declaration of intent rather
  than a guarantee (ARCHITECTURE.md, "The `Input` media capability").
- `InputRegistering` — the registration seam where input plug-ins attach
  (register on connect, unregister on disconnect); the host's `InputRegistry`
  conforms.
- `CapturedFrame` — one GPU-resident video frame plus its presentation time on
  the master clock; `@unchecked Sendable` under the frame ownership rule
  (ARCHITECTURE.md, "Frame ownership across the `Input` seam").
- `CapturedAudio` — one captured audio buffer whose PTS is the actual host
  time of capture; the audio half of the frame ownership rule.
- `ErrorIdentifier` — the stable, machine-readable failure identifiers error
  events carry (`inputNotFound`, `authorizationDenied`, `recordingFailed`, …);
  the registry lives in CLI.md, and identifiers are append-only, never renamed.
- `StreamingService` — the output seam: connects, appends program media on the
  shared session timeline, reports connection events, and stops (HaishinKit
  lives behind this protocol).
- `StreamingServiceProvider` — what an output plug-in registers: a factory
  keyed by destination URL scheme that creates a configured
  `StreamingService` per stream.
- `StreamingServiceEvent` — a connection event reported after a successful
  start (`connectionLost`); the session drives reconnect policy from it.
- `StreamingServiceError` — the error currency of `StreamingService.start(to:)`
  (`unsupportedDestination`, `connectionRejected`), each mapped to its stable
  error identifier.
- `StreamingStatistics` — a point-in-time snapshot of a service's delivery
  counters, feeding the periodic `stream.stats` events.
- `StreamConfiguration` — the compression and program settings a stream session
  runs with (resolution, frame rate, codecs, bitrates, and the
  `includesVideo`/`includesAudio` track topology the recording sink needs up
  front); contains no secrets. Shared by the streaming and recording sinks.
- `OutputID` — the stable identifier for a registered output (streaming or
  recording).
- `OutputRegistering` — the registration seam where output plug-ins attach —
  both streaming (by URL scheme) and recording (by file extension) providers;
  the host's `OutputRegistry` conforms.
- `Destination` — a configured streaming target: URL plus optional stream key
  (deliberately not `Codable` — the key is a secret).
- `RecordingService` — the recording seam: opens a local file, appends the same
  program media the stream gets, reports a terminal write failure, and
  finalizes (`AVAssetWriter` lives behind this protocol). A narrower sibling
  of `StreamingService` — no destination, no reconnect.
- `RecordingServiceProvider` — what a recording plug-in registers: a factory
  keyed by file extension (`mov`/`mp4`) that creates a configured
  `RecordingService` per recording.
- `RecordingServiceEvent` — a recording event reported after a successful start
  (`failed`); a file has no reconnect, so a write failure is terminal.
- `RecordingServiceError` — the error currency of `RecordingService.start(to:)`
  (`unwritableDestination`, `writerNotReady`), each mapped to the
  `recordingFailed` identifier.
- `RecordingFile` — where a recording is written: a local file URL plus its
  container format (`mov`/`mp4`); the recording counterpart to `Destination`,
  carrying no secret.
- `EffectID` — the stable identifier for a registered effect, shared by the
  audio and video sides; what a persisted chain entry names.
- `EffectConfiguration` — one effect as a document persists it: its `EffectID`
  plus its parameter payload. A chain persists as an ordered list of these
  (order is signal order); an entry naming an effect this build has no
  provider for survives the round trip untouched.
- `EffectParameter` — one adjustable parameter an effect declares (key, name,
  range, default, unit, linear/logarithmic scale), so a host draws a control
  for a third-party effect without knowing it exists.
- `AudioEffect` — one audio processing step in a channel strip's chain,
  processing the mixer's native currency (deinterleaved float32 blocks at the
  mix rate) in place at the mix tick.
- `AudioEffectProvider` — what an effect plug-in registers for an audio
  effect: identity, declared parameters, and a factory creating one
  `AudioEffect` instance per chain slot.
- `VideoEffect` — one video processing step in a layer's chain, processing the
  renderer's native currency (`CIImage → CIImage`) so a whole chain fuses into
  one render pass.
- `VideoEffectProvider` — the video counterpart of `AudioEffectProvider`.
- `EffectRegistering` — the registration seam where effect plug-ins attach —
  one seam, two media protocols; the host's `EffectRegistry` conforms.
- `IdentifiedError` — the protocol the engine's error enums
  (`StreamingServiceError`, `RecordingServiceError`, `CaptureInputError`,
  `InputSelectorError`) conform to, so a front end maps any of them to its
  stable `ErrorIdentifier` without knowing the concrete type.
- `Tool` — the MCP tool seam: a control the engine exposes to agents, with a
  machine name, a JSON-Schema input, and a `call(_:)` returning structured
  JSON; plug-in contributed like inputs and outputs.
- `ToolError` — a structured, actionable tool failure keyed off the append-only
  `ErrorIdentifier` registry (never message wording).
- `ToolRegistering` — the registration seam where tool plug-ins attach; the
  host's `ToolRegistry` conforms.
- `JSONValue` — an arbitrary JSON value (the currency of the tool seam):
  scalars, arrays, and objects, encoding as natural JSON; more general than
  the event bus's scalar-only `EventValue`. Reads through `objectValue`,
  `arrayValue`, `stringValue`, `intValue`, `doubleValue`, and `boolValue`.
- `EngineClock` — the master clock seam: current time and the absolute-deadline
  tick stream (see [CLOCK.md](docs/CLOCK.md)).
- `PlugIn` — the protocol every plug-in conforms to: identity plus an
  activation hook for registering capabilities.
- `PlugInID` — the stable reverse-DNS identifier for a plug-in; doubles as its
  event domain.
- `PlugInContext` — the host infrastructure handed to a plug-in at activation:
  the event bus, the clock, and the input, output, effect, and tool
  registration seams.

## `packages/TingraHost`

- `HostClock` — the production `EngineClock`: the host time clock with a
  `ContinuousClock`-based absolute-deadline tick loop.
- `InputRegistry` — the actor where input plug-ins register the inputs they
  contribute and the engine resolves them from (by stable ID, listing index, or
  unique name substring via `resolveInput(selector:ofKind:)`); the host's
  concrete `InputRegistering`. Given the event bus, it reports an input that
  declares no `InputMedia` as an `error` event rather than refusing it.
- `InputRegistryError` — errors thrown by the registry (e.g. registering a
  duplicate input identifier).
- `InputSelectorError` — selector resolution failures (`notFound`,
  `ambiguous`), each mapped to its stable error identifier.
- `PlugInLoader` — the host's plug-in lifecycle: activates plug-ins against a
  `PlugInContext`, reporting each outcome on the event bus; a throwing plug-in
  is skipped, never fatal.
- `OSLogSink` — the system-of-record sink: routes every event to OSLog
  (`subsystem` `com.moonwink.tingra`, `category` = domain), params `.private`.
  `tingra-cli` skips attaching it when standard error is a terminal — the OS's
  own terminal mirror already echoes the process's events there (see EVENTS.md,
  "OSLog sink").
- `LogLineFormatter` — the one shared human log line format (`LEVEL MM-DD-YYYY
  HH:MM:SS.mmm TZ [SSSS] @ domain name key=value`), reused by every text sink
  so each front end logs identically — the CLI's console (human mode) and file
  sinks and the app's console sink (see EVENTS.md, "The human log line format").
- `LogSession` — the four-digit log session id stamped into every log line:
  incremented once per cold start and persisted in Application Support, a
  reliable cold-start anchor (distinct from the engine session in GLOSSARY.md).
- `OutputRegistry` — the actor where output plug-ins register their providers —
  streaming (resolved by destination URL scheme) and recording (resolved by
  file extension) — in one registry; the host's concrete `OutputRegistering`.
- `OutputRegistryError` — errors thrown by the output registry (a scheme, or a
  recording file extension, already served by another provider).
- `EffectRegistry` — the actor where effect plug-ins register their audio and
  video effect providers and the engine resolves a persisted chain entry's
  `EffectID` from; one registry, separate tables per media kind, registration
  order preserved for stable effect menus. The host's concrete
  `EffectRegistering`.
- `EffectRegistryError` — errors thrown by the effect registry (an audio or
  video effect id already registered).
- `ProgramPacer` — the tick-paced latest-wins video pacing for the CLI era:
  one frame per program tick, restamped with the tick's time, re-sending the
  held frame across an input stall (see CLOCK.md, "The tick before composition
  exists").
- `StreamSession` — one live stream fanned out to **N destination legs**: owns
  the shared timeline (`T0`), pumps program video and program audio into every
  leg's streaming service — and, when `--record` is set, the same media into a
  parallel recording sink — emits the `stream.*` (and `recording.*`) status
  events, drives a **per-leg** reconnect policy (attempts, delay, and the
  stability window that keeps a flapping connection from reconnecting forever,
  each leg on its own budget so one destination dropping never takes another
  down), and finalizes the recording on every teardown path. Its start is best
  effort — a refused destination is reported and skipped while the rest go
  live — and it ends with `connectionLost` only when the last live leg is lost.
  Its `VideoSource` is either `.input` (a single capture input the
  session paces through `ProgramPacer` and whose lifecycle it owns — the CLI's
  one-camera path) or `.program` (the compositor's already tick-paced program
  frames, consumed as-is — the phase-3 app's path), and its `AudioSource`
  mirrors it: `.input` (a pass-through microphone at capture cadence,
  session-owned) or `.program` (the mixer's already-paced program mix, reported
  as the stable `"mix"` identity); everything downstream is identical.
- `StreamSession.DestinationLeg` — one destination the program fans out to: a
  caller-minted stable id (the `destination` param on every per-leg status
  event), the `Destination` it streams to, and the `StreamingService` taking
  it there.
- `SecureStorage` / `KeychainSecureStorage` — the host's secret store seam and
  its data-protection-Keychain implementation: stream keys live here (keyed by
  destination id under Tingra's identifier namespace), never in the project
  document, an event, or a log. A seam so the app runs against the real
  Keychain and tests against an in-memory double. Its optional access group —
  resolved at runtime by `sharedAccessGroup()` from the running binary's own
  entitlements, so no Team ID appears in source — is what lets the app and
  `tingra-cli` reach one another's keys (DESTINATIONS.md).
- `SecureStorageError` — a recoverable, secret-free failure from the secure
  store (a Keychain status, or a value that would not read back as text).
- `DestinationStore` — the operator's saved destinations, the host service
  every surface resolves "my Twitch" against (DESTINATIONS.md): `{id, name,
  url}` records in `~/Library/Application Support/Tingra/destinations.json`
  beside their keys in secure storage, selector resolution mirroring input
  selection, and `destination.added`/`.changed`/`.removed` on the event bus.
  Reads go to the file every time — the app and the daemon are separate
  processes over one document — and the directory is injectable so tests never
  touch the operator's own.
- `DestinationID` / `StoredDestination` — a saved destination's stable identity
  (what its key is filed under, unchanged by an edit) and the key-free record
  itself: operator-global, referenced by a project rather than owned by one.
- `DestinationStoreError` — a recoverable, secret-free store failure:
  `notFound`/`ambiguous` selector resolution (mirroring the input selector's
  two), an unreadable or unwritable document, and the unreadable key an
  unsigned development build gets, whose message names the fix.
- `ToolRegistry` — the actor where tool plug-ins register the MCP tools they
  contribute and the MCP/Control service lists and resolves them from; the
  host's concrete `ToolRegistering`.
- `ToolRegistryError` — errors thrown by the tool registry (a tool name already
  registered).
- `StatusSink` — the status sink: retains the latest control-plane status
  events for point reads (`stream_status`) and re-broadcasts them to
  subscribers (the MCP notifications), so status is reported without polling
  (see EVENTS.md, "Sinks"). Retains per event name *and*, for the events a
  fanned-out stream emits once per destination, per name-and-destination — so
  one leg's stats never stand in for another's.

## `packages/TingraCapturePlugIns`

- `AVFoundationCapturePlugIn` — contributes the Mac's cameras and microphones as
  inputs with stable identifiers (`AVCaptureDevice.uniqueID`), backed by
  `AVCaptureSession` (camera; IOSurface 32BGRA, BT.709 tagged at the seam) and
  an `AVAudioEngine` input tap (microphone; PTS from `AVAudioTime` host time),
  and keeps the registry current from the framework's device notifications,
  reporting each change as a `device.connected`/`device.disconnected` event —
  never polling.
- `ScreenCaptureKitCapturePlugIn` — contributes the Mac's displays as inputs
  (`InputKind.display`), discovered through CoreGraphics (no Screen Recording
  prompt; stable `CGDisplayCreateUUIDFromDisplayID` identifiers that survive
  reconnection) and captured via an `SCStream` (IOSurface 32BGRA, BT.709 tagged
  at the seam, host-time PTS, idle frames skipped). A separate plug-in from the
  AVFoundation one — a different framework and a different TCC permission
  (Screen Recording, not Camera). It also keeps the registry current as
  displays come and go, reporting each change as the same
  `device.connected`/`device.disconnected` event with `kind=display`.
- `DisplayChange` / `DisplayEventReporter` — the display mirror of the
  camera/microphone reporter: one CoreGraphics reconfiguration registration
  (`CGDisplayRegisterReconfigurationCallback`, never a poll) fanned out to its
  observers, updating the registry before it emits so a listener always sees
  the registry already reflecting the change. Changes come from **diffing
  display snapshots** rather than the callback's `CGDirectDisplayID`, because
  a removed display's id no longer resolves to the UUID that is its only
  stable identifier — which also means a resolution or arrangement change
  reports nothing rather than a spurious disconnect/reconnect pair.
- `SystemDefaultInputs` — the system default camera and microphone as input
  identifiers, for resolving the `stream` defaults without importing AVFoundation
  elsewhere.

## `packages/TingraGeneratorPlugIns`

- `GeneratorPlugIn` — contributes the built-in generators as inputs through the
  same registration seam as capture.
- `BarsGenerator` — SMPTE color bars with burned in timecode
  (`--video-generator bars`): one IOSurface-backed 32BGRA, BT.709-tagged frame
  per clock tick.
- `AlignmentGenerator` — industry-standard-style alignment pattern
  (`--video-generator alignment`): a cached crosshatch/alignment frame generated
  once at runtime and copied into fresh buffers thereafter.
- `PlugeGenerator` — PLUGE black-level calibration pattern
  (`--video-generator pluge`): reference-black background with below-black,
  near-black, and shadow-detail patches for monitor setup.
- `PlugeStrictGenerator` — stricter broadcast-style PLUGE pattern
  (`--video-generator pluge-strict`): a sparse reference-black field with the
  classic below-black / reference-black / above-black trio.
- `BlackGenerator` — full-frame opaque black (`--video-generator black`): the
  **black generator** a switcher carries as a selectable input on its rows.
  Upstream of fade to black and complementary to it — an ordinary input bound
  into a layer, so overlays, keys, and titles composite over it, where FTB is a
  downstream master stage that obscures everything. Black-only rather than a
  colour parameter: `Layer` has no per-layer parameter dictionary, so a settable
  colour would need a new persisted document key, and a shot's own `background`
  already provides an arbitrary solid — what it cannot be is stacked as a layer.
- `ToneGenerator` — the 440 Hz test tone (`--audio-generator tone`): mono
  float32 buffers with phase continuity, one per clock tick.

## `packages/TingraComposition`

- `Compositor` — the tick-paced engine: holds a latest-wins slot per input and,
  on each program tick, renders the current shot's layer tree over every slot's
  latest frame, yielding one program frame stamped with the tick's master clock
  time. Holds a loaded preset's shots, switches among them with
  `take(shotID:transition:)` — a cut by default, or a dissolve or wipe
  (`loadPreset(_:)` — which never interrupts what is already playing out: the
  on-program shot holds when its id exists in the incoming preset, and otherwise
  keeps rendering as a held snapshot, readable via `programShot`, until a take;
  `setShot(_:)`), edits one live with `updateShot(_:)` — the loaded preset's
  shot with the matching id is replaced in place and, when it is on program,
  rendered from the very next tick — and manages the pool with `addShot(_:at:)`
  (adding is not taking: the program is untouched), `removeShot(shotID:)`
  (removing the shot on program cuts to the adjacent shot — never a dead
  program), and `moveShot(shotID:to:)` (reordering the switcher order, never
  taking: the program is untouched). The step-6 realization of the model
  `ProgramPacer` stood in for — same tick, slots, and timestamps, "take the
  latest frame" replaced by "render the layer tree"; renders a live background
  canvas from the first tick. It also renders the second bus, **preview** — the
  staging bus where the next shot is checked before going to air:
  `setPreview(shotID:)` stages one of the loaded preset's shots (`nil` clears;
  `previewShotID`/`previewShot` read it back), `previewFrames()` is its own
  frame stream, and `takePreview(transition:)` promotes it, swapping what was
  on program onto preview. Preview is a second `ShotRenderer` pass over the
  same tick's snapshot, run only while a shot is staged and a consumer is
  attached, and never fed to a sink — nothing on preview reaches viewers.
  Downstream of everything sits one master stage, **fade to black**:
  `setFadeToBlack(_:duration:)` ramps the program's picture to black and
  latches there across shot switches (`isFadedToBlack` reads the latch). It
  applies to whatever the tick rendered, so a fade and a transition can run at
  once; while the program is held fully black no layer tree is composited at
  all. Program only — preview is never faded, so the operator keeps working
  behind it — and picture only: `AudioMixer.setMasterFade(_:duration:)` is the
  other half.
- `Project` — the saved document for a whole show: a versioned, plain `Codable`
  value type holding the presets, the stream `destination` (key excluded — it
  lives in secure storage), and each shot's optional default transition. The
  format is version 1 until the first release ships (pre-release it grows
  within v1, optional fields decoding forgivingly); decoding a document newer
  than the build understands throws rather than silently loading it.
- `ProjectDestination` — a key-free destination configuration saved in a
  `Project` (the RTMP(S)/SRT URL, a stable id, the operator's name, and an
  enabled flag); the secret it references lives in the host's secure storage,
  keyed by that **id** — not the URL, which is neither unique nor stable
  across an edit. Deliberately `Codable` precisely because it holds no secret,
  unlike the plug-in seam's `Destination`.
- `ProjectDestinationID` — a destination's stable identity within a project:
  what its stream key is filed under in secure storage and what its per-leg
  status events report.
- `Preset` — a named, persisted collection of shots you cut among during a live
  session; a plain `Codable` value type (the project/scripting contract), also
  carrying the preset's optional authored audio configuration (`audioChannels`
  — absent when never authored, so pre-routing documents decode unchanged).
  Active-shot selection is session state on the compositor, not part of the
  saved preset — and which of the project's presets is active is session state
  too, never a field of the saved document.
- `AudioChannel` — one authored channel of a preset's audio configuration: a
  channel strip as the document persists it — the input's device-stable
  `InputID`, a cached display `name`, the authored `level`, `pan`, and
  `isMuted`, and an optional `effects` chain (an ordered list of
  `EffectConfiguration`s in signal order; absent means no chain, so a
  pre-effects document decodes unchanged). Routed to the program mix, v1's
  only bus: membership is routing (sends and further buses are later). Lives
  beside `Preset` because the document types live together; the live strip
  stays `TingraAudio`'s deliberately non-`Codable` `ChannelStrip`.
- `PresetID` — a stable, string-backed identifier for a preset (a fresh UUID by
  default).
- `Shot` — a short-term composition with a stable `id` and user-facing `name`:
  an ordered layer tree (bottom to top) over a `BackgroundColor`, plus an
  optional `defaultTransition` the shot is taken with when the caller does not
  name one (absent = a cut) and an `origin` saying who made it. `Codable` as
  part of the persisted preset.
- `ShotOrigin` — whether a shot is `authored` (the operator made it) or
  `automatic` (the app made it to stage a clicked input, naming it after the
  device). Provenance, not lifecycle: both persist and both are in the
  switcher, and only surfaces meaning "the operator's own shots" filter on it.
  An optional document key that decodes to `authored` when absent, so every
  earlier project keeps its shots.
- `ShotID` — a stable, string-backed identifier for a shot, used to take it to
  program (a fresh UUID by default, or a fixed token for a built-in shot).
- `Layer` — one positioned element: an input referenced by `InputID`, placed in
  a normalized top-left-origin destination `frame` with an `opacity` and an
  optional `effects` chain (an ordered list of `EffectConfiguration`s in signal
  order, applied before placement; absent means no chain, so a pre-effects
  document decodes unchanged). `Codable` with the `frame` flattened to
  `x`/`y`/`width`/`height` keys.
- `BackgroundColor` — a straight RGBA background the layers composite over
  (defaults to opaque black).
- `ProgramFormat` — the program's output geometry and rate (width, height, frame
  rate) every frame is rendered at.
- `Transition` — the move from one shot to the next, passed per call to
  `take(shotID:transition:)`: `cut` (instant, the default), `dissolve(duration:)`
  (crossfade), `wipe(edge:duration:)` (directional reveal), or
  `shader(name:duration:)` (a custom Metal-shader reveal from the built-in
  menu); a plain `Codable` value type on the same project/scripting contract as
  `Preset`/`Shot`, persisted as a shot's `defaultTransition`.
- `WipeEdge` — the frame edge a wipe reveals the incoming shot from (`left`,
  `right`, `top`, `bottom`, in the operator's top-left-origin screen terms),
  its boundary sweeping to the opposite edge; `Codable` by its stable camelCase
  raw value.
- `TransitionShader` — the built-in menu of custom-shader transitions (`iris`,
  `diagonal`, `blinds`), each a first-party hand-written Metal kernel compiled
  into the app — a project document can only name an entry here, never supply
  shader code; `Codable` by its stable camelCase raw value.
- `ShotRenderer` — the internal seam between the compositor's tick-paced control
  flow and the pixel work (a plain render, a dissolve's crossfade, a wipe's
  directional reveal, a shader transition's kernel blend, and fade to black's
  `renderFaded(_:toBlack:format:time:)` — the one requirement that takes a
  composited *frame* rather than shots, because it is a master stage applying to
  whatever the tick produced); task-confined, so it needs no `Sendable`, and
  swappable for a mock in tests.
- `VideoEffectFactory` — how a renderer resolves a layer's persisted chain
  entries into live `VideoEffect`s without depending on the host's effect
  registry: the app builds one from a boot-time snapshot of the registry and
  passes it to the renderer it injects. Returning nil for an unavailable
  effect leaves that slot a pass-through.
- `CoreImageShotRenderer` — the default renderer: composites the layer tree with
  a Metal-backed `CIContext`, GPU-resident, into an IOSurface-backed 32BGRA
  program buffer tagged BT.709 (a software `CIContext` makes the compositing
  math unit-testable with no GPU); dissolves alpha-blend the two layer trees,
  wipes blend them behind a soft-edged swept gradient mask, shader
  transitions blend through the first-party stitchable Metal kernels, compiled
  once at first use from compiled-in source, and the fade stage composites
  opaque black over the finished program frame at the ramp's alpha — the same
  alpha math a dissolve uses, so both share one ramp character. A layer's effect chain is applied
  to its own image before placement (and cropped back to its extent), composing
  lazily so the whole chain fuses into the one render pass; instances are cached
  per layer and rebuilt only when the layer's configurations change.

## `packages/TingraAudio`

- `AudioMixer` — the clock-paced mixer: a mix tick sums every unmuted strip's
  queued samples — scaled by its level, placed by its pan (the equal-power law
  normalized to unity at center; mono pans, stereo balances) — into one stereo
  program-audio block per tick, stamped with the tick's master clock time
  (contiguous, monotonic PTS by construction). Each strip's audio is normalized
  once at channel intake (float32, deinterleaved, at the mix rate); a stalled
  strip contributes silence and never stalls the mix.
  `setChannelStrips(_:)` attaches and detaches strips live;
  `setLevel(_:forInput:)`/`setPan(_:forInput:)`/`setMuted(_:forInput:)` apply
  from the next tick; `setEffects(_:forInput:)` replaces a strip's effect
  chain (a structural edit) and `setEffectParameters(_:forEffectAt:forInput:)`
  retunes one slot in place, keeping its processing state so a dragging
  control never clicks; `programAudio()` is the single-consumer mixed stream,
  and `meterReadings()` its meter sibling — one `MeterBlock` per tick,
  measured pre-fader as a byproduct of the same walk, only while a consumer is
  attached, and never on the event bus. Downstream of every strip,
  `setMasterFade(_:duration:)` ramps the whole master to silence and latches
  there (`isMasterFaded` reads the latch; `defaultMasterFadeDuration` is the
  broadcast-typical half second) — the audio half of **fade to black**,
  interpolated per sample within the block so a scripted ramp has no zipper,
  and applied upstream of the post-fader master reading, so a faded master
  meters as silence while every strip meter keeps reading its input.
- `ChannelStrip` — one input's slot in the mixer: the input and its level, pan,
  and mute (the effect chain is mixer channel state, set through
  `AudioMixer.setEffects(_:forInput:)`, since effect instances hold live
  processing state; routing needs no surface here — the program mix is v1's
  only bus, and the strip's persisted form is `TingraComposition`'s
  `AudioChannel`). Engine mute is independent of device lifecycle — whether a
  muted strip's device keeps capturing is the caller's policy.
- `MeterReading` — one strip's meter measurement over one mix block, pre-fader
  (after intake normalization and the strip's effect chain, before level, pan,
  and mute): the block's peak
  and its RMS (the hotter channel's, for stereo), as linear magnitudes;
  `floor` is what silence meters as.
- `StereoMeterReading` — the master's measurement over one mix block: a
  `MeterReading` per program channel, measured **post-fader** on the summed
  mix. Stereo where a strip's reading collapses to its hotter channel, because
  the master is where the operator judges the stereo image; `floor` is silence
  on both channels.
- `MeterBlock` — one mix tick's readings: every live strip's `MeterReading`
  keyed by input id (a strip with nothing queued reads the floor, never a
  gap) plus the post-fader `master` reading, stamped with the tick's master
  clock time.
- `MixFormat` — the program mix's audio geometry: the sample rate and the block
  size each mix tick produces (48 kHz, 1024-frame blocks by default; the mix is
  always stereo float32).
- `AudioMonitor` — the monitor seam: the engine's audio **output** path, the
  program mix played to an output device the operator chooses (GLOSSARY.md,
  "Monitor"). A **sink**, not a bus — it consumes blocks the mixer has already
  produced, so nothing it does can change what viewers hear, and the monitor
  level scales only what is played out. `availableDevices()` lists the output
  devices and `deviceUpdates()` streams the list as devices come and go (never
  polled); `start(device:format:)`/`stop()` open and close the path,
  `play(_:)` plays one mixed block, and `setLevel(_:)` sets the operator's
  listening volume.
- `AudioMonitorDevice` — one audio output device the operator can monitor
  through, identified by its stable Core Audio UID (the persisted identity)
  with its user-facing name.
- `AudioMonitorError` — what can go wrong opening a monitor device
  (`deviceNotFound`, `couldNotStart`), every case recoverable: a device that
  will not open leaves the program mix, the stream, and the recording
  untouched.
- `AVAudioEngineMonitor` — the first-party `AudioMonitor`: mixed blocks
  scheduled onto an `AVAudioPlayerNode` inside an `AVAudioEngine` bound to the
  chosen device, with output devices discovered through the Core Audio HAL.
  An actor, so the non-`Sendable` engine needs no `@unchecked Sendable`
  escape. Because the mix tick and the output device run on different clocks,
  it caps its scheduled backlog (≈85 ms) and **drops** past it rather than
  letting monitor latency grow — the mixer's intake cap mirrored at the
  output. Seam-only, like the capture inputs' hardware paths. It excludes
  macOS's **private aggregate** devices (`CADefaultDeviceAggregate-<pid>-0`),
  which Core Audio creates inside our own process the moment the monitor
  starts — without the filter the picker offers the monitor's own plumbing as
  something to monitor through. The test is the composition dictionary's
  `private` flag, which a user-created aggregate does not carry, so an
  operator's own aggregate stays offered.

## `packages/TingraEffectPlugIns`

- `EffectPlugIn` — contributes the built-in audio effects through the effect
  registration seam.
- `GainEffectProvider` / `GainEffect` — a clean decibel trim on a channel
  strip (`gainDecibels`, −24…24 dB, unity by default); the seam's reference
  conformance.
- `HighPassEffectProvider` / `HighPassEffect` — a second-order Butterworth
  high-pass, the broadcast rumble filter (`cutoffHertz`, 20…1000 Hz, 80 Hz by
  default).
- `LowPassEffectProvider` / `LowPassEffect` — a second-order Butterworth
  low-pass for hiss and harshness (`cutoffHertz`, 200…20000 Hz, 12 kHz by
  default).
- `ColorAdjustEffectProvider` / `ColorAdjustEffect` — a layer's
  brightness, contrast, and saturation trim over `CIColorControls`; every
  parameter neutral at its default, so adding it changes nothing until it
  is adjusted.
- `BlurEffectProvider` / `BlurEffect` — a layer's Gaussian blur over
  `CIGaussianBlur` (`radiusPixels`, 0…100 px in the layer's own image
  scale, no blur by default).

## `packages/TingraOutputPlugIns`

- `HaishinKitOutputPlugIn` — contributes the RTMP/RTMPS and SRT providers
  through the output registration seam.
- `RTMPStreamingServiceProvider` — the provider serving `rtmp://` and `rtmps://`
  destinations; creates a fresh service per stream.
- `HaishinKitStreamingService` — the concrete RTMP/RTMPS service: connects and
  publishes, compresses internally (VideoToolbox via HaishinKit), appends program
  video as uncompressed sample buffers and audio as PCM buffers carrying the
  session-timeline PTS, watches for connection loss, and reports delivery counters.
- `SRTStreamingServiceProvider` — the provider serving `srt://` destinations
  (roadmap step 8); creates a fresh service per stream.
- `SRTHaishinKitStreamingService` — the concrete SRT service: composes the stream
  key into the URL's `streamid`, connects and publishes over SRT (MPEG-TS), shares
  buffer conversion and compression settings with the RTMP service, and derives
  its frame rate by counting appends. HaishinKit's SRT publish path exposes no
  mid-stream loss push, so it reports start-time failures but not `connectionLost`.
- `HaishinKitMediaConversion` — the transport-neutral compression-settings mapping
  and buffer conversion (program frame → uncompressed sample buffer, program audio
  → PCM buffer + `AVAudioTime`) shared by both HaishinKit services.

## `packages/TingraRecordingPlugIns`

- `RecordingPlugIn` — contributes the `.mov`/`.mp4` recording provider through
  the same output registration seam as streaming.
- `AVAssetWriterRecordingServiceProvider` — the provider serving `.mov` and
  `.mp4` targets; creates a fresh recording service per recording.
- `AVAssetWriterRecordingService` — the concrete service: orchestrates open,
  append, finalize, and terminal-failure reporting over a writer backend, so its
  lifecycle is unit-testable without touching disk.
- `RecordingCapacity` — how much recording a volume still holds, in time rather
  than bytes; the pre-flight free-space check refuses a recording the volume
  cannot hold for at least five minutes, and the app shows the same reading.
- `RecordingCapacityProbe` — how a recording service measures a volume,
  injected so the check is testable without a disk.

## `packages/TingraMCP`

- `Daemon` — the engine daemon (`tingra-cli serve`): accepts connections on a
  Unix domain socket, verifies each peer's uid, serves each as an independent
  `MCPSession` against the shared engine, and idle-exits when quiet but never
  mid-stream. `manual(socketPath:…)` binds its own socket; the launchd
  socket-activated path uses `init` with a supplied descriptor.
- `MCPSession` — one per-connection MCP session: the `initialize` handshake
  (carrying the daemon build version), `tools/list`, `tools/call` dispatch, and
  status-change notifications fed by the status sink.
- `StreamCoordinator` — owns the one active stream in v1 on behalf of the stream
  tools; reuses the host's `StreamSession`, confirms the stream went live before
  `stream_start` returns, resolves each leg's destination (a raw URL, or one
  named against the operator's `DestinationStore`), and keys
  `stream_status`/`stream_stop` off the session id.
- `StreamDefaults` — the system default input identifiers, injected so the
  coordinator never imports the capture package.
- `ControlToolsPlugIn` — registers the first-party tools (`devices_list`,
  `destinations_list`, `probe`, `stream_start`, `stream_status`,
  `stream_stop`) through the same `ToolRegistering` seam a third party uses.
- `DaemonInfo` — the daemon identity (name, version) reported in the
  `initialize` result so a client can detect version skew.
- `StdioSocketProxy` — the transparent byte pipe behind `tingra-cli mcp`: copies
  bytes between stdin/stdout and the daemon socket with no protocol logic (stdin
  EOF closes the connection; the connection closing exits).
- `SocketLocation` — the per-user socket path
  (`~/Library/Application Support/Tingra/tingra.sock`) and its `0700` directory
  setup.
- `LaunchAgent` — the daemon's launchd LaunchAgent: renders the socket-activation
  plist and installs/uninstalls it (`serve --install`/`--uninstall`), so the
  daemon is launchd-parented and TCC prompts name Tingra (MCP.md, "Lifecycle").
- `LaunchAgentError` — a developer-facing failure from installing or removing
  the LaunchAgent (directory/plist not writable, `launchctl` reported nonzero),
  each stating what to fix.
- `LaunchdSocket` — adopts the launchd-owned listening socket under socket
  activation (wrapping the `CTingraLaunchd` C shim over `launch_activate_socket`);
  returns nil when not launchd-parented, so the daemon falls back to manual mode.
- `JSONRPCID`, `JSONRPCError`, `JSONRPCErrorCode`, `JSONRPCResponse`,
  `JSONRPCNotification`, `JSONRPCIncoming` — the documented JSON-RPC 2.0 wire
  types, so direct socket clients can script the engine without the proxy.
- `MCPProtocol` — the MCP method names, notification names, and the protocol
  version the daemon speaks.


## `apps/tingra-cli`

An executable, so it exposes no public types; its surface is its subcommands —
`devices`, `stream`, `probe`, `serve`, `mcp`, and `version` (see
[CLI.md](CLI.md) for each one's options, output, and exit codes).

## `apps/ingest-simulator`

No Swift target and no types: a pinned MediaMTX binary wrapped in `sim.sh`
(`start | stop | status | verify`) with key-validating paths (see
[SIMULATOR.md](SIMULATOR.md)).

## `apps/tingra-app`

An app, so it exposes no public API beyond its `@main` entry; its internal
surface is:

- `EngineModel` — the `@Observable @MainActor` model that boots the host,
  activates the capture, generator, and streaming plug-ins through the same
  `PlugInContext` the CLI uses, drives the compositor and the mixer, loads — or
  seeds, on first launch — the project's presets from the autosaved project
  document, switches among them without ever interrupting what is on program
  (the active preset, like the active shot, is session state), manages the
  presets — add, duplicate, rename, reorder, remove — and the active preset's
  shots — add, duplicate, rename, reorder, remove — applies layer-tree edits to
  the active shot, rebinds the built-in roles' layers when a picker's selection
  changes, starts and stops each channel strip's device as it is unmuted and
  muted, and puts the program on air by feeding the compositor's frames and the
  mixer's blocks to a `StreamSession` program source fanned out to every enabled
  destination, each destination's stream key held in Keychain-backed secure
  storage under its own id — reflecting the session's `StreamStatus` and each
  leg's `DestinationState` from the bus's `stream.*` events, never a poll, and
  takes the whole program off air with `setFadeToBlack(_:duration:)` — the one
  control driving both engine surfaces, which lives here because
  `TingraComposition` and `TingraAudio` depend on each other in neither
  direction.
- `SidebarView` — the main window's leading sidebar: the project's presets, the
  active one's shots, the video generators, the audio generators, every camera,
  display, audio input device, and audio output device this Mac can see, and the
  destinations the program streams to, in nine sections. It is a standard
  `NavigationSplitView` sidebar, which is what makes it Liquid Glass on macOS 26
  — nothing applies a glass material by hand, and the deployment floor has none
  to apply. The order is the signal path: presets hold shots, a shot is what
  goes to air, the inputs beneath are what shots are built from, and the
  destinations the program leaves by come last — and the shot section lists the
  **authored** shots only, so the working shots the app creates to stage a
  clicked input stay in the switcher without cluttering the operator's own list.
  The Video Generators section lists the patterns that synthesize a picture —
  bars, PLUGE, alignment, black — drawn from the video inputs, so the 440 Hz
  tone never becomes a video layer that renders nothing; the tone is listed
  instead in Audio Generators, inert beside the microphones it mixes with, which
  is what makes both headings say which medium they mean. Shot, camera, display,
  generator, and preset rows behave identically — one `stagingSection` draws all
  five, so they cannot drift — staging on preview and lighting the same tally
  the input rows' tiles carry, red on air and green staged, from the shared
  `Tally` tints; only the call differs, `setPreview(_:)` for a shot,
  `stagePreview(showing:)` for an input, and `switchPreset(to:)` for a preset —
  which is also why the active preset wears a checkmark rather than a lamp,
  since a preset is not on a bus and red means on air everywhere else in the
  app. Nothing reaches program from here. Every section collapses, with the
  standard source-list disclosure, and which ones are folded away persists
  across launches. A shot row also carries a context menu with one item, Delete,
  which raises a confirmation naming the shot before anything is removed —
  unlike the switcher's own Remove Shot, which is immediate; a destination row
  carries the same Delete, whose confirmation says that the stored stream key
  goes with it. The audio and destination rows otherwise read rather than switch
  — the channel strips, the monitor picker, and the streaming panel already own
  those decisions — and listing a device starts nothing, so no camera indicator
  lights for the sidebar.
- `SidebarRow` — the pure, unit-tested row derivation behind it: one identity
  across shots, presets, capture devices, destinations, and Core Audio outputs;
  the shot tally with red winning over green; the checkmark that marks the
  active preset without borrowing the tally's colours; the `kind` filter that
  keeps a generator out of a device list and gives the audio generators a
  section of their own; and the name sort that stops the output section
  reshuffling when Core Audio reorders itself.
- `SidebarSection` — the closed list of the sidebar's nine sections, each
  deriving its own persistence key and its own disclosure `tap` name, so a
  section added without an entry does not compile.
- `SidebarPreferences` — which sections are open: machine-local `UserDefaults`
  on the `MonitorPreferences` pattern — window habits are not part of the show,
  and a source list that forgot its collapsed sections each launch would read as
  a bug. A section nothing is stored for reads open, so the default is the
  absence of a value rather than its content.
- `ContentView` — the main window's detail column, in two sections — a
  monitoring section across the top, the input rows on the left and the preview
  and program monitors on the right, over a control section holding everything
  the operator works. The whole column scrolls, and the monitoring section's
  height is derived from the window's width — two 16:9 monitors have no use for
  surplus vertical room, and a plain stack resolved a shortfall by collapsing
  the monitors and pushing the pickers off the bottom edge. The control section
  holds the camera/display pickers, a streaming panel — the destination list,
  live status, Start/Stop — and a preset switcher that switches and manages the
  project's presets — an Add Preset button plus a per-preset context menu with
  Duplicate, Rename…, Move Left / Move Right, and Remove Preset, disabled on the
  last remaining preset — above a shot switcher that also manages shots: an Add
  Shot button plus a per-shot context menu with Duplicate, Rename…, a Default
  Transition submenu setting the shot's persisted default, Move Left / Move
  Right, and Remove Shot, and a segmented transition picker — Default (each
  shot's own default transition, the initial selection), or an explicit Cut,
  Dissolve, or Wipe, with an edge pop-up while Wipe is selected — choosing how
  the next take reaches program, and beneath it a latching Fade to Black button
  (⇧⌘B) that takes the whole program off air, picture and sound together, and
  stays available when the preset has no shots.
- `DestinationListView` — the streaming panel's destination list: one row per
  destination the program fans out to, each with an enable toggle, a name, a
  URL, a secure stream-key field, its own live state — its bitrate and frame
  rate while delivering, or Reconnecting/Refused/Lost when it alone is in
  trouble — and a remove button that also clears its stored key; rows lock while
  streaming, since v1 adds and removes destinations between runs.
- `DestinationEdit` — the pure, unit-tested destination state behind those rows:
  the URL held **as text** while it is typed, streamable only once it carries a
  supported scheme and a host, converting to a saved `ProjectDestination` only
  when usable — so a half-typed URL never reaches the project file, and an
  edited URL keeps its id and therefore its stored key.
- `MixerView` — the mixer panel: one channel strip per authored audio channel
  and per discovered audio input, each with a mute toggle, a meter, a live level
  slider, a pan slider that recenters on double-click, and an Effects button
  badged with the chain's length; a strip whose device is absent stays on the
  panel, marked not connected, its settings kept for the device's return —
  closing with the **master strip**, the console's master section: the
  post-fader stereo master meter beside the monitor device picker and the
  operator's own monitor level. There is deliberately no master fader — the
  engine has no master gain, and the monitor level scales only what the operator
  hears.
- `EffectChainView` — one strip's audio effect chain, in a popover: slots in
  signal order with Move Up / Move Down / Remove, an Add Effect menu over every
  registered audio effect, and a slider per parameter the effect declares —
  drawn generically from its `EffectParameter` descriptors, so a third-party
  effect gets parameter UI without the app knowing it exists.
- `MixerStrip` — the pure, unit-tested strip state: the merge of the active
  preset's authored `AudioChannel`s with live discovery — authored channels
  first in document order, new devices appended muted — falling back to the
  seeding policy, first *captured* input unmuted at unity — never a generator,
  which would put a test tone on air — the rest muted, every strip centered,
  when nothing is authored; strip edits sync back into the active preset and
  autosave debounced like shot edits.
- `StripMeter` — one strip's meter: a compact capsule showing the strip's
  pre-fader signal.
- `MasterMeter` — the master's meter: two capsules showing the program mix
  post-fader, one per program channel — stereo because the master is where the
  operator judges the stereo image.
- `MeterCapsule` — the one capsule both meters draw, so the scale, the zone
  boundaries, and the ballistics can never drift between two meters read side by
  side — an RMS bar over broadcast green/yellow/red zones with a decayed peak
  marker, drawn at display cadence in a `TimelineView` sampling the shared
  `MeterRelay` the model's meter drain fills, so readings never churn SwiftUI
  observation.
- `MeterBallistics` — the unit-tested draw-time ballistics: instant attack,
  20 dB/s decay on a −60…0 dBFS scale.
- `MonitorPreferences` — where the monitor device and level persist:
  machine-local `UserDefaults`, not the project document — which headphones are
  plugged into this Mac is not part of the show — and not session state, since
  headphones do not change between launches; monitoring starts off on a fresh
  install, because monitoring through speakers beside a live microphone is a
  feedback howl, and it caches the selected device's name so the picker can
  label a selection the device list cannot currently resolve.
- `RecordingPanel` — the recording panel: the folder the program is written to,
  a container picker, how much room the volume still holds, and the Record
  control with its own elapsed time and file name — its own panel beside the
  streaming one because recording is its own session, so stopping the stream
  leaves a recording rolling and vice versa.
- `RecordingPreferences` — where the recordings folder and container persist:
  machine-local `UserDefaults` for the same reasons as `MonitorPreferences`,
  defaulting to `~/Movies`, which needs no TCC prompt where Desktop and
  Documents would.
- `RecordingFilename` — the pure, unit-tested naming rule: a date-stamped name,
  and a numeric suffix rather than overwriting when one is taken — a recording
  must never destroy an earlier take.
- `StatusBarView` — the status bar across the bottom of the main window and the
  multiview window: whether the program is being recorded and whether it is on
  air, with the recording's elapsed time and the stream's bitrate and frame
  rate. A bottom safe-area inset rather than a row in the stack, so it never
  scrolls away with the panels that say the same thing — which is the whole
  reason it exists, since those panels sit at the foot of a scrolling column of
  eight surfaces and the multiview window never had them at all. It carries
  status only, no controls: a bar always on screen is always one stray click
  from whatever it holds, and the two actions it would hold are the two that go
  out to viewers. Its leading inset matches the production column's padding, so
  the readings line up with the panel headings above them — which is what the
  collapsed sidebar makes visible.
- `StatusBarCommands` — the View-menu item that shows and hides it, ⌘/ — the
  Finder's and Safari's assignment. The title flips, Show to Hide, the macOS
  convention for this item, where the settings row is a checkbox because a
  settings row states the current state; a trailing separator keeps it out of
  Enter Full Screen's section, which would otherwise indent it past an icon
  column it does not use. It is not in `ProductionShortcut`: window chrome is
  discoverable in the menu bar, which is what a production control on a
  scrolling panel is not.
- `SidebarVisibilityCommands` — the View-menu Show/Hide Sidebar item, ⌃⌘S,
  driving the main window's own column-visibility state. Hand-written after
  SwiftUI's stock `SidebarCommands()` was measured and rejected: its ⌃⌘S
  collapsed the *settings* window's source list — the one sidebar that must
  never collapse, since it is that window's only navigation — and once that
  window existed it stopped reaching the main window at all, while its title
  stayed on "Show Sidebar" with the sidebar plainly showing.
- `StatusBarItem` — the pure, unit-tested reading behind it — the lamp state and
  symbol for a stream and for a recording, with idle and stopped reading the
  same, a file still being closed reading pending rather than off, and both
  faults drawing a warning triangle.
- `StatusBarPreferences` — whether the bar is shown: machine-local
  `UserDefaults` on the `AppearancePreferences` pattern, shown on a fresh
  install, the presence of the key checked first so a missing value does not
  read as hidden.
- `StatusBarModel` — the `@Observable` both windows read and both the General
  settings checkbox and the View-menu item write — shared rather than each
  window reading `UserDefaults` for itself, since `UserDefaults` is not
  observable and the two controls live outside the windows they change.
- `TingraAppDelegate` — the two AppKit hooks: it answers `.terminateLater` so a
  recording open at quit is finalized into a playable file instead of truncated,
  and turns off automatic window tabbing before the first window exists — the
  one line that removes AppKit's Show Tab Bar and Show All Tabs from the View
  menu, which are the only two items in it that do nothing this app wants: the
  main window is one per show, and multiview's whole point is a second display
  rather than a tab beside the window it monitors.
- `Binding.reportingTap` — the shared helper that reports a control's `tap` from
  its **selection binding** rather than from `.onChange` — a binding setter runs
  only when the operator works the control, so a default the model assigns at
  boot no longer records a tap nobody made; see EVENTS.md, "Where a picker's tap
  is reported".
- `LayerTreeEditorView` — the layer-tree editor: add a layer bound to any
  discovered camera or display, remove, reorder, and adjust a layer's frame and
  opacity with live sliders — every edit on program at the next tick, and
  autosaved to the project file.
- `LayerTreeEdit` — the pure, unit-tested edit operations over a `Shot`,
  including the rebind a picker change applies.
- `ShotEdit` — the pure, unit-tested shot-management operations: a new empty
  shot, a shot showing one input full frame (the one kind the app marks
  `automatic`), a duplicate under a fresh id, a rename that ignores empty names —
  and that promotes an automatic shot to authored, the operator claiming it —
  setting or clearing a shot's default transition, and the match that decides
  which existing shot staging an input reuses — one showing *only* that input,
  never one that merely contains it, so clicking a camera previews the camera
  rather than a composition built around it.
- `PresetEdit` — the same operations one level up: a new empty preset, a
  duplicate under a fresh id with the source's shot ids preserved — so switching
  between original and copy holds the on-program shot — and a rename that
  ignores empty names.
- `ProjectStore` — loads and autosaves the `.tingraproject` document under
  `~/Library/Application Support/Tingra`, setting an unreadable file aside
  rather than overwriting it.
- `MonitorView` — the Core Image `MTKView` that samples one frame source at
  display rate — one instance over program, another over preview, and one per
  input tile in multiview; it was `ProgramPreviewView` while program was the
  only bus.
- `MonitorFrameSource` — the seam a monitor reads through, so those three cases
  share one draw path: a bus's `ProgramFrameRelay`, or an `InputFrameSource`.
- `MonitorTile` — the framed monitor — video letterboxed on black, an optional
  tally border, a name badge, and an optional status badge, which is what tells
  a program monitor faded to black apart from a dead one — shared by the main
  window's two monitors and every multiview tile.
- `MonitorRenderContext` — the one Metal device, command queue, and `CIContext`
  every monitor draws through, rather than one per view.
- `InputGridView` — the multiview window's input grid: one tile per *running*
  input, name-badged and tally-bordered — red on air, green staged, no border
  idle. The tiles are deliberately inert: a tile is an *input* while preview
  stages a *shot*, and a guess one click from air is exactly what the preview
  bus refused.
- `InputRowsView` — the main window's top-left pane: every available camera in a
  horizontal row, the generators and displays in a second row beneath it, split
  by provenance because cameras are what an operator reaches for. Every tile is
  live — the engine runs every discovered video input for monitoring, a
  deliberate exception to the multiview rule, paid for in camera indicator
  lights and an awake Continuity Camera — and clicking a tile stages that input
  on preview, resolving the input-versus-shot question in favour of an authored
  shot that already shows it and only inventing one when none does.
- `MultiviewView` — the multiview window: program and preview across the top
  with the input grid beneath, at full tile size on a display of its own, over
  the same status bar the main window carries — which earns its place here more
  than anywhere, since a multiview on a second display is often the only surface
  an operator is looking at. Not a bus: nothing is fed from it and nothing is
  promoted out of it, so it adds no engine surface beyond two read accessors.
  The window monitors preview beside program and carries a second switcher row
  that stages a shot on preview, with Cut and Take buttons promoting it
  (`EngineModel.setPreview(_:)`/`cutPreview()`/`takePreview()` — Cut takes
  instantly whatever transition is armed, the CUT beside AUTO of a hardware
  panel); what is staged is session state and never enters the project document.
- `InputFrameSource` — one input's tile frames, pulled from the compositor's
  latest-wins slot on each draw — a read-only share, drawn and dropped.
- `MultiviewTile` — the pure, unit-tested tile derivation and its tally rule,
  red winning over green, plus the `Tally` tint pair both tile surfaces draw
  from so they cannot read a lamp differently.
- `MultiviewCommands` — the View-menu command that opens the window, ⌥⌘M.
- `ProgramLayout` — the pure, unit-tested arrangement that seeds a fresh
  project's picture-in-picture, display, and camera shots.
- `ProductionShortcut` — the closed list of production keyboard shortcuts —
  staging ⌘1–⌘9, Cut ⇧⌘↩, Take ⌘↩, Fade to Black ⇧⌘B, Go Live ⌘G, Record ⌘R,
  Show or Hide Status Bar ⌘/ — that is both the binding the controls apply and
  the listing the Shortcuts settings pane prints, so a documented shortcut and a
  working one cannot disagree; the case order is the pane's reading order; the
  assignments are the ones the professional Mac switchers already share, which
  is why the take is ⌘Return and not ⌘T. The status bar is the one entry bound
  to a menu item rather than a control, because window chrome has no control to
  hang a shortcut on — and the View-menu item binds this case, so the pane and
  the menu bar still cannot disagree.
- `SettingsView` — the settings window, ⌘, — a `NavigationSplitView` whose
  source list holds three panes, the shape System Settings and Xcode 26 settled
  on. A `Window` scene with its own Settings… command rather than SwiftUI's
  `Settings` scene, because that scene starts its content below the title bar
  and leaves the source list floating as a card instead of running the full
  height of the window with the close/minimize/zoom buttons on it. The sidebar's
  collapse button is removed, since a settings sidebar *is* its navigation and
  collapsing it strands the operator in a pane — but an empty toolbar item
  stays, because a window with no toolbar reverts to the short title bar the
  sidebar cannot run up through. The open pane names the window, on the leading
  edge beside the split view rather than centered; and Escape closes the window
  beside the ⌘W every window has, since nothing here is committed for Escape to
  cancel.
- `SettingsPane` — the closed list of panes — General, Shortcuts, About — each
  deriving its own name and symbol, so the sidebar's label and the window's
  title cannot drift.
- `SettingsCommands` — the app-menu Settings… item that opens it, replacing the
  one the `Settings` scene would have contributed.
- `GeneralSettingsView` — the General pane: the app's Appearance, and a Show
  Status Bar checkbox showing or hiding the bar across the bottom of both
  windows.
- `AppearancePicker` / `AppearanceSwatch` / `AppearanceMiniDesktop` — the
  three-thumbnail appearance control and the miniature desktop each thumbnail
  draws — the System swatch composites the other two rather than being a third
  artwork.
- `ShortcutsSettingsView` / `ShortcutRow` — the Shortcuts pane, read-only —
  every shortcut the app binds in **one** group, no headings and no footnote,
  drawn from `ProductionShortcut.allCases` so a seventh cannot be added and
  forgotten here.
- `AboutSettingsView` — the About pane: the app's icon, name, and version.
- `AppearanceMode` — System, Light, or Dark — three cases rather than a boolean,
  because "follow the system" is a state and not the absence of a choice.
- `AppearancePreferences` — where that choice persists: machine-local
  `UserDefaults` on the `MonitorPreferences` pattern, defaulting to System, with
  an unrecognizable stored value reading as System rather than trapping.
- `AppearanceModel` — the `@Observable` that installs the matching
  `NSAppearance` on the application at launch and on every change, so the stored
  value and the painted window can never disagree.
- `AppearanceTarget` — the one-property seam it installs through, so a test can
  watch the install without repainting the test host.
- `AppVersion` — the pure, unit-tested version assembly the About pane prints —
  the build in parentheses, dropped when it repeats the version, and nothing
  invented for a bundle that names neither.

## `apps/tingra-cameras`

An app, so it exposes no public API beyond its `@main` entry; its internal
surface is:

- `TingraCamerasApp` — the `@main` entry owning the shared model.
- `ContentView` — the `NavigationSplitView` two-column layout.
- `SidebarView` — the Cameras/Microphones sections as a standard sidebar `List`
  — `Label` rows with SF Symbols and a trailing checkmark on the active camera
  and microphone.
- `PreviewCanvasView` — the right panel centering the rounded 16:9 preview
  frame.
- `CameraPreviewView` — the video view window: a standard
  `ContentUnavailableView` placeholder today, with an
  `AVCaptureVideoPreviewLayer` seam that shows a live feed once a running
  `AVCaptureSession` is attached.
- `HardwareModel` — the `@Observable @MainActor` selection state — `Device` and
  `DeviceKind` values, and the selected camera/microphone.
