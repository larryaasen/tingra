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
  and the emitting call site; publicly initializable, for a host re-creating
  one it received over a wire (the app tier handing an extension the event
  that woke it) and for tests.
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
  stream for the media the input does not produce). A `ParameterDescribing`
  since 2026-09-15: an input may declare settings, and `setParameters(_:)`
  (defaulted to nothing) hands it their values live, before or after `start()`.
- `InputID` — the stable identifier for an input, as surfaced by input
  discovery.
- `InputKind` — the kind of input (camera, microphone, display, generator,
  media) — its *provenance* — driving discovery grouping and selector
  resolution; `media` is a file the operator added, created by a
  `MediaInputProvider` rather than discovered.
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
  `StreamingService` per stream; a `ParameterDescribing`, whose declared
  per-destination settings arrive on `Destination.parameters`.
- `StreamingServiceEvent` — a connection event reported after a successful
  start (`connectionLost`); the session drives reconnect policy from it.
- `StreamingServiceError` — the error currency of `StreamingService.start(to:)`
  (`unsupportedDestination`, `connectionRejected`), each mapped to its stable
  error identifier.
- `StreamingStatistics` — a point-in-time snapshot of a service's delivery
  counters, feeding the periodic `stream.stats` events.
- `StreamConfiguration` — the compression and program settings a stream session
  runs with (resolution, frame rate, codecs, bitrates — with the static
  `recommendedVideoBitsPerSecond(width:height:frameRate:)` rule, linear in
  pixel rate and anchored at 1080p30 = 4500k, that the app encodes at — and the
  `includesVideo`/`includesAudio` track topology the recording sink needs up
  front); contains no secrets. Shared by the streaming and recording sinks.
- `OutputID` — the stable identifier for a registered output (streaming or
  recording).
- `OutputRegistering` — the registration seam where output plug-ins attach —
  both streaming (by URL scheme) and recording (by file extension) providers;
  the host's `OutputRegistry` conforms.
- `Destination` — a configured streaming target: URL plus optional stream key
  (deliberately not `Codable` — the key is a secret), plus since 2026-09-15
  the `parameters` its provider declared, keyed by `Parameter.key` (default
  empty).
- `RecordingService` — the recording seam: opens a local file, appends the same
  program media the stream gets, reports a terminal write failure, and
  finalizes (`AVAssetWriter` lives behind this protocol). A narrower sibling
  of `StreamingService` — no destination, no reconnect.
- `RecordingServiceProvider` — what a recording plug-in registers: a factory
  keyed by file extension (`mov`/`mp4`) that creates a configured
  `RecordingService` per recording; a `ParameterDescribing`, whose declared
  settings arrive on `RecordingFile.parameters`.
- `RecordingServiceEvent` — a recording event reported after a successful start
  (`failed`); a file has no reconnect, so a write failure is terminal.
- `RecordingServiceError` — the error currency of `RecordingService.start(to:)`
  (`unwritableDestination`, `writerNotReady`), each mapped to the
  `recordingFailed` identifier.
- `RecordingFile` — where a recording is written: a local file URL plus its
  container format (`mov`/`mp4`); the recording counterpart to `Destination`,
  carrying no secret, and since 2026-09-15 the provider's `parameters`
  (default empty).
- `EffectID` — the stable identifier for a registered effect, shared by the
  audio and video sides; what a persisted chain entry names.
- `EffectConfiguration` — one effect as a document persists it: its `EffectID`
  plus its parameter payload. A chain persists as an ordered list of these
  (order is signal order); an entry naming an effect this build has no
  provider for survives the round trip untouched.
- `ParameterDescribing` — what every host-tier registration shares since
  2026-09-15 (PLUGINS.md, Decision 15): the one requirement `parameters`,
  defaulted to empty, refined by `Input`, `StreamingServiceProvider`,
  `RecordingServiceProvider`, `AudioEffectProvider`, and
  `VideoEffectProvider`, so a host draws a settings pane for any of them from
  the descriptors alone. Where the values live differs per seam and each
  names its place (the chain slot, `Input.setParameters`,
  `Destination.parameters`, `RecordingFile.parameters`).
- `Parameter` — one adjustable parameter a plug-in declares for something it
  registers (key, name, range, default, unit, linear/logarithmic scale), so a
  host draws a control for a third-party effect, input, or output without
  knowing it exists. Its `Kind` is `.number` (a slider) or, since 2026-09-09,
  `.color` (a color well, with a `defaultColor`) — added additively, every
  numeric conformer unchanged. `value(in:)`, `color(in:)`, and `clamped(_:)`
  are the reading rules every control and conformer share. Named
  `EffectParameter` until 2026-09-15; the old name is a deprecated alias.
- `ParameterColor` — the value of a color parameter: sRGB red, green, blue, and
  alpha in 0…1, clamped on creation, carried in a persisted payload as the
  plain object `{red, green, blue, alpha}` (`jsonValue` / `init(_:)`). Named
  `EffectColor` until 2026-09-15; the old name is a deprecated alias.
- `AudioEffect` — one audio processing step in a channel strip's chain,
  processing the mixer's native currency (deinterleaved float32 blocks at the
  mix rate) in place at the mix tick.
- `AudioEffectProvider` — what an effect plug-in registers for an audio
  effect: identity, declared parameters, and a factory creating one
  `AudioEffect` instance per chain slot.
- `VideoEffect` — one video processing step in a layer's chain, processing the
  renderer's native currency (`CIImage → CIImage`) so a whole chain fuses into
  one render pass; `outputExtent(for:)` (2026-09-09, defaulted to the input
  extent) declares the extent `process` will leave, so a host can measure a
  layer's picture after its chain without rendering it.
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
- `Resource` — the MCP resource seam (2026-09-14): one thing the engine lets
  a client observe — a JSON document at a stable `tingra://` URI with a name,
  title, description, MIME type (default `application/json`), a `read()`, and
  a `changes()` signal stream (default: never changes) that subscriptions
  forward as updated notifications. Value types and identifiers only, never
  an engine object; a document is a scripting contract like a tool's result.
- `ToolRegistering` — the registration seam where tool plug-ins attach; the
  host's `ToolRegistry` conforms.
- `JSONValue` — an arbitrary JSON value (the currency of the tool seam):
  scalars, arrays, and objects, encoding as natural JSON; more general than
  the event bus's scalar-only `EventValue`. Reads through `objectValue`,
  `arrayValue`, `stringValue`, `intValue`, `doubleValue`, and `boolValue`.
  `@frozen` (2026-09-23; PLUGINS.md, Decision 22): JSON has exactly its six
  kinds, so a client's switch stays exhaustive against the resilient kit —
  the kit's one frozen enum.
- `EngineClock` — the master clock seam: current time and the absolute-deadline
  tick stream (see [CLOCK.md](docs/CLOCK.md)).
- `PlugIn` — the protocol every plug-in conforms to: identity plus an
  activation hook for registering capabilities.
- `BundledPlugIn` — a host-tier plug-in shipped as a bundle (2026-09-23;
  PLUGINS.md, Decision 23): a `PlugIn` that is a class with `init()`, named
  as the bundle's `NSPrincipalClass`; the host's bundle loader makes one
  instance and activates it exactly as it does a compiled-in plug-in.
- `PlugInKitVersion` — the kit's `MAJOR.MINOR.PATCH` (2026-09-23; Decision
  24), `current` naming this build's; parsed from the
  `com.moonwink.tingra.plug-in.kit-version` a bundle's Info.plist declares
  and compared before any of the bundle's code loads.
- `PlugInID` — the stable reverse-DNS identifier for a plug-in; doubles as its
  event domain.
- `MediaProviderID` — a stable identifier for a media input provider.
- `MediaInputProvider` — a plug-in's factory for media inputs: the uniform
  types it opens and `makeInput(for:id:)` creating the `Input` that plays a
  file; registered through `MediaRegistering` and resolved by the host's
  `MediaRegistry` by content type, the streaming-provider shape.
- `MediaRegistering` — the registration seam where media plug-ins attach their
  providers (register and unregister); resolution stays on the host's side.
- `MediaRegisteringError` — the error the unavailable registry throws: the
  host built its context without a media registry.
- `UnavailableMediaRegistry` — the default `PlugInContext.media`: a registry
  that accepts no providers and throws rather than discarding one, so a
  media plug-in loaded into a host without media reports itself.
- `PlugInContext` — the host infrastructure handed to a plug-in at activation:
  the event bus, the clock, and the input, output, effect, tool, and media
  registration seams (the media seam defaulted, a pre-1.0 addition).

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
  `PlugInContext`, reporting each outcome on the event bus (`plugin.activated`,
  or the `plugin.activation` error, each with `tier: "host"` — the app tier
  emits the same names with `tier: "app"`, see PLUGINS.md); a throwing plug-in
  is skipped, never fatal. `activate(bundles:in:)` activates loaded bundles
  the same way, their events adding `source: "bundle"` and the `path`, and
  `activate(_:thenBundlesFrom:in:)` is what every front end calls: the
  compiled-in plug-ins, then the bundles, compiled-in ids winning.
- `PlugInBundleLoader` — the host tier's external bundle loader (2026-09-23;
  PLUGINS.md, "The bundle loader: the design"): scans the user's and the
  machine's `Tingra/Plug-ins` folders once for `*.tingraplugin` bundles and,
  before any code loads, checks the Info.plist's id and kit version, the
  duplicate rule, and the signature (notarized when quarantined); then loads,
  casts the principal class to `BundledPlugIn`, and makes one instance.
  Every problem is a `plugin.bundle` `error` event. `canLoad(builtAgainst:in:)`
  is the version rule: majors equal and the bundle's minor not newer — before
  1.0.0, minors equal.
- `PlugInBundle` — a loaded bundle: its `BundledPlugIn` instance and its
  directory.
- `PlugInBundleScan` — one scan's result: the bundles loaded and the problems
  found, in scan order.
- `PlugInBundleProblem` — a refusal, or a defect in a bundle that loaded
  anyway, with its stable `Reason` (`unsigned`, `notNotarized`, `kitVersion`,
  `duplicateID`, `idMismatch`, `noPrincipalClass`, `loadFailed`, and
  `embeddedKit`, the one that does not refuse), the bundle, its id when
  known, and the developer-facing message naming the fix.
- `PlugInBundleInfo` — what a bundle's Info.plist declares: its id, its kit
  version, and its principal class name.
- `PlugInBundleOpening` — the seam under the loader that touches a bundle on
  disk (reads its declarations, lists its `Contents/Frameworks`, loads its
  code); `FoundationPlugInBundleOpener` is the production one, over `Bundle`.
- `CodeSignatureChecking` — the seam under the loader that admits a bundle's
  signature, returning a `CodeSignatureVerdict` (`valid`, `unsigned` with the
  Security framework's detail, `notNotarized`); `StaticCodeSignatureChecker`
  is the production one: `SecStaticCodeCheckValidity`, ad-hoc accepted, and
  the `notarized` requirement for a quarantined bundle.
- `AuthorizationPermission` — the three TCC grants capture depends on — `camera`,
  `microphone`, `screenRecording` — with raw values that are a stable contract.
- `AuthorizationStatus` — where one stands: `notDetermined`, `granted`, `denied`,
  `restricted`. Screen Recording reports only granted or denied, because
  CoreGraphics' preflight is a yes-or-no question that cannot tell a refusal
  from a permission never asked for.
- `AuthorizationChecking` — the authorization seam (ARCHITECTURE.md, "The
  host"): `status(of:)`, which never prompts; `request(_:)`, which prompts
  only for an undecided permission; and `reset(_:)` (2026-09-07), which asks
  the system to forget a decision so the permission reads undecided again —
  the one move an app can make on a TCC record. The app's Permissions pane
  and its tests run against it with a scripted answer.
- `AuthorizationError` — a recoverable failure from `reset(_:)`: the process
  has no bundle identifier to reset for, or `tccutil` refused, with its exit
  status and what it printed.
- `SystemAuthorization` — the production checker: AVFoundation for the camera
  and microphone, `CGPreflightScreenCaptureAccess` for Screen Recording —
  deliberately not `SCShareableContent`, whose read is the call that makes
  macOS show the Screen Recording prompt. Its reset spawns
  `tccutil reset <service> <bundle id>`, the system's own tool, since no
  framework offers the operation; `AuthorizationPermission.tccServiceName`
  names each permission's TCC service (`ScreenCapture`, not the framework's
  name).
- `OSLogSink` — the system-of-record sink: routes every event to OSLog
  (`subsystem` `com.moonwink.tingra`, `category` = domain), params `.private`.
  `tingra-cli` skips attaching it when standard error is a terminal — the OS's
  own terminal mirror already echoes the process's events there (see EVENTS.md,
  "OSLog sink").
- `LogLineFormatter` — the one shared human log line format (`LEVEL MM-DD-YYYY
  HH:MM:SS.mmm TZ [SSSS] @ domain name key=value`), reused by every text sink
  so each front end logs identically — the CLI's console (human mode) and file
  sinks and the app's console and file sinks (see EVENTS.md, "The human log
  line format").
- `LogSession` — the four-digit log session id stamped into every log line:
  incremented once per cold start and persisted in Application Support, a
  reliable cold-start anchor (distinct from the engine session in GLOSSARY.md).
  The counter file's location is public (`counterFileURL`), so the app lists
  and removes the same file this increments rather than a copy of the path.
- `FileSink` — the file sink: the shared human log lines appended to a file,
  every group, no filter; the file and its parent folder are created on the
  first event. `tingra-cli` attaches one for `--log-file`; the app attaches one
  always, over `LogFile.defaultURL`. Moved here from `tingra-cli` 2026-09-08,
  the second front end being the trigger (see EVENTS.md, "File sink").
- `LogFile` — the locator over the app's one log file
  (`~/Library/Logs/Tingra/Tingra.log`, `defaultURL`): its folder, whether it
  exists, its size, a dated snapshot copy for sharing (`Tingra Log
  2026-09-08.txt`), an in-place truncate that keeps a running sink writing,
  and (2026-09-12, for the log window) `lines(before:maxByteCount:)`, the whole
  lines in the bytes ending at an offset — the file's end by default, going
  back `chunkByteCount` (2 MB) — cut at a newline so consecutive reads meet
  with no line lost or doubled. Emits nothing — the `log.cleared` event is the
  app's to send.
- `LogFileError` — what `LogFile` refuses: `empty(URL)`, a snapshot asked of a
  log that does not exist or holds nothing.
- `LogFileChunk` — one `LogFile.lines(before:maxByteCount:)` read: the lines,
  oldest first, and the byte offset the first begins at, which is where the
  read for the lines before them ends (`hasEarlierLines`).
- `LogLevel` — the word a log line begins with (`INFO`, `DEBUG`, `ERROR`),
  derived from the event's group; public since 2026-09-12 because a `LogEntry`
  carries it.
- `LogEntry` — one log line read back (2026-09-12): the whole text and, where
  the line is in the human format, its level, log session ID, domain (none for
  a tap), name, and whether it is a tap. The reading half of
  `LogLineFormatter`, in the same file; a line not in the format keeps its text
  with no parsed parts rather than being dropped. The group and param values are
  not read back — a line does not carry them reliably.
- `OutputRegistry` — the actor where output plug-ins register their providers —
  streaming (resolved by destination URL scheme) and recording (resolved by
  file extension) — in one registry; the host's concrete `OutputRegistering`.
- `OutputRegistryError` — errors thrown by the output registry (a scheme, or a
  recording file extension, already served by another provider).
- `MediaRegistry` — the actor where media plug-ins register their
  `MediaInputProvider`s and the app resolves a file the operator added to
  the first provider whose content types it conforms to, by the file
  system's reported type or its extension; makes the input through that
  provider; the host's concrete `MediaRegistering`.
- `MediaRegistryError` — errors thrown by the media registry (a duplicate
  provider identifier, a file no provider opens, a URL that is not a file).
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
  Keychain and tests against an in-memory double. Beside the per-account
  read, write, and remove it lists the accounts it holds — the keys, never a
  value — and clears every item under Tingra's service in one call, which is
  what the app's Remove All Data uses so an orphaned key goes with the rest
  (2026-09-07). Its optional access group —
  resolved at runtime by `sharedAccessGroup()` from the running binary's own
  entitlements, so no Team ID appears in source — is the seam by which the app
  and `tingra-cli` would reach one another's keys. It resolves to nil in both
  today — `tingra-cli` cannot carry the restricted entitlement, and the app's
  entry was removed once there was no second party to share with — so the two
  do not share keys, and the seam stands ready for whatever replacement lands
  (DESTINATIONS.md).
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
- `ResourceRegistry` — the actor where the engine's observable state is
  registered as MCP `Resource`s for the MCP/Control service to list, read, and
  subscribe to (`register(_:)`, `resource(at:)`, `allResources`); host-owned
  for now — the app fills it from its model — with the plug-in-contributed
  seam deferred to PLUGINS.md Phase 4.
- `ResourceRegistryError` — errors thrown by the resource registry (a URI
  already registered).
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
- `PrivateAggregateDevice` — macOS's private aggregate audio devices
  (`CADefaultDeviceAggregate-<pid>-0`, built inside any process running an
  `AVAudioEngine`, Tingra's monitor included) and the two rules that keep them
  out of the input registry and out of a document: the composition's `private`
  flag for a live device, applied at discovery and on connect/disconnect with
  an `input.ignored` trace, and the UID prefix for a dead one, which the app's
  strip merge drops authored channels by (2026-09-09). A user's Audio MIDI
  Setup aggregate has neither and stays a microphone.

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
  float32 buffers with phase continuity, one per clock tick. The first input
  to declare parameters (2026-09-15): `frequencyParameter` (`frequencyHertz`,
  20 Hz–20 kHz, logarithmic) and `levelParameter` (`levelDecibels`, −60…0 dB,
  defaulting to half amplitude), applied live and phase-continuously through
  `setParameters(_:)` — a running phase accumulator, not a sample counter,
  so a retune bends the wave rather than breaking it.

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
  `setFormat(_:)` changes the program's size and rate live at a tick boundary —
  the tick reads the format into each snapshot, so a size change shows on the
  next render and a rate change re-arms the tick stream — reporting
  `program.format`; `format` reads it back.
  `setFadeToBlack(_:duration:)` ramps the program's picture to black and
  latches there across shot switches (`isFadedToBlack` reads the latch). It
  applies to whatever the tick rendered, so a fade and a transition can run at
  once; while the program is held fully black no layer tree is composited at
  all. Program only — preview is never faded, so the operator keeps working
  behind it — and picture only: `AudioMixer.setMasterFade(_:duration:)` is the
  other half.
- `MediaID` — a stable identifier for a media item in a project — and, by
  the same string, the `InputID` of the input that plays it.
- `ProjectMedia` — one file the operator added to a project as media: its
  `MediaID`, absolute path (no bookmark; the app is not sandboxed), and cached
  display name; the document's record from which the app asks the media
  registry for the input on each launch.
- `ProjectID` — a stable, string-backed identifier for a project document
  itself, not its file (a fresh UUID by default): what lets the app keep the
  operator's position per show outside the document (2026-09-13;
  ARCHITECTURE.md, "Projects as documents").
- `Project` — the saved document for a whole show: a versioned, plain `Codable`
  value type holding the optional `id` (absent in a document written before
  projects had one; the app assigns and saves it), the presets, the stream
  `destination` (key excluded — it
  lives in secure storage), each shot's optional default transition, the
  optional `programFormat` (absent meaning 1080p30), the optional `media`
  list, and the optional `plugInData` — project-scoped storage for app-tier
  plug-ins, keyed by plug-in id, each value opaque JSON the plug-in owns; an
  entry for a plug-in the build does not have round-trips untouched
  (PLUGINS.md, "Storage"), and the optional `inputParameters` — the values of
  the parameters the project's inputs declare, keyed by input id then by
  parameter key (PLUGINS.md, Decision 15), per project because an input's
  settings describe the input, not one preset's mix. The
  format is version 1 until the first release ships (pre-release it grows
  within v1, optional fields decoding forgivingly); decoding a document newer
  than the build understands throws rather than silently loading it.
- `DestinationReference` — a project's use of one destination: the saved
  destination's id plus whether this show streams to it. The name and URL live
  in the operator-global store, and the key in secure storage under the same
  id, so neither is written to the project. A document written before this
  change decodes unchanged — `Codable` ignores the `url` and `name` keys it no
  longer reads — keeping every id and enabled flag.
- `ProjectDestination` — **superseded by `DestinationReference`**; nothing
  writes it any more. The key-free destination configuration a `Project` once
  held (the RTMP(S)/SRT URL, a stable id, the operator's name, and an enabled
  flag). Kept because documents written before the change still carry its keys.
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
- `Shot` — a persisted composition with a stable `id` and user-facing `name`:
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
  rate) every frame is rendered at; `Codable` under those three keys because it
  is a project setting (`Project.programFormat`), with `aspectRatio` for the
  monitors that show it.
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
- `ShotRenderFailure` — why a `ShotRenderer` produced no frame for a tick (the
  output pool could not be created, could not vend a buffer, or Core Image could
  not complete the render — the out-of-`IOSurface` case that used to abort the
  process); every requirement throws it, typed, and the compositor skips that
  bus's tick and reports the episode as `program.stalled`/`preview.stalled`
  with the failure's stable `reason` token and `status` code (EVENTS.md,
  "Reporting a repeating failure").
- `VideoEffectFactory` — how a renderer resolves a layer's persisted chain
  entries into live `VideoEffect`s without depending on the host's effect
  registry: the app builds one from a boot-time snapshot of the registry and
  passes it to the renderer it injects. Returning nil for an unavailable
  effect leaves that slot a pass-through.
- `CoreImageShotRenderer` — the default renderer: composites the layer tree with
  a Metal-backed `CIContext`, GPU-resident, into an IOSurface-backed 32BGRA
  program buffer tagged BT.709 (a software `CIContext` makes the compositing
  math unit-testable with no GPU; `init(context:makeVideoEffect:)` is public
  since 2026-09-13 so a front end can hand in the context it draws with, and
  `composedImage(shot:frames:format:)` hands the layer-tree graph back as a
  lazy `CIImage` for a monitor to draw at its own size); dissolves alpha-blend the two layer trees,
  wipes blend them behind a soft-edged swept gradient mask, shader
  transitions blend through the first-party stitchable Metal kernels, compiled
  once at first use from compiled-in source, and the fade stage composites
  opaque black over the finished program frame at the ramp's alpha — the same
  alpha math a dissolve uses, so both share one ramp character. A layer's effect chain is applied
  to its own image before placement (cropped back to its extent, and the extent
  that remains — a crop's kept region — is what fills the layer's frame), composing
  lazily so the whole chain fuses into the one render pass; instances are cached
  per layer and rebuilt only when the layer's configurations change.

- `VideoEffectChain` — one layer's live effect chain (2026-09-10;
  ARCHITECTURE.md, "The effect chain says its order, and the layer gets a
  monitor"): the instances built from its persisted configurations, in signal
  order, and `apply(to:)`, which runs them and crops to the input's extent —
  shared by the renderer (one per shot and layer, replacing its private cache)
  and the app's layer monitor, so a picture is processed the same wherever it
  is drawn.
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

- `EffectPlugIn` — contributes the built-in audio and video effects through
  the effect registration seam.
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
- `FrameEffectProvider` / `FrameEffect` — a layer's rounded corners and
  inside border (2026-09-09; ARCHITECTURE.md, "The Frame effect"):
  `cornerRadius` (0…0.5) and `borderWidth` (0…0.1) as fractions of the
  image's shorter side (unit `%`, so the app shows them as percent), both
  `0` by default so a fresh Frame draws nothing,
  and `borderColor` (an `EffectColor`, opaque white) — a rounded-rectangle
  mask and a source-out ring over built-in Core Image generators, cropped
  to the source extent.
- `CropEffectProvider` / `CropEffect` — a layer showing only part of its
  input's picture, a portrait strip out of a landscape camera (2026-09-09;
  ARCHITECTURE.md, "The Crop effect"): four insets `left`, `top`, `right`,
  `bottom`, each a fraction (0…0.9) of the width or height cut from that
  edge (unit `%`, shown as percent), all `0` by default; top is the picture's top; the kept rectangle is
  rounded out to whole pixels and is also the declared output extent, and
  insets that meet pass the image through untouched.

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

## `packages/TingraMediaPlugIns`

- `MediaPlugIn` — contributes the image, movie, and text providers through the
  media registration seam; registration is all or nothing, rolling back on a
  refusal.
- `MediaInputError` — errors a media input throws from `start()`: a file that
  cannot be read, an image ImageIO will not decode, text that is not UTF-8, a
  movie without a video track or that AVFoundation refuses, and the two
  buffer failures.
- `ImageMediaProvider` — the provider for every image type ImageIO reads.
- `ImageInput` — a still image as an input: decoded once at start into one
  BT.709-tagged BGRA buffer (long side capped at 3840, orientation applied,
  alpha kept), delivered once per consumer and held.
- `MovieMediaProvider` — the provider for every movie type AVFoundation reads.
- `MovieInput` — a video file as an input: `AVAssetReader` paced by the master
  clock at the file's rate, presentation times remapped from the start tick,
  looping continuously; the audio track arrives as `CapturedAudio` on the
  same timeline, so the file gets a channel strip.
- `TextMediaProvider` — the provider for plain text and Markdown.
- `TextInput` — a text or Markdown document as an input: rendered once onto a
  transparent 1920×1080 canvas in white system type (Markdown headings,
  emphasis, code, and list items mapped onto a fixed ramp), delivered once
  per consumer and held.

## `packages/TingraJSONRPC`

- `JSONRPCID` — a JSON-RPC 2.0 request/response identifier, a string or an
  integer, carried verbatim so a response echoes exactly the id it answers.
- `JSONRPCErrorCode` — the five standard JSON-RPC error codes (parse error,
  invalid request, method not found, invalid params, internal error) and MCP's
  own `resourceNotFound` (`-32002`); a tool that runs and reports a failure is
  not one of these — it returns a normal result with `isError` set.
- `JSONRPCError` — the error object a response carries in its `error` member;
  also a Swift `Error`, so a method handler throws the exact protocol error a
  session should answer with.
- `JSONRPCIncoming` — an incoming message as a peer receives it: a request
  (method and id), a notification (method, no id), or a response to a request
  this side sent (id, no method), decoded before dispatch decides which.
- `JSONRPCResponse` — an outgoing response: exactly one of `result` or `error`,
  and the request's id echoed (`success(id:result:)`, `failure(id:error:)`).
- `JSONRPCNotification` — an outgoing method call with no id, so no response
  follows; how the daemon's status changes reach connected sessions.
- `MessageCoder` — the one encoder/decoder configuration every peer shares:
  sorted keys, so a payload is stable for tests and logs, and unescaped
  slashes, so `tools/call` reads as written.
- `MessageTransport` — the seam under a session: a duplex, message-level
  channel that owns its own framing (newline delimiting on a socket, one XPC
  message per payload), so session logic never touches bytes. The daemon's
  implementation is `SocketMessageTransport` in TingraMCP; the app tier's is
  `XPCMessageTransport`.
- `SurfaceMessage` — one message with what rode beside it: the JSON payload
  and the `IOSurface` the sender attached, if any — pixels in shared memory
  (a program frame for an app-tier plug-in), the one value JSON cannot carry.
- `SurfaceMessageTransport` — the `MessageTransport` refinement that can carry
  an `IOSurface` beside a message (`readSurfaceMessage()`,
  `writeMessage(_:surface:)`): the XPC and in-memory transports; a socket
  cannot, so the daemon's does not conform.
- `InMemoryMessageTransport` — the test transport: inbound payloads enqueued by
  the test, everything the session writes collected, no socket and no process;
  a `SurfaceMessageTransport`, so a linked pair hands a surface across too.
- `LinkedMessageTransports` — two in-memory transports joined so what one
  writes the other reads (`makePair()`): a client and a server run against
  each other in one process, which is how an extension's `PlugInConnection` is
  tested against the app's endpoint.
- `AsyncQueue` — a single-consumer async FIFO bridging blocking producers (a
  socket reader thread, an accept loop, an XPC delivery) into structured
  concurrency, strict-concurrency clean: a lock-guarded buffer with one
  suspended waiter, never an `AsyncStream` iterator smuggled across an
  isolation boundary.
- `XPCMessageChannel` — the one `@objc` protocol an `NSXPCConnection` carries
  between the app and an extension process: `open()` to establish the link (a
  connection exists only from its first message) and `deliver(_:)` for one
  JSON-RPC payload per XPC message, in both directions — or
  `deliver(_:surface:)`, the payload with an `IOSurface` attached. A byte channel, never a
  second RPC protocol; `nonisolated` explicitly, because XPC calls it on the
  connection's own queue.
- `XPCMessageTransport` — the `MessageTransport` over an `NSXPCConnection`: the
  app-tier link between Tingra.app and an ExtensionKit extension, carrying the
  same MCP JSON-RPC the daemon speaks over its socket — a
  `SurfaceMessageTransport`, so a frame's surface rides beside its
  notification. The side that made the
  connection passes `opening: true` and sends the establishing message; `End`
  (`interrupted`, `invalidated`) tells the `onEnd` handler how the peer went
  away.
- `XPCMessageTransportError` — what a write can get wrong beyond what XPC
  itself reports: the connection offered no channel proxy, so the peer is not
  a Tingra app-tier endpoint.

## `packages/TingraMCP`

- `Daemon` — the engine daemon (`tingra-cli serve`): accepts connections on a
  Unix domain socket, verifies each peer's uid, serves each as an independent
  `MCPSession` against the shared engine, and idle-exits when quiet but never
  mid-stream. `manual(socketPath:…)` binds its own socket; the launchd
  socket-activated path uses `init` with a supplied descriptor.
- `MCPSession` — one per-connection MCP session (public since 2026-09-13, so
  the app runs one over each extension's XPC link): the `initialize` handshake
  (carrying the endpoint's build version), `tools/list`, `tools/call` dispatch,
  the `resources/list`, `resources/read`, `resources/subscribe`, and
  `resources/unsubscribe` methods over a `ResourceRegistry` (a subscription
  forwards the resource's change signals as `notifications/resources/updated`
  until unsubscribed or the session ends; an unknown URI is MCP's `-32002`),
  and status-change notifications fed by the status sink; an optional
  `SessionMethodHandler` answers the endpoint's own methods beyond MCP, and
  `request(_:params:)` sends a server-initiated request to the peer — the app
  asking an extension to perform a command — with `server-`-prefixed string
  ids that never collide with the client's numeric ones.
- `SessionMethodHandler` — the seam an endpoint plugs its own methods into —
  the app tier's `tingra/*` storage and event methods — so `MCPSession` stays
  one session type for the daemon's socket and the app's XPC link; returns nil
  for a method it does not own, and the session answers method-not-found.
  `sessionOpened(notifier:)` and `sessionClosed()` (both defaulted to nothing)
  bracket the session's run, so a handler can send notifications of its own
  and end what it started.
- `SessionNotifier` — how a `SessionMethodHandler` sends its session's peer a
  notification (`notify(_:params:)`), optionally with an `IOSurface` attached
  (`notify(_:params:surface:)`, sent only over a transport that can carry
  one); holds the transport, never the session.
- `SessionRequestError` — what a request the session sends to its peer can get
  wrong: the session closed first, the transport refused the write, the peer
  answered with a JSON-RPC error, or its response did not decode.
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
  `JSONRPCNotification`, `JSONRPCIncoming`, `MessageCoder`, `MessageTransport`,
  and the transports — moved to `TingraJSONRPC` on 2026-09-13 so the app
  tier's extension side can speak the protocol without linking the daemon or
  the host, and re-exported here (`@_exported import TingraJSONRPC`) so
  `import TingraMCP` sees them exactly as before; listed under that package.
- `MCPProtocol` — the MCP method names (the tools' and the resources'),
  notification names, and the protocol version the daemon speaks.


## `packages/TingraAppPlugInKit`

- `PaneID` — the identifier of a pane an app-tier plug-in declares: the plug-in
  id and a name joined with a dot (`com.moonwink.tingra.notes.pane`), so panes
  from different plug-ins never collide.
- `CommandID` — the identifier of a command, unique within its plug-in
  (`show`); the app qualifies it with the plug-in id where a global name is
  needed, as in the `tap` event's name.
- `StatusItemID` — the identifier of a status item, unique within its plug-in
  (`link`), like a `CommandID`.
- `SidebarPosition` — which sidebar a pane would like: `leading`, `trailing`,
  or `bottom` — a preference the app may override, and in Phase 1 every pane is
  hosted in the trailing sidebar.
- `PaneDescriptor` — a pane a plug-in contributes to a sidebar: id, title,
  symbol, preferred sidebar, and the `sceneID` of the extension scene that
  draws it; the app hosts it in shared chrome, the extension's process draws
  it.
- `ShortcutDescriptor` — a keyboard shortcut as a manifest declares it, one key
  and named `Modifier`s (`command`, `option`, `shift`, `control`) — `Codable`,
  which SwiftUI's `KeyboardShortcut` is not; the app turns it into one.
- `CommandPlacement` — where a command appears; Phase 1's one case,
  `plugInMenu`, is the plug-in's submenu of the app's Plug-ins menu.
- `CommandDescriptor` — a command a plug-in contributes: id, title, optional
  shortcut, placement, and the pane it reveals (`showsPane`) or the window it
  opens (`showsWindow`); the app renders
  the menu item before the extension has run and forwards the invocation after
  emitting the `tap` itself.
- `SettingsPaneDescriptor` — a settings pane a plug-in contributes to the
  Settings window: a row in its source list, and a remote view like any pane.
- `WindowDescriptor` — a window a plug-in contributes: a pane hosted in a
  window of its own rather than a sidebar — id (a `PaneID`, so
  `pane(for:)` answers for it), title, and the `sceneID` of the scene that
  draws it; opened by a command naming it (`showsWindow`).
- `StatusItemDescriptor` — a status item a plug-in contributes to the windows'
  status bar: id, title (the tooltip and VoiceOver's name for the reading),
  and symbol. The app draws the reading from a text the plug-in sets
  (`PlugInConnection.setStatusText(_:for:)`); no scene is hosted for it, and
  it reports and never acts.
- `MeterLevel` — one meter's level over a window of the mix: `peak` and `rms`
  as linear sample magnitudes (`1` is full scale), `floor` for silence,
  `decibels(_:)` for display, and the `{"peak", "rms"}` JSON it travels as.
- `MeterLevels` — one `tingra/meters` notification: the window's `time`, every
  live strip's pre-fader level by `InputID`, and the master's post-fader left
  and right; `jsonValue` and `init?(jsonValue:)` are the wire shape.
- `FrameBus` — a video bus whose frames a plug-in can follow: `program` or
  `preview`.
- `BusFrame` — one frame of a bus as it reaches a plug-in: the app's own
  `IOSurface` (nil when the bus is empty), the bus, and the time; shared
  memory, to draw and never to write or keep. `jsonValue` is the JSON half of
  `tingra/frame`; `init?(jsonValue:surface:)` reads it with its attachment.
- `BusMonitorView` — the ready-made bus monitor for a plug-in's pane: each
  frame's surface becomes a layer's contents, aspect kept, over black,
  following the bus only while on screen.
- `ActivationCondition` — a bus event that wakes the plug-in, written in the
  manifest's `activation` list as one string: the event's name, optionally
  followed by `:key=value` naming one param the event must carry
  (`stream.started`, `device.connected:kind=camera`); `init(parsing:)` reads
  that form, `rawValue` writes it, `matches(_:)` tests an `EventBusEvent` by
  name and by the param's string form, and `Codable` travels as the string.
  The nested `Qualifier` is the key and value.
- `ActivationConditionError` — what can be wrong with a condition's text, each
  naming the fix: an empty or malformed event name, or a qualifier that is not
  `key=value`.
- `PlugInManifest` — what a plug-in declares about itself (id, name, panes,
  commands, settings panes, windows, status items, activation conditions),
  read by the app from the
  extension's Info.plist under `EXAppExtensionAttributes` → `TingraPlugIn` at
  discovery, before the extension has ever run; `init(bundle:)` decodes it,
  and a manifest that does not decode is a `PlugInManifestError`.
- `PlugInManifestError` — what can be wrong with a manifest, each naming the
  fix: a required key absent, a dictionary that does not decode, a pane id
  or window id outside the plug-in's namespace, a repeated pane, command,
  status item, or activation condition.
- `AppTierMethod` — the JSON-RPC methods the app tier adds beside MCP's own,
  spelled once for both sides: `tingra/event`, `tingra/storage.get`,
  `tingra/storage.set`, `tingra/secrets.get`, `tingra/secrets.set`,
  `tingra/statusItem.set` (extension → app) and `tingra/command.perform`, `tingra/activation`
  (app → extension), with their parameter keys as the nested `EventParam`,
  `StorageParam`, `SecretParam`, `StatusItemParam`, `CommandParam`, and
  `ActivationParam`.
- `StorageScope` — where a plug-in's stored value lives: `project` (in the
  document — travels and saves with it, dirties it like a layer edit) or
  `application` (this Mac, under the app's Application Support folder); never
  secrets, which go through `tingra/secrets.*` to the Keychain.
- `PlugInConnection` — the extension's end of one connection to the app: an
  MCP client over a `MessageTransport` that runs `initialize`, calls the app's
  tools (`call(_:arguments:)`) and lists them, lists the app's resources
  (`resources()`), reads one (`read(_:)`), and follows one (`observe(_:)`, an
  `AsyncStream` yielding the document now and after each updated
  notification, unsubscribing when its consumer stops), files `event`s and
  `error`s on the app's bus under the plug-in's domain, reads and writes
  project- and application-scoped storage and the plug-in's own secrets
  (`secret(named:)`, `setSecret(_:named:)` — Keychain items the app files
  under the plug-in's id, a refused write thrown rather than dropped), gives
  a declared status item its text (`setStatusText(_:for:)`, nil removing
  the reading), follows the app's meters (`meters()`, an `AsyncStream` of
  `MeterLevels` that subscribes with its first consumer and unsubscribes with
  its last) and a bus's video (`frames(_:)`, an `AsyncStream` of `BusFrame`
  circulating one demand at a time, newest wins), and answers the two requests the
  app makes of it, a command to perform and an activation condition met (the
  `CommandHandler` and `ActivationHandler` it is created with). One per
  `NSXPCConnection` the app opens; the kit creates them, an author receives
  them.
- `PlugInConnectionError` — what a connection call can get wrong: the
  connection is closed, the transport reported an error, the peer answered
  with a protocol error, a tool reported an error, or a response did not
  decode.
- `DebouncedWriter` — coalesces a stream of values into one write after the
  stream pauses, so a text editor's keystrokes become one storage write per
  pause rather than one per key; the last value wins, and `flush()` writes it
  now, for a pane about to disappear.
- `PlugInRuntime` — the extension process's `@Observable @MainActor` view of
  its connections: one `PlugInConnection` per connection the app opens and the
  most recent as `connection`, read by a pane through
  `@Environment(PlugInRuntime.self)`; one `shared` runtime per process.
- `TingraAppExtension` — what a plug-in's `@main` type adopts: ExtensionKit's
  `AppExtension` with the boilerplate owned by the kit — the author supplies
  `pane(for:)` and `perform(_:using:)`, optionally `activated(by:event:using:)`
  (a do-nothing default) for the activation conditions the manifest declares,
  and the default `configuration` turns the manifest into one scene per pane
  and settings pane, accepts every connection the app opens, and runs the MCP
  handshake on each.
- `PlugInCommandHandler` — the `AppExtensionConfiguration` behind that default:
  accepts the app's command connection and hands it, and each pane scene's
  connection, to `PlugInRuntime` with the command and activation handlers.

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
  shots — add (empty, or showing a chosen input), duplicate, rename, reorder,
  remove, and keep — stages a clicked input as a **transient** shot that is
  promoted when kept, edited, or aired and discarded when the operator stages
  something else (never written to the document), applies layer-tree edits to
  the active shot, starts and stops each channel strip's device as it is unmuted and
  muted, and puts the program on air by feeding the compositor's frames and the
  mixer's blocks to a `StreamSession` program source fanned out to every enabled
  destination, each destination's stream key held in Keychain-backed secure
  storage under its own id — reflecting the session's `StreamStatus` and each
  leg's `DestinationState` from the bus's `stream.*` events, never a poll, and
  takes the whole program off air with `setFadeToBlack(_:duration:)` — the one
  control driving both engine surfaces, which lives here because
  `TingraComposition` and `TingraAudio` depend on each other in neither
  direction.
- `LeadingSidebar` — the main window's leading sidebar (GLOSSARY.md, "Sidebar"; `SidebarView` until 2026-09-10): the project's presets, the
  active one's shots, the video generators, the project's media files, the
  audio generators, every camera, display, audio input device, and audio
  output device this Mac can see, and the destinations the program streams
  to, in ten sections. The Cameras and
  Displays headings are plain headings: the casting pickers they carried from
  2026-09-09 were removed on 2026-09-13. It is a standard
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
  the shot bank's tiles carry, red on air and green staged, from the shared
  `Tally` tints; only the call differs, `setPreview(_:)` for a shot,
  `stagePreview(showing:)` for an input, and `switchPreset(to:)` for a preset —
  which is also why the active preset wears a checkmark rather than a lamp,
  since a preset is not on a bus and red means on air everywhere else in the
  app. An input row's click stages a transient shot; the row is also draggable
  onto the shot bank (a full-frame authored shot) and the layer list (a layer),
  and its context menu offers Add Shot Showing … (2026-09-07). Nothing reaches
  program from here. Every section collapses, with the
  standard source-list disclosure, and which ones are folded away persists
  across launches. A shot row carries the shared shot context menu
  (`ShotContextMenu`: Duplicate, Rename…, Default Transition, Move Up / Move
  Down, and Delete, which raises a confirmation naming the shot before anything
  is removed — unlike the shot bank's Remove Shot, which is immediate); a
  destination row carries a Delete of its own, whose confirmation says that the
  stored stream key goes with it. Two controls pinned to the sidebar's bottom
  edge, the Add Shot menu (`AddShotMenu`) over Add Preset, made a new one of
  each (2026-09-07), until the Add Shot row went the same day — adding a shot
  is now the Shots section header's context menu, an Add Shot submenu of the
  shared `AddShotMenuItems`, leaving Add Preset alone at the bottom. The
  audio and destination rows otherwise read rather than switch — the channel
  strips, the monitor picker, and the streaming panel already own those
  decisions — and listing a device starts nothing, so no camera indicator lights
  for the sidebar.
- `SidebarRow` — the pure, unit-tested row derivation behind it: one identity
  across shots, presets, capture devices, destinations, and Core Audio outputs;
  the shot tally with red winning over green; the checkmark that marks the
  active preset without borrowing the tally's colours; the `kind` filter that
  keeps a generator out of a device list and gives the audio generators a
  section of their own; and the name sort that stops the output section
  reshuffling when Core Audio reorders itself.
- `SidebarSection` — the closed list of the sidebar's ten sections, each
  deriving its own persistence key and its own disclosure `tap` name, so a
  section added without an entry does not compile.
- `SidebarPreferences` — which sections are open: machine-local `UserDefaults`
  on the `MonitorPreferences` pattern — window habits are not part of the show,
  and a source list that forgot its collapsed sections each launch would read as
  a bug. A section nothing is stored for reads open, so the default is the
  absence of a value rather than its content.
- `ContentView` — the main window's detail column, in two sections — a
  monitoring section across the top, the preview and program monitors side by
  side across the full width, each captioned beneath with the name of the shot
  on its bus (2026-09-07), with the **shot bank** (`ShotBankView`) beneath them
  under a **Shots** heading, over a control section holding everything the
  operator works. The whole column scrolls, and the monitoring section's height
  is derived from the window's width — two 16:9 monitors have no use for
  surplus vertical room, and a plain stack resolved a shortfall by collapsing
  the monitors and pushing the pickers off the bottom edge. The control section
  holds the `TransitionPanel`, the layer editor, and the mixer (the
  camera/display casting pickers moved to the sidebar's Cameras and Displays
  headings on 2026-09-09 and were removed on 2026-09-13, and the selected
  layer's controls to a trailing
  inspector column, `LayerInspectorColumn`, toggled by ⌥⌘I and the toolbar's
  trailing button); Start/Stop and Record are toolbar items, and the streaming
  and recording panels that closed the column became the Streaming and
  Recording settings panes on 2026-09-08 — destinations and the recording
  folder are set up before a show, and the column is for working one. Shots
  are staged from the bank, the
  sidebar's shot rows, and by number from the Shots menu; presets are made and
  managed in the sidebar. (The optional Program and Preview rows of shot
  buttons, and their General settings checkbox, lived here for one day and
  went with the bank — ARCHITECTURE.md, "The shot bank".)
- `TransitionPanel` — the Cut, Take, and transition controls under their own
  heading (2026-09-07), on **one row**: Cut and Take lead as a matched large
  pair (since 2026-09-13), Take prominent and red, both disabled with a
  one-line hint while nothing is staged; then a pop-up menu naming the armed
  transition — Default (each shot's own default transition, the initial
  selection), or an explicit Cut, Dissolve, Wipe, or Shader — with the wipe
  edge or shader name beside it while that kind is selected; and beside
  those a **Duration** field and stepper in seconds (0–10 s, tenths),
  the panel's one rate knob applied to every timed take, a shot's default
  included, disabled while Cut is armed. Time, not frames: the compositor
  converts to ticks at take time. Cut ⇧⌘↩ and Take ⌘↩ stay on the buttons.
  Fade to Black left the panel for the toolbar on 2026-09-07
  (`FadeToBlackButton`): it is a master stage, not a transition.
- `FadeToBlackButton` — the latching Fade to Black control in the main
  window's toolbar, leading Start Streaming and Record (2026-09-07): it takes
  the whole program off air, picture and sound together, stays available when
  the preset has no shots, reads Fade Up with a filled red frame while
  latched, and keeps ⇧⌘B and the `fadeToBlack.button` tap. The panel's
  "viewers see and hear nothing" hint went with it — the program monitor's
  badge already says so.
- `SettingsButton` — the gear at the trailing end of the main window's toolbar
  (2026-09-09), in an item of its own after the three on-air controls, opening
  the same settings window as the app menu's Settings… (⌘,). It is the one-click
  route to the Streaming and Recording panes that took the outputs' setup out
  of the main window the day before; the shortcut stays on the menu item, and
  the `settings.button` tap tells its clicks from the menu's `settings.menuItem`.
- `DestinationListView` — the Streaming settings pane's destination list: one
  form **section** per destination the program fans out to, headed by its name,
  with an enable switch, a name, a URL, a secure stream-key field, its own live
  state while streaming — its bitrate and frame rate while delivering, or
  Reconnecting/Refused/Lost when it alone is in trouble — and Remove
  Destination, which also clears its stored key; then an Add Destination
  section. Sections rather than the one-line rows the main window's streaming
  panel drew until 2026-09-08, since a settings form is a third of that column's
  width. Fields lock while streaming, since v1 adds and removes destinations
  between runs. The key is filed in the Keychain **as it is typed**
  (`EngineModel.setStreamKey`) and prefilled from there: Start Streaming sits in
  another window now and reads the keys back at the click.
- `DestinationEdit` — the pure, unit-tested destination state behind those rows,
  merged from the two places a destination lives: the name and URL from the
  operator's `StoredDestination`, the enabled flag from this project's
  `DestinationReference`. The URL is held **as text** while it is typed and
  becomes a `StoredDestination` only once it carries a supported scheme and a
  host — so a half-typed URL never reaches the store every project shares — and
  an edited URL keeps its id and therefore its stored key. Lists the store in
  store order: a destination this project never referenced appears disabled
  rather than surprise-live, and a reference to one the operator deleted is
  dropped.
- `MixerView` — the mixer panel: one channel strip per authored audio channel
  and per discovered audio input, each a **column** with a console strip's
  anatomy (2026-09-12, ARCHITECTURE.md "The console mixer"; one row per strip
  before that): the name, an Effects button badged with the chain's length, a
  pan slider that recenters on double-click, the peak-hold readout, a dB
  **fader standing beside the meter** over one travel, the level readout in
  decibels, and the mute — the strips side by side in a horizontal scroll, so
  many inputs grow the panel sideways; a strip whose device is absent stays on
  the panel, marked not connected, its settings kept for the device's return —
  with the **master column** standing at the panel's trailing edge outside the
  scroll, the console's master section (2026-09-08), as two headed groups
  divided from each other: **Master**, the peak-hold readout over the
  post-fader stereo master meter, and **Monitor**, the device picker over the
  operator's own monitor level fader (unity at its top), its dB readout, and
  the monitor mute (2026-09-09; the control room cut, keeping device and level
  while silencing playback, the same control as a strip's mute). A
  double-click returns a fader to unity. There is deliberately no master
  fader — the engine has no master gain of the operator's, and the monitor
  level scales only what the operator hears (TODO.md, "Does the recorded mix
  need a master fader?").
- `FaderScale` — the pure, unit-tested mapping between a fader's travel and
  the linear gain it stands for (2026-09-12): a breakpoint table linear in
  decibels between stops — silence at the bottom, −60 dB a tenth of the way
  up, unity three quarters up, +6 dB at the top for a strip (`strip`); the
  same table cut at unity and stretched so unity is the top for the monitor
  (`monitor`, since its playback gain clamps at 1) — with position ⇄ gain
  conversions, the decibel helpers, and the readout's formatting (one decimal,
  explicit sign, nil at silence). Presentation only: the document and the
  engine keep linear gain.
- `EffectChainView` — one strip's audio effect chain, in a popover: slots in
  signal order with Move Up / Move Down / Remove, an Add Effect menu over every
  registered audio effect, and a slider paired with an `EffectParameterField`
  (or, for a color parameter, an `EffectColorWell`) per parameter the effect
  declares — drawn generically from its `Parameter` descriptors, so a
  third-party effect gets parameter UI without the app knowing it exists;
  the slider's travel runs through `ParameterScale` since 2026-09-15.
- `InputParametersView` — one input's declared settings, in a popover off its
  channel strip's Input Settings button (2026-09-15; PLUGINS.md, Decision 15):
  a slider paired with an `EffectParameterField` per number parameter and an
  `EffectColorWell` per color parameter, drawn from the input's `Parameter`
  descriptors alone, applying live through `EngineModel.setInputParameter`
  (which stores the value in the project's `inputParameters`, hands the whole
  payload to the input in order through one chained task, and autosaves
  debounced). The strip shows the button only for an input in
  `EngineModel.declaredInputParameters` — the tone today — so a microphone's
  strip is unchanged.
- `ParameterScale` — the pure, unit-tested mapping between a declared
  parameter's value and a slider's `0…1` travel, honoring `Parameter.Scale`:
  linear spans, or equal ratios for a logarithmic parameter whose range is
  strictly positive (falling back to linear otherwise, never a NaN). Every
  generic parameter slider — both chain editors and the input settings — goes
  through it, so 440 Hz sits near the middle of a 20 Hz–20 kHz slider.
- `CommittingNumberField` — the numeric field every inspector and chain-editor
  number goes through (2026-09-10): commits once, on Return or focus loss,
  never per keystroke; keeps its own text while focused, parses in the
  user's locale (`parse`/`formatted`, tested), shows what the holder kept
  after a clamp, and refreshes when the value changes from outside.
- `EffectChainHeading` / `EffectSlotOrdinal` — what both chain editors share
  to say that order matters (2026-09-10): the "Effects" heading (a headline in
  the audio popover, a caption in the inspector) over "Applied in order, top
  to bottom", and the "1." / "2." ordinal before each slot's name.
- `EffectParameterField` — the editable value field both chain editors draw
  beside a number parameter's slider (2026-09-10; ARCHITECTURE.md, "Effect
  parameters show and take their value"): the value in the parameter's unit,
  typed values clamped to its range and committed once on Return or focus
  loss. `EffectParameterFormat` holds the pure conversions: a `%` unit means
  a stored fraction shown and typed as percent; other units show as stored
  with no fraction digits, a unitless value with one.
- `UnsupportedParameterRow` — the row every parameters editor (both chain
  editors and the input settings) draws for a declared parameter whose
  `Parameter.Kind` this build does not know — the kit's enums are open under
  Library Evolution (2026-09-23; PLUGINS.md, Decision 22), so a bundle built
  against a later kit can declare one: the parameter's name and "Needs a
  newer version of Tingra".
- `EffectColorWell` — the control both chain editors draw for a color
  parameter (2026-09-09): an AppKit `NSColorWell` in its minimal style (a
  swatch popover at the well, "Show Colors…" inside it for the panel),
  wrapped by `ColorWellRepresentable`, that coalesces the well's continuous
  changes into one gesture — begin on the first change, apply live, end (one
  undo step, one `tap`) after half a second of quiet — with the `NSColor` ⇄
  `EffectColor` conversions beside it.
- `MixerStrip` — the pure, unit-tested strip state: the merge of the active
  preset's authored `AudioChannel`s with live discovery — authored channels
  first in document order, new devices appended muted — falling back to the
  seeding policy, first *captured* input unmuted at unity — never a generator,
  which would put a test tone on air — the rest muted, every strip centered,
  when nothing is authored; strip edits sync back into the active preset and
  autosave debounced like shot edits.
- `MuteLabel` — the label every mute toggle shares, a strip's and the
  monitor's: the speaker symbol, slashed while muted, sized to the union of
  both symbols (each laid out hidden under the visible one) because they
  differ in glyph width and height and a bordered button sizes to its label —
  so a mute button never changes size as it flips (2026-09-09).
- `StripMeter` — one strip's meter: a capsule standing beside the strip's
  fader over the same travel, showing the strip's pre-fader signal.
- `PeakReadout` / `PeakSubject` — a meter's peak-hold readout (2026-09-12):
  the held peak in dBFS to one decimal above the meter, `−∞` until anything
  is metered, red (and "over" to VoiceOver) once the hold reached full scale;
  a plain button that resets the hold, reporting `meterPeak.reset` with the
  subject's id — a strip's input id, or `master`. Samples the relay in a
  ten-hertz `TimelineView`, never through observation.
- `MasterMeter` — the master's meter: two capsules showing the program mix
  post-fader, one per program channel — stereo because the master is where the
  operator judges the stereo image; standing, left beside right, over the same
  travel as the monitor fader next to it.
- `MeterCapsule` — the one capsule both meters draw, so the scale, the zone
  boundaries, and the ballistics can never drift between two meters read side by
  side — an RMS bar over broadcast green/yellow/red zones with a decayed peak
  marker, drawn at display cadence in a `TimelineView` sampling the shared
  `MeterRelay` the model's meter drain fills, so readings never churn SwiftUI
  observation. Fills along one axis — upward standing beside a fader, every
  meter on the panel since the console layout, or rightward lying down —
  through unit-tested geometry helpers.
- `MeterRelay` — the lock-guarded, nonisolated holder the meter drain writes
  off the main actor and the meters sample on it: the latest tick's strip
  readings and master reading, plus each meter's **peak hold** (2026-09-12)
  — the loudest sample since its last reset, folded **per block** by
  `fold(_:)` rather than at draw time, so a hot block while the window is
  occluded is held all the same; `resetPeak` per strip and `resetMasterPeak`.
  Unit-tested.
- `ProgramFrameRelay` — the lock-guarded, nonisolated holder of the latest
  program (or preview) frame (2026-09-12, ARCHITECTURE.md "Bounded frame
  streams"; a `@MainActor` class before that): the program drain stores off
  the main actor, the `MTKView` coordinator reads `latest` at display cadence,
  and the preview relay stops accepting — emptying itself — while nothing is
  staged. A `MonitorFrameSource`. It also numbers every change (a store, an
  emptying), and `next(after:)` answers with the `Update` past a number — at
  once, or as soon as there is one — which is how a frame reaches an app-tier
  plug-in with nobody polling. Unit-tested.
- `ProgramTee` — the lock-guarded, nonisolated tee the program and
  program-audio drains yield every frame and block into (2026-09-12): the
  stream session's and the recording session's leaves attach and detach on
  the main actor, a detach finishes the leaf's stream, and an attach over a
  leaf finishes the one it replaces — the four continuations the model used
  to hold, in one place the drains can reach without the main thread.
  Unit-tested.
- `VerticalSlider` — a vertical slider: an `NSSlider` standing on end behind
  `NSViewRepresentable`, mirroring `Slider(value:in:onEditingChanged:)` — the
  binding updates through the drag and the editing callback brackets it, so the
  drag-end `tap` convention holds — with control size and enablement mirrored
  from the SwiftUI environment. SwiftUI's `Slider` lays out horizontally only.
  Its unit-tested `Coordinator` turns AppKit's continuous action stream into
  that shape, and forwards a double-click to an optional `onDoubleClick` — the
  fader's return to unity (2026-09-12) — caught by `FaderSlider`, the
  `NSSlider` subclass beneath it, before AppKit would track it as a drag.
- `MeterBallistics` — the unit-tested draw-time ballistics: instant attack,
  20 dB/s decay on a −60…0 dBFS scale.
- `SessionPreferences` / `SessionPosition` — where the operator's position
  persists between launches (2026-09-07): the active preset, the shot on
  program, the shot staged on preview, and the transition armed on the
  switcher (its kind, the wipe edge, the shader, and since 2026-09-13 the take
  duration in seconds), as ids and raw values in
  machine-local `UserDefaults` on the `MonitorPreferences` pattern — not the
  project document, which stays a pure description of the show. Scoped per
  project since 2026-09-13 (`projectID`, keys under `session.projects.<id>`;
  `scoped(to:)` moves the bus position, the transition stays global; an
  unscoped store reads the one-project era's flat keys), and holding the
  `lastProjectURL` the launch reopens. The armed
  transition comes back whatever the document holds; a value the app no
  longer knows reads nil and leaves the picker on its default, and a duration
  is clamped to the panel's range on restore. `EngineModel` records
  it from the properties' own observers, so no path that moves a bus
  can forget, and reads it once at the top of `loadProject()` before any
  assignment overwrites it. `SessionPosition` validates the record against
  what actually loaded: `launchPreset(in:)` adopts the recorded preset while
  the document holds it and the first otherwise, and `shots(validIn:)` keeps
  each recorded shot only while it exists in the adopted pool — each on its
  own, so a deleted staged shot does not cost the program shot its place.
  Before this every cold start put the first preset's first shot on program
  and its second on preview, whatever had been staged at quit.
- `MonitorPreferences` — where the monitor device, level, and mute persist:
  machine-local `UserDefaults`, not the project document — which headphones are
  plugged into this Mac is not part of the show — and not session state, since
  headphones do not change between launches; monitoring starts off on a fresh
  install, because monitoring through speakers beside a live microphone is a
  feedback howl, and it caches the selected device's name so the picker can
  label a selection the device list cannot currently resolve.
- `RecordingSettingsView` — the Recording settings pane (the main window's
  recording panel until 2026-09-08): a grouped form with the folder the program
  is written to and its Choose Folder… button, a container picker, how much
  room the volume still holds, and a status row with the rolling state, its
  elapsed time, and the file name — its own pane beside the Streaming one
  because recording is its own session, so stopping the stream leaves a
  recording rolling and vice versa.
- `RecordButton` — the Record / Stop Recording control, in the main window's
  toolbar since 2026-09-06 rather than at the foot of the recording panel: a
  primary action, always on screen where the panel scrolls away, with ⌘R bound
  to it and the word beside the symbol so a red glyph cannot read as streaming.
- `StreamButton` — the Start Streaming / Stop Streaming control beside it in
  the toolbar, since the same day, with ⌘G bound to it and the same disabled
  rule — nothing to stream to, nothing to start. It took the stream keys typed
  into the streaming panel's rows as a value collected at the click until the
  rows moved to the settings window (2026-09-08); `EngineModel.startStreaming()`
  now reads each key back from the Keychain, where the Streaming pane filed it.
- `RecordingPreferences` — where the recordings folder and container persist:
  machine-local `UserDefaults` for the same reasons as `MonitorPreferences`,
  defaulting to `~/Movies/Tingra Recordings` — under Movies, which needs no
  TCC prompt where Desktop and Documents would, and a subfolder since the
  Library's Recordings tab lists the folder (2026-09-12). Injected into
  `EngineModel` so tests never write the operator's preference.
- `RecordingFilename` — the pure, unit-tested naming rule: a date-stamped name,
  and a numeric suffix rather than overwriting when one is taken — a recording
  must never destroy an earlier take. Its locale-independent timestamp
  (`timestamp(at:)`) is shared with `SnapshotFilename`.
- **Snapshots** (`Snapshots/`, 2026-09-11; ARCHITECTURE.md, "Snapshots") — a
  still of whatever frame a monitor is showing, saved as a PNG:
  - `SnapshotSubject` — which monitor: program, preview, an input's multiview
    tile, or the layer monitor; each maps to the `MonitorFrameSource` that
    monitor draws (`EngineModel.snapshotSource(for:)`), so what is saved is
    what is shown.
  - `SnapshotFeedback` — what the last request came to (Snapshot Saved,
    Snapshot Not Saved with its cause as help, No Picture to Save), worn as a
    badge on that monitor for a moment — never a sound, never a flash.
  - `SnapshotWriter` — the actor that renders off the main actor through its
    own Metal-backed `CIContext` (`encode(_:)`, `@concurrent`, letting go of
    the frame before the PNG encode) and names and writes one file at a time
    (`write(_:subject:at:in:)`), so two in one second never share a name.
    PNG in sRGB with the profile embedded; alpha only when a pixel is not
    opaque. `SnapshotPNG` is the encoded result; `SnapshotError` the refusals,
    with a developer-facing description that never names the folder and an
    operator message that does.
  - `SnapshotFilename` — the naming rule: `Tingra Program 2026-09-10
    14.03.12.png`, the subject localized and sanitized (`/` and `:` to `-`, a
    byte budget), the timestamp not, and a numeric suffix rather than an
    overwrite.
  - `SnapshotPreferences` — the snapshots folder, machine-local, defaulting to
    `~/Pictures/Tingra Snapshots` and chosen in the General settings pane;
    injected into `EngineModel` so tests never write into the operator's
    folder.
  - `SnapshotMonitorMenu` — the one modifier every monitor wears
    (`snapshotMenu(model:subject:tapName:tapParams:)`): the Save Snapshot
    context menu and the badge (`SnapshotBadge`), bottom center.
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
  collapsed sidebar makes visible. App-tier plug-ins' status items ride at the
  trailing end, drawn by the app from `StatusItemRegistry.readings` in the
  bar's secondary style, so the app's three readings keep the leading edge.
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
  faults drawing a warning triangle; plus the informational `programFormat`
  reading, lamp always off, whose label is `ProgramFormatChoice.label(for:)`.
- `StatusBarPreferences` — whether the bar is shown: machine-local
  `UserDefaults` on the `AppearancePreferences` pattern, shown on a fresh
  install, the presence of the key checked first so a missing value does not
  read as hidden.
- `StatusBarModel` — the `@Observable` both windows read and both the General
  settings checkbox and the View-menu item write — shared rather than each
  window reading `UserDefaults` for itself, since `UserDefaults` is not
  observable and the two controls live outside the windows they change.
- `TingraAppDelegate` — the AppKit hooks: `application(_:open:)` takes a
  project document the Finder handed the app (a double-click, a Dock drop),
  holding it until the main window's task hands the model over when it
  launched the app; it answers every quit with
  `.terminateLater` so the shutdown is recorded on the bus and drained to the
  log before the process exits (`EngineModel.shutDown(reason:)`, with the cause
  read from the quit Apple event through `TerminationReason`) and a recording
  open at quit is finalized into a playable file instead of truncated, and
  turns off automatic window tabbing before the first window exists — the
  one line that removes AppKit's Show Tab Bar and Show All Tabs from the View
  menu, which are the only two items in it that do nothing this app wants: the
  main window is one per show, and multiview's whole point is a second display
  rather than a tab beside the window it monitors.
- `PresetContextMenu` — one preset's context menu — duplicate, rename, reorder,
  remove — attached to the sidebar's preset rows, and to any surface that
  lists presets, so right-clicking a preset offers the same commands wherever
  it is listed; Rename… hands the preset back to the owning view, which opens
  the dialog.
- `PresetMenuSurface` — which surface a preset menu is on — today only the
  sidebar, since the main window's preset switcher row was removed 2026-09-06:
  the pure, unit-tested source of the surface's `tap` names (`sidebarPreset…`)
  and of its reorder words (Move Up / Move Down, a vertical list's).
- `PresetRenameDialog` — the preset rename alert as a modifier, so each surface
  presents the one dialog over its own content with its own subject and `tap`
  names.
- `ShotContextMenu` — one shot's context menu — duplicate, rename, default
  transition, reorder, remove — shared by the shot bank's tiles and the
  sidebar's shot rows; Rename… and the remove item hand the shot back to
  the owning view, which opens the dialog or, in the sidebar, asks first.
- `ShotMenuSurface` — which surface a shot menu is on, the switcher (the shot
  bank's tiles) or the sidebar: the pure, unit-tested source of each surface's
  `tap` names (the switcher keeps its `shot…` names, the sidebar reports
  `sidebarShot…`, keeping `sidebarShotDelete.menu`) and of the reorder words —
  Move Left / Move Right across the bank, Move Up / Move Down in the sidebar.
- `ShotRenameDialog` — the shot rename alert as a modifier, `PresetRenameDialog`
  one level down.
- `LaunchDiagnostics` — what the first line of every app log says about the
  build it came from: the params of the `app.launched` event `EngineModel`
  emits before anything else — `appVersion`, `appBuild`, `systemVersion`,
  `systemBuild` (`sysctl kern.osversion`), and `hardwareModel` (`sysctl
  hw.model`, `Mac15,3`); a missing reading drops its key. Injectable readings,
  so the assembly is tested without booting an engine.
- `TerminationReason` — why the app is quitting, as far as AppKit can say: the
  app's own `terminate(_:)` (the Quit item, ⌘Q), or a quit Apple event from the
  Dock, a script, or the login window on logout, restart, and shutdown, read
  from the event's `kAEQuitReason` parameter. The `reason` param of the
  `app.terminating` event; a `SIGTERM`, a Force Quit, or a crash bypasses the
  hook and records nothing.
- `QuitCommands` — the app-menu Quit item, replacing AppKit's so the click is
  recorded as a `tap` (`quit.menuItem`) before `terminate(_:)`; the delegate
  records the `app.terminating` effect for every quit, clicked or not.
- `Binding.reportingTap` — the shared helper that reports a control's `tap` from
  its **selection binding** rather than from `.onChange` — a binding setter runs
  only when the operator works the control, so a default the model assigns at
  boot no longer records a tap nobody made; see EVENTS.md, "Where a picker's tap
  is reported".
- `LayerTreeEditorView` — the layer-tree editor: add a layer bound to any
  discovered camera, display, or video generator — from the Add Layer menu or
  by dropping a sidebar input row on the layer list — remove, drag rows to
  reorder, and adjust a layer's frame and opacity with live sliders, or on the
  monitor itself (`LayerHandlesOverlay`, 2026-09-09). Each row carries the
  sidebar's kind symbol and the Layer menu's items as its context menu, a layer
  whose input is not discovered draws dimmed with a warning, a bare shot shows
  an empty state in place of the list, and the Delete key removes the
  selection, which is the model's (`EngineModel.selectedLayerIndex`). It follows the shot staged on preview, falling back
  to the shot on program when nothing is staged (`EditedShot`), and heads itself
  with that shot's name beside the shared tally lamp — red, with a note that
  edits are live, while the shot is on program; every edit reaches the compositor
  at the next tick and is autosaved to the project file.
- `EditedShot` — the pure, unit-tested rule for which shot the layer-tree editor
  follows (preview first, program as the fallback, never a held snapshot outside
  the pool) and the tally its header shows, red winning when the same shot is on
  both buses.
- `LayerTreeEdit` — the pure, unit-tested edit operations over a `Shot`,
  including the one-layer rebind the inspector's Input popup makes, a move to any index, the
  displayed-order move a drag-to-reorder makes, and a duplicate that lands
  directly above its source.
- `LayerHandlesOverlay` — direct manipulation of the selected layer on the
  monitor showing the edited shot (2026-09-09; ARCHITECTURE.md, "Direct
  manipulation, drag-to-reorder, and undo in the layer-tree editor"): a
  selection rectangle and eight handles in the tally's tint, drawn inside
  `MonitorTile` on the fitted video rect; drag to move, a handle to resize
  (Shift holds the aspect, Option resizes about the center), click to select
  the topmost layer under the pointer, arrow keys to nudge by 1% (Shift 10%),
  Delete to remove, with Keynote's yellow smart guides while a drag snaps.
  One undo step and one `tap` per drag.
- `LayerHandle` — the eight handles, each knowing which edges it moves and
  where it sits on the frame.
- `LayerFrameGesture` — the pure, unit-tested geometry behind the overlay and
  the inspector's fields: move, resize with the aspect and center rules and a
  2% minimum size, a typed width or height under the lock, Match Input's
  return to the input's own proportion (measured after the layer's effect
  chain by `pictureExtent(_:through:)`), nudge, and topmost-first hit
  testing, all over normalized frames.
- `LayerSnap` — the pure, unit-tested smart guides: a moving edge or center
  within a threshold of the program's edges, center, or thirds snaps onto it,
  and the guide is reported for the overlay to draw.
- `LayerCommands` — the menu bar's **Layer** menu, `LayerMenuItems` over the
  selected layer.
- `LayerMenuItems` — the six items drawn once for the Layer menu and a layer
  row's context menu: Bring to Front ⇧⌘], Bring Forward ⌘], Send Backward ⌘[,
  Send to Back ⇧⌘[, Duplicate Layer ⌘D, Delete Layer — acting on one layer
  and reporting the surface they were chosen from.
- `LayerArrangeCommand` — the closed, unit-tested table of those commands:
  key, modifiers, title, availability at the ends of the stack, destination
  index, and tap name per `LayerMenuSurface`. Deliberately not in
  `ProductionShortcut`: editing keys, not production ones.
- `LayerMenuSurface` — which surface a layer menu item was chosen from (menu
  bar or context menu), for its tap name's suffix.
- `LayerUndoAction` — what a layer-tree edit did, naming the Edit menu's Undo
  and Redo items ("Undo Move Layer") and the `layerEdit.undo` tap's `action`.
- `TrailingSidebar` — the main window's trailing sidebar (2026-09-10;
  GLOSSARY.md, "Sidebar"; ARCHITECTURE.md, "Media inputs and the Library's
  Media tab"): a generic container whose panes today are the layer
  inspector above the Library, split by `LibrarySplitter`, a draggable
  hairline that resizes the Library within `LibraryPreferences`' clamp and
  persists the height when a drag ends. 280–440 points wide, each pane
  pinned to that width so one pane's content can never push the other
  sideways. Registered plug-in panes follow the Library as collapsible
  sections (`PlugInPaneSection`, 2026-09-13), the two existing panes
  unchanged above them.
- `LayerInspectorColumn` — the trailing sidebar's upper pane
  (2026-09-09; ARCHITECTURE.md, "The inspector column and the sidebar's casting
  pickers"): a title naming the shot being edited ("Shot: Main Display",
  beside the tally lamp) over a caption naming the selected layer with its
  kind symbol, then
  `LayerInspectorView`, or the empty state saying
  where to select a layer. Shown by default, not persisted.
- `LibraryView` — the Library pane (GLOSSARY.md), the trailing sidebar's
  lower pane: a **Library** heading with a Media | Snapshots | Recordings
  segmented control, the heading yielding when the column is too narrow for
  both. The **Media** tab lists the project's media files, with the Add
  Media… button (a file importer over the types the media providers open),
  its content a drop target for files, and each row's context menu offering
  Quick Look, Reveal in Finder, and Remove from Project — which drops the
  reference and never deletes the file. The **Snapshots** tab (2026-09-11)
  lists the snapshots folder, re-read on events (the tab appearing, the app
  becoming active, Tingra's own writes), with Quick Look, Reveal in Finder,
  Add to Media, and Move to Trash — confirmed only when the project uses the
  file as media. The **Recordings** tab (2026-09-12; ARCHITECTURE.md, "The
  Recordings tab") lists the recordings folder on the same terms through the
  same row menu, re-read also when a take starts and when it is finalized,
  with the take being written first as its own row offering Reveal in Finder
  alone.
- `LibraryTab` — the Library's tabs, Media, Snapshots, and Recordings,
  persisted in `LibraryPreferences`.
- `LibraryList` — the one file list every Library tab draws: a Quick Look
  thumbnail, the name, and a detail line per row, each row draggable — a
  media row as its input (`DraggedInput`), a file row as its file, the take
  being written not at all, under a red record symbol — and dimmed with a
  warning when its file is missing.
- `LibraryFacts` — the rows' read-once display facts, kept for the panel's
  lifetime: a thumbnail generated by Quick Look and a movie file's length
  read from its asset (`assetDuration(of:)`, injectable), neither asked for
  a missing file or the take being written; display data only. It was
  `LibraryThumbnails` until 2026-09-12.
- `FolderListing` — the files directly in a folder conforming to one content
  type (`files(in:conformingTo:)`: images for snapshots, movies for
  recordings), newest first, not recursive, hidden files skipped, not
  filtered by name — the one reading both Library file tabs list and the
  Data pane counts, with `isSameFile(_:_:)` matching a listed file to the
  take being written. It was the Snapshots-only `SnapshotListing` until
  2026-09-12.
- `LibraryItem` — one Library row as a value: its `Identity` — a media
  item's id (whose `InputID` it plays through) or a file's URL — name, file,
  kind (image, movie, text, other — each with its symbol, resolved from the
  content type), modification date, size, a movie's duration, whether its
  input is registered, and whether it is the take being written
  (`isRecording`); with the pure detail-line rule (date — with the time for a
  file row — then length, then size, or "Recording…" for the take being
  written) and the rows-from-media, rows-from-snapshots, and
  rows-from-recordings builders the tests exercise.
- `LibraryPreferences` — the Library's height and tab: machine-local
  `UserDefaults` on the `SidebarPreferences` pattern, with the pure clamp
  keeping the Library at or above its minimum and the inspector above its
  own; an unknown stored tab reads as Media.
- **Plug-ins** (`PlugIns/`, 2026-09-13; PLUGINS.md, "The app side") — the app
  as the host of the app tier: ExtensionKit extensions targeting the app's
  extension point (`com.moonwink.tingra.app.plug-in`, declared by the
  `.appextensionpoint` property list copied into `Contents/Extensions`), each
  registered from its manifest before it runs, launched on demand, and spoken
  to over MCP JSON-RPC on `XPCMessageTransport` — never a second RPC protocol.
  `EngineModel` carries the engine-side pieces: `toolRegistry`, the host's
  `ToolRegistry` the endpoint lists and dispatches against (the program tools
  register into it at boot), `resourceRegistry`, the host's `ResourceRegistry`
  the endpoint serves (the three engine resources register into it once the
  engine is up), and `plugInProjectData(for:)` / `setPlugInProjectData(_:for:)`,
  the document's `plugInData` held opaque per plug-in id and written back as
  read, a write dirtying and autosaving the document like a layer edit
  (`project.plugInDataEdited`).
  - `EngineResources` — the three resources the app serves (2026-09-14;
    PLUGINS.md, "Phase 2 as built, first slice"), each rendered from the
    model: `tingra://session` (`sessionValue(of:)` — stream state, counters,
    each destination's state, recording state and file), `tingra://program`
    (`programValue(of:)` — presets, the active preset's shots with ids and
    inputs, program and preview shots, the tally, fade to black), and
    `tingra://inputs` (`inputsValue(of:)` — every known input by kind and
    media). Value types and identifiers only, never the compositor, the
    mixer, or a registry; every key a scripting contract.
  - `ModelResource` — a `Resource` over a main-actor snapshot closure of the
    model: `read()` renders it, and `changes()` re-renders after each change
    to anything the snapshot read (observation tracking, never a poll),
    signalling only when the document differs, so a follower of the program
    is woken by a take and never by a meter.
  - `ObservedChange` — `withObservationTracking` turned into something a loop
    can await: `next(of:)` returns once any observable property the read
    touched changes, or the task is cancelled, so a follower that stops leaves
    no task parked.
  - `ProgramToolsPlugIn` — the first-party program tools plug-in, registered
    at boot beside the capture and generator plug-ins through the same
    `ToolRegistering` seam: `shot_take`, `preview_set`, `fade_to_black`, and
    the stream and recording tools below. App-owned rather than in
    `TingraMCP` because only the app has a program.
  - `ProgramControlling` — the seam the program tools act through (shots, the
    program and preview shots, fade to black, `take`, `setPreview`,
    `setFadeToBlack`), which the model conforms to, so the tools are tested
    against a fake with no engine booted.
  - `ShotSelector` — the `shot` argument the two shot tools share: an exact id
    wins, else a case-insensitive name that must match exactly one shot, no
    index form; `shotNotFound` and `shotAmbiguous` otherwise.
  - `ShotTakeTool`, `PreviewSetTool`, `FadeToBlackTool` — the three tools:
    a take with the switcher's selected transition (the operator's own take,
    so the compositor's `program.take` reports it), a stage on preview, and
    a fade of picture and sound over an optional `duration`.
  - `ProgramOutputControlling` — the seam the stream and recording tools act
    through (the two statuses, `isStreaming`, `isRecording`,
    `hasStreamableDestination`, `recordingURL`, and the four start and stop
    methods the toolbar's buttons call), which the model conforms to — the
    twin of `ProgramControlling`.
  - `ProgramOutputTool` — what the four tools share: the no-arguments schema
    and the two results, `tingra://session`'s own `stream` and `recording`
    state members plus `changed`.
  - `ProgramStreamStartTool`, `ProgramStreamStopTool`,
    `ProgramRecordStartTool`, `ProgramRecordStopTool` — `program_stream_start`,
    `program_stream_stop`, `program_record_start`, `program_record_stop`
    (PLUGINS.md, Decision 17): argument-free, each naming a state rather
    than a toggle (already there answers `changed: false`, never an error),
    returning once the session is starting; `destinationNotFound` with
    nothing to stream to, `pipelineError` or `recordingFailed` when a start
    settles on an error at once.
  - `AppPlugInHost` — the `@Observable` host: discovers identities for the
    extension point at launch and on the system's own change stream (never
    polling), decodes each `PlugInManifest`, fills the pane, command, and
    status item registries, starts a plug-in's process when a hosted pane activates, a
    command is invoked, or a bus event meets an activation condition the
    manifest declared (one task drains the bus and asks the
    `ActivationTable`; `AppPlugInLink.activate` launches the process if
    needed and sends `tingra/activation`), and re-hosts a pane one second
    after its process dies.
    `DiscoveredPlugIn` is an identity with its manifest; `AppPlugInServices`
    is what every link needs (the bus, the tool registry, the status sink and
    identity the session serves, the storage, the status items — whose texts
    the link drops when the plug-in's last connection closes); `AppPlugInStorage` is the
    storage behind the method handler — project scope through `EngineModel`,
    app scope through `PlugInApplicationStore`, secrets through
    `PlugInSecretStore`; `AppPlugInLink` is one
    plug-in's process and connections — the command connection through
    `AppExtensionProcess` and one per hosted pane, each carrying an
    `MCPSession` with the plug-in's method handler, the plug-in "activated"
    while any is open; `PlugInHostError` is the one refusal, an identity whose
    bundle is not embedded (a third-party bundle is located in Phase 3).
  - `ActivationTable` — the activation conditions every discovered plug-in
    declared, indexed by event name so each bus event costs one lookup: `add`
    and `removeAll(for:)` follow discovery, `matches(_:)` answers which
    plug-ins an event wakes (each once, by its first matching condition, in
    registration order) as `Match` values.
  - `PaneRegistry` — the app tier's pane registry: every sidebar pane,
    settings pane, and window plug-ins have declared — every scene the app
    hosts, in one id space — filled from manifests at discovery, the app-side
    mirror of the host's registries; `plugIn(hosting:)` names the plug-in
    behind a hosted scene of any kind. `RegisteredPane`,
    `RegisteredSettingsPane`, and `RegisteredWindow` pair a descriptor with
    the plug-in it belongs to.
  - `StatusItemRegistry` — the status items plug-ins declared and the text
    each currently reports: `readings` is what the bar draws (an item only
    while it has a text, in registration order), `setText(_:for:plugIn:)`
    refuses an undeclared item and cuts a text at `maximumTextLength`,
    `clearTexts(for:)` drops a plug-in's readings when it stops running.
    `RegisteredStatusItem` pairs a descriptor with its plug-in;
    `PlugInStatusReporting` is the seam the method handler sets a text
    through.
  - `MeterFeed` — the mix's meter blocks as plug-ins follow them
    (`tingra/meters`): the meter drain folds each block into every follower's
    `MeterWindow`, and `levels(every:)` sends a follower its window no more
    often than the interval, driven by the blocks and never a timer.
    `MeterWindow` is the fold — the largest peak, the blocks' own RMS, the
    latest block's strips; `PlugInMeterFeeding` is the seam the method
    handler subscribes through.
  - `RelayFrameFeed` — the program and preview relays as plug-ins follow them
    (`tingra/frame`): `next(of:after:)` surfaces the `IOSurface` behind the
    relay's next frame, or an empty bus, as a `PlugInFrameUpdate`;
    `PlugInFrameFeeding` is the seam the method handler demands through.
  - `PlugInWindowView` — the content of a plug-in's window: the hosted scene
    its descriptor names, titled from the manifest, looked up in the registry
    on every draw so a window restored before discovery fills in when its
    plug-in appears, and says Plug-in Unavailable when it is gone. One
    `WindowGroup(for: PaneID.self)` scene (`TingraApp.plugInWindowID`) serves
    every plug-in's windows, one window per id.
  - `CommandRegistry` — the command registry, grouped by plug-in for the
    Plug-ins menu's submenus; `RegisteredCommand` pairs a `CommandDescriptor`
    with its plug-in and derives the `tap` name
    (`<plugInID>.<commandID>.menuItem`).
  - `PlugInRegistryError` — a registration refused because its id is taken,
    reported as an `error` event naming the plug-in and the id; the next
    plug-in registers normally.
  - `PlugInMethodHandler` — the `SessionMethodHandler` serving the app tier's
    `tingra/*` methods on one plug-in's connection: storage reads and writes
    against the plug-in's own scopes, secret reads and writes against the
    plug-in's own Keychain items (the plug-in id is the connection's, never
    a param, so a plug-in cannot reach another's data; a refused secret is
    answered with an internal error and reported as `plugin.secrets`, neither
    carrying the value), status item texts against the items the plug-in
    declared (`tingra/statusItem.set`; an undeclared item is invalid params),
    the meters subscription (`tingra/meters.subscribe` → `tingra/meters`, at
    most ten a second) and the frame demands (`tingra/frame.next` →
    `tingra/frame` with the surface attached, one outstanding per bus), both
    sent through the session's `SessionNotifier` and ended with the session,
    and events landed on the bus under the plug-in's domain. `PlugInStoring` is the storage-and-secrets seam behind it, so the
    handler is tested with an in-memory store.
  - `PlugInApplicationStore` — the app-scoped storage on this Mac: one JSON
    file per plug-in under `~/Library/Application Support/Tingra/Plug-ins/<id>/`
    (`defaultDirectory`); never secrets.
  - `PlugInSecretStore` — the plug-ins' secrets in the engine's own
    Keychain-backed `SecureStorage`, each under `plugin:<PlugInID>.<name>`
    (`account(named:for:)`): read, stored, or removed by name for one
    plug-in, and counted or cleared as a group (`accounts()`, `removeAll()`)
    by the `plugin:` prefix (`isPlugInAccount(_:)`), never touching a stream
    key's `destination:` item.
  - `PanePreferences` — which plug-in panes are open in the trailing sidebar,
    keyed by pane id on the `SidebarPreferences` pattern: an open pane is the
    absence of a value, so a fresh install shows every pane; also whether the
    Settings window's collapsible **Plug-ins** section — the heading over
    the plug-ins' settings panes, named like the menu and absent while no
    plug-in has one, its expansion mirrored on `AppPlugInHost` — is open
    (`settings.plugIns.expanded`).
  - `PlugInShortcut` — turns a manifest's `ShortcutDescriptor` into the SwiftUI
    `KeyboardShortcut` a menu item carries; a descriptor without a single
    character yields nil, so a malformed manifest loses its shortcut, not its
    menu item.
  - `PlugInPaneHost` — one pane's extension scene: `EXHostViewController`
    under `NSViewControllerRepresentable`, reporting activation and
    deactivation to the host so the pane's session opens and closes with the
    scene, and recreated by generation after the extension process dies (the
    host view controller never relaunches its scene itself).
  - `PlugInPaneSection` — one plug-in pane in the trailing sidebar, following
    the Library: the shared chrome — a disclosure header with the pane's title
    and symbol, expansion persisted per pane — around the hosted remote view,
    so uniformity comes from the container, not from each author.
  - `PlugInCommands` — the **Plug-ins** menu: one submenu per plug-in with
    commands, rendered before any extension has run and absent while no
    plug-in has a command; each `PlugInCommandItem` emits its `tap` first,
    opens the window the command names (`showsWindow` — here, since
    `openWindow` is an environment action, and only a window the same plug-in
    declared), then hands the command to the host, which reveals the pane the
    command names and forwards it to the extension.
- **Notes** (`tingra-notes`, 2026-09-13; PLUGINS.md, "The first-party proof:
  Notes") — the first-party proof of the app tier: a second target in
  `tingra-app.xcodeproj` (product `TingraNotes.appex`, module `TingraNotes`,
  manifest in `TingraNotes-Info.plist`) embedded in Tingra.app under
  `Contents/Extensions`, linking `TingraAppPlugInKit` alone — it cannot reach
  the engine; it is not even in the engine's process. Its manifest declares
  one pane (`com.moonwink.tingra.notes.pane`, trailing), one command ("Show
  Notes", ⌥⌘N, revealing that pane), and one settings pane; its strings have
  their own catalog (en/de/es).
  - `NotesExtension` — the `@main` `TingraAppExtension`: the pane and settings
    views by pane id, and the `show` command, whose own effect is the
    `notes.shown` event (the app has already emitted the `tap`).
  - `NotesModel` — the notes and the editor's font size, shared by the pane
    and the settings scene (one process serves both): the text is
    project-scoped storage, the font size app-scoped; edits reach the app
    debounced — one `tingra/storage.set` and one `notes.edited` event per
    pause in typing, never one per keystroke.
  - `NotesPaneView` — the pane: a text editor over the project-scoped notes
    and a Clear button (`notes.cleared`); the app supplies the chrome around
    it, so the pane is the editor alone.
  - `NotesSettingsView` — the settings pane: the editor's font size, kept on
    this Mac (`notes.fontSize`).
- **The fixture plug-in bundle** (`tingra-fixture-plugin`, 2026-09-23;
  PLUGINS.md, Decision 27) — a third target in `tingra-app.xcodeproj`
  (product `FixturePlugIn.tingraplugin`, module `FixturePlugIn`, Info.plist
  `FixturePlugIn-Info.plist`), built only for the tests: the test target
  carries it in its own `Contents/PlugIns`, and it is never embedded in
  Tingra.app. It links the two kits without embedding them, as a third
  party's bundle does, and `PlugInBundleFixtureTests` loads it through the
  production loader.
  - `FixturePlugIn` — the principal class, a `BundledPlugIn` registering one
    input and reporting `fixture.activated`.
  - `FixtureInput` — a generator that delivers nothing; its job is to land in
    the host's `InputRegistry` from across the boundary.
- `InspectorCommands` — the View menu's Show/Hide Inspector item, ⌥⌘I, beside
  the sidebar's; `InspectorButton` is the same toggle as the toolbar's
  trailing-most item, each under its own tap.
- `LayerInspectorView` — the selected layer's inspector (2026-09-09;
  ARCHITECTURE.md, "The layer inspector"), Final Cut Pro's Video Inspector
  shape, laid out for the column: an Input popup that rebinds the layer in
  place and truncates a long name rather than widening the column, Position
  and Size as number fields with steppers and their labels beneath, in
  program pixels or percent, the unit toggle and aspect lock over Match Input
  and Reset, a 3×3 anchor grid with Full Frame / Half / Inset beside it or
  beneath it as the column's width allows, opacity as a
  slider paired with a percent field, then the effect chain, then the layer
  monitor (a `MonitorTile` over `LayerMonitorSource`, badged "Layer", behind
  a "Layer Monitor" disclosure closed by default and built only while open,
  `EngineModel.isLayerMonitorDisclosed`). One edit, one
  undo step, and one `tap` per committed field or click.
- `LayerInspectorUnit` — the pure, unit-tested pixels/percent conversion the
  fields read and write, whole pixels rounded so a value round-trips.
- `LayerPlacement` — the pure, unit-tested placement presets — plus `fullFrame`
  and `fitting(inputAspect:in:)`, the letterboxed or pillarboxed frame a new
  media layer takes so a picture is shown whole, never stretched: nine anchors
  that move a layer (edge anchors keeping `ProgramLayout.insetMargin` while
  the layer spans less than half the program, flush otherwise) and three
  sizes that resize it, so Inset then Bottom Right is the built-in
  picture-in-picture camera exactly.
- `ShotEdit` — the pure, unit-tested shot-management operations: a new empty
  shot, a shot showing one input full frame (transient — `automatic` — when
  the app makes it to stage a clicked input, authored when the operator asked
  for it by drop or menu), a duplicate under a fresh id, a rename that ignores
  empty names — and that promotes an automatic shot to authored, the operator
  claiming it — `claiming`, the promotion every other edit and Keep go
  through, `persistedShots`, the authored shots a save writes and a load keeps,
  setting or clearing a shot's default transition, and the match that decides
  which existing shot staging an input reuses — one showing *only* that input,
  never one that merely contains it, so clicking a camera previews the camera
  rather than a composition built around it — and the preview refill: the shot
  staged whenever preview would otherwise be empty, the first not on program,
  else the program shot itself.
- `PresetEdit` — the same operations one level up: a new empty preset, a
  duplicate under a fresh id with the source's shot ids preserved — so switching
  between original and copy holds the on-program shot — and a rename that
  ignores empty names.
- `ProjectStore` — loads and saves one `.tingraproject` document: the
  default project's under `~/Library/Application Support/Tingra` (what a
  fresh install opens and the Data pane removes), or, since 2026-09-13, any
  file the operator named and placed (`init(fileURL:)`), with the `name` the
  window title shows; sets the default project's unreadable file aside
  rather than overwriting it.
- `ProjectCommands` — the File menu's project items (2026-09-13;
  ARCHITECTURE.md, "Projects as documents"): New Project… (⌘N), Open… (⌘O),
  an Open Recent submenu over `EngineModel.recentProjectURLs` ending in Clear
  Menu, Save As… (⇧⌘S), and Reveal in Finder — plain commands over the one
  autosaved project the engine keeps open, not a `DocumentGroup`; New, Open,
  and Open Recent disabled while streaming or recording.
- `ProjectFilePanel` — the AppKit open and save panels those items run,
  filtered to the project document's type (`UTType.tingraProject`).
- `ProjectSwitch` — the pure rule behind the disabled items and the model's
  refusal to replace the open project: the program format's own
  (`"streaming"` / `"recording"` / nil).
- `MonitorView` — the Core Image `MTKView` that samples one frame source at
  display rate — one instance over program, another over preview, and one per
  input tile in multiview; it was `ProgramPreviewView` while program was the
  only bus. A source that empties after showing frames (preview cleared) gets
  one cleared drawable, so the monitor never holds a stale frame.
- `MonitorFrameSource` — the seam a monitor reads through, so those cases
  share one draw path: a bus's `ProgramFrameRelay`, an `InputFrameSource`,
  the inspector's `LayerMonitorSource`, or the shot bank's
  `ShotThumbnailSource`. `image(for:)` (2026-09-10, defaulted
  to the frame itself) is the `CIImage` the monitor draws for a frame, which
  is how the layer monitor hands a frame through the layer's chain on the
  one draw path.
- `LayerMonitorSource` — the inspector's layer monitor's source (2026-09-10;
  ARCHITECTURE.md, "The effect chain says its order, and the layer gets a
  monitor"): the selected layer's input, drawn through the layer's effect
  chain via `VideoEffectChain` and scaled to the layer frame's proportion in
  program pixels (the picture as the layer places it, opacity aside), the
  chain's own instances kept in a private cache and rebuilt when the
  configurations change; reads the selection on every draw.
- `MonitorTile` — the framed monitor — video fitted to the program's aspect
  ratio on black (every caller passes `programAspectRatio`, so a portrait
  program gets portrait tiles), an optional
  tally border, an optional name badge, and an optional status badge, which is
  what tells a program monitor faded to black apart from a dead one — shared by
  the main window's two monitors, every multiview tile, and the shot bank's
  tiles, which pass no badge and are captioned beneath instead. The main
  window's two monitors also hand it content drawn over the fitted video rect
  — the layer handles (2026-09-09); every other tile passes nothing. The
  layer list's row thumbnails pass a smaller corner radius, and the preview
  and program monitors — the main window's and the multiview's — pass zero
  (2026-09-13): a monitor shows the exact pixels going to air,
  square-cornered like Final Cut's Viewer, while the bank, multiview input,
  and layer-monitor tiles stay rounded.
- `MonitorRenderContext` — the one Metal device, command queue, and `CIContext`
  every monitor draws through, rather than one per view.
- `InputGridView` — the multiview window's input grid: one tile per *running*
  input, name-badged and tally-bordered — red on air, green staged, no border
  idle. The tiles are deliberately inert: a tile is an *input* while preview
  stages a *shot*, and a guess one click from air is exactly what the preview
  bus refused.
- `ShotBankView` — the **shot bank** under the monitors, headed **Shots**
  (2026-09-07; ARCHITECTURE.md, "The shot bank"): one 16:9 tile per shot of
  the active preset in switcher order, each a `MonitorTile` showing the latest
  frame of the shot's dominant layer, captioned beneath with the shot's name as
  the monitors are — followed by its stage shortcut, "Default (⌘1)", for the
  first nine — tally-bordered red on program and green staged, clicked to
  stage, with the shared `ShotContextMenu` on the switcher
  surface; a stacked-layers glyph on a shot with more than one layer; a dashed
  tile with a Keep button for the transient shot a sidebar click staged; a
  placeholder naming both ways in when the preset has no shots; and a drop target for a sidebar input
  — before or after the tile it lands on, or appended at the end. It replaced
  `InputRowsView`, which tiled every discovered video input live and had the
  engine running every camera for monitoring; the engine again runs only what
  the show references.
- `ShotBankTile` — the pure, unit-tested tile derivation behind it: one tile
  per shot with the shot-level tally (red winning over green) and whether the
  shot is transient (the dominant-layer thumbnail input and the layer count
  left with "Shot thumbnails are the shot", 2026-09-13).
- `ShotThumbnailSource` — a bank tile's frame source (2026-09-13;
  ARCHITECTURE.md, "Shot thumbnails are the shot"): the whole shot, every
  layer's latest frame through its chain over the background, composed as a
  lazy `CIImage` by the bank's one `CoreImageShotRenderer`
  (`composedImage(shot:frames:format:)`) and drawn at thumbnail size in the
  monitor's one pass; `latest` is the lowest delivering layer's frame, the cue
  to draw, and `image(for:)` the composition.
- `AddShotMenu` — the **Add Shot** menu the plus button beside the Shots
  heading opens: `AddShotMenuItems` under a caller-drawn label.
- `AddShotMenuItems` — the Add Shot items every surface shares — Empty Shot,
  then Camera, Display, and Video Generator submenus listing each discovered
  input, each adding a full-frame authored shot of it; a submenu with nothing
  to list shows the sidebar's placeholder for that section, disabled. A view
  rather than a menu because two of its three hosts are menus already: the
  sidebar's Shots section header context menu and the menu bar's Shots menu
  each carry them as an Add Shot submenu.
- `AddShotMenuSurface` — which surface the items are on, sidebar, bank, or
  menu bar: the pure, unit-tested source of each surface's `tap` names
  (`sidebarShotAddEmpty.menuItem` / `sidebarShotAddInput.menuItem`,
  `shotBankAddEmpty.menuItem` / `shotBankAddInput.menuItem`,
  `shotsMenuAddEmpty.menuItem` / `shotsMenuAddInput.menuItem`).
- `DraggedInput` — the `Transferable` payload of an input dragged from the
  sidebar — its id under the app's exported `com.moonwink.tingra.input` type,
  declared in the target's `Info.plist` — accepted by the shot bank (a new
  shot) and the layer list (a new layer), and by nothing else.
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
- `ProgramCommands` — the Program menu (2026-09-10; ARCHITECTURE.md, "The
  program format as a project setting"): a Size submenu of the named
  `ProgramSize`s plus a Custom Size… item, and a Frame Rate submenu of
  `ProgramFormatChoice.frameRates`, each item a checkmark toggle reading as a
  radio group; disabled while streaming or recording. Leads the app's own
  menus because the program is what a shot is composed onto. Above them,
  Save Snapshot of Program (⌥⌘S) and Save Snapshot of Preview (2026-09-11;
  ARCHITECTURE.md, "Snapshots"); the Layer menu (`LayerCommands`) ends with
  Save Snapshot of Layer.
- `ProgramSize` / `ProgramFormatChoice` / `ProgramFormatProblem` — the pure,
  unit-tested rules behind that menu and its sheet: the named sizes (SD, 480p,
  720p, 1080p, Vertical, 1440p, 4K — every one even; 8K reachable only by
  typing), `named(matching:)` for the checkmarks, the offered frame rates, the
  status bar's verbatim label, `refusal(isStreaming:isRecording:)` for the
  reason a change is refused on air, and `problem(width:height:frameRate:)` —
  too small, odd, or a bad rate — with the message the sheet shows.
- `ProgramFormatSheet` — the Custom Size… sheet: width, height, and frame rate
  in `CommittingNumberField`s prefilled from the program's format, the first
  broken rule beneath them, Apply held back until none is. Presented by
  `ContentView` from window state the app scene owns, since a menu command
  cannot present a sheet.
- `ShotCommands` — the Shots menu: an Add Shot submenu of the shared
  `AddShotMenuItems`, then one item per shot in the active preset, in
  switcher order and under the shot's own name, staging it on preview; the
  first nine carry ⌘1–⌘9, which moved here from the preview row's buttons when
  those became optional — a key whose control may be off screen belongs in the
  menu bar.
- `ProgramLayout` — the pure, unit-tested arrangement that seeds a fresh
  project's picture-in-picture, display, and camera shots, and — when the bars
  generator is registered — a full-frame Bars shot after them, the one
  generator an operator wants as a shot.
- `ProductionShortcut` — the closed list of production keyboard shortcuts —
  staging ⌘1–⌘9, Cut ⇧⌘↩, Take ⌘↩, Fade to Black ⇧⌘B, Go Live ⌘G, Record ⌘R,
  Save Snapshot of Program ⌥⌘S, Show or Hide Status Bar ⌘/ — that is both the binding the controls apply and
  the listing the Shortcuts settings pane prints, so a documented shortcut and a
  working one cannot disagree; the case order is the pane's reading order; the
  assignments are the ones the professional Mac switchers already share, which
  is why the take is ⌘Return and not ⌘T. The status bar is the one entry bound
  to a menu item rather than a control, because window chrome has no control to
  hang a shortcut on — and the View-menu item binds this case, so the pane and
  the menu bar still cannot disagree. The snapshot is the second such entry: a
  snapshot has no button, so the Program-menu item binds it.
- `SettingsView` — the settings window, ⌘, — a `NavigationSplitView` whose
  source list holds eight panes, the shape System Settings and Xcode 26 settled
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
- `SettingsPane` — the closed list of panes — General, Streaming, Recording,
  Permissions, Shortcuts, Data, Logging, About — each deriving its own name and
  symbol, so the sidebar's label and the window's title cannot drift.
- `SettingsSelection` — what the source list selects: `builtIn(SettingsPane)`,
  or `plugIn(PaneID)` for a settings pane an app-tier plug-in registered, which
  the list appends below the built-in eight — identifier-backed for plug-ins
  while the built-in panes keep their closed enum (2026-09-13; PLUGINS.md,
  "The app side").
- `SettingsCommands` — the app-menu Settings… item that opens it, replacing the
  one the `Settings` scene would have contributed.
- `GeneralSettingsView` — the General pane: the app's Appearance and a Show
  Status Bar checkbox showing or hiding the bar across the bottom of both
  windows, then a Snapshots section naming the snapshots folder with a
  Choose Folder… button (2026-09-12; recorded as a Recording-pane section and
  moved here on the day it was built — where a still lands is not part of
  setting up a recording).
- `StreamingSettingsView` — the Streaming pane (2026-09-08; the main window's
  streaming panel until then): `DestinationListView`'s sections, then a status
  row rendering `EngineModel.StreamStatus` — Idle, Connecting…, ● Live with the
  bitrate and frame rate, Reconnecting… with the attempt count, Stopped, or
  Error with the message as a tooltip — under a footer that says where Start
  Streaming is and that keys live in the Keychain. The status stays with the
  destinations rather than returning to the main window: the status bar there
  already answers "am I on air", and what this pane adds is the per-destination
  reading beside the destination it belongs to.
- `AppearancePicker` / `AppearanceSwatch` / `AppearanceMiniDesktop` — the
  three-thumbnail appearance control and the miniature desktop each thumbnail
  draws — the System swatch composites the other two rather than being a third
  artwork.
- `ShortcutsSettingsView` / `ShortcutRow` — the Shortcuts pane, read-only —
  every shortcut the app binds in **one** group, no headings and no footnote,
  drawn from `ProductionShortcut.allCases` so a seventh cannot be added and
  forgotten here.
- `PermissionsSettingsView` / `PermissionRow` / `StatusLabel` — the Permissions
  pane: one row per system permission (Camera, Microphone, Screen Recording)
  with what Tingra uses it for, its status as a colored symbol and a word, and
  the one action its state allows — Request… for a permission never asked for,
  Open System Settings… for a refused one, nothing for a granted or restricted
  one — and, since 2026-09-07, a Reset button that asks the system to forget
  the decision so the status reads Not Requested again and macOS asks the next
  time an input needs it, disabled while there is no decision to forget.
  Opening the pane never prompts; a status read is not a request.
- `PermissionsModel` — the `@Observable @MainActor` model behind that pane and
  the engine's record of what TCC allows: re-reads every permission on each app
  activation (the event a System Settings change rides on — never a poll) and
  on the pane appearing, reports the launch picture once as
  `authorization.status` and each later change as `authorization.changed`, and
  hands back the permissions that newly became granted so
  `EngineModel.applyNewlyGranted(_:)` can rerun the reconfigure pass and start
  the inputs the grant unblocked without being asked. `reset(_:)` asks the
  seam to forget a decision and refreshes, reporting `authorization.reset` as
  an event on success and as an error naming the reason otherwise.
- `DataSettingsView` / `AppDataRow` — the Data pane (2026-09-07): everything
  Tingra has saved on this Mac, one row per kind with its name, how much
  there is (files, keys, or entries, with the size on disk), and where — the
  folder for the documents, the counter, and the recordings, as a link that
  opens it in the Finder while it is on disk; the file for the preferences;
  the Keychain for the keys — no description line; a Not Removed section that
  appears only after a removal left something behind, with the reason; and
  Remove All Data…, whose confirmation lists every kind with the counts of the
  moment, says the recordings are kept, and on Remove and Quit removes
  everything and terminates the app so the next launch is a first run.
  Permissions are the Permissions pane's, where each row has its own Reset.
- `AppDataModel` — the `@Observable @MainActor` model behind that pane: the
  inventory, refreshed on the pane appearing and after a removal (never
  polled); the removal, reported as one `appdata.removed` event carrying the
  count of each kind cleared and an `appdata.remove` error per kind that was
  not — counts only, never a path of the operator's and never a secret.
- `AppDataStore` / `AppDataKind` / `AppDataItem` / `AppDataRemovalFailure` —
  where everything the app saves is and how to remove it, over injected paths
  so tests run the real inventory and removal against a temporary directory
  and a throwaway defaults suite. The kinds are a closed list — the project
  document (with its `.unreadable` sibling), the destinations document, the
  stream keys in the Keychain, the plug-ins' app-scoped files and their
  Keychain secrets (counted apart from the keys by their `plugin:` accounts),
  the preferences domain, the log session
  counter, the log file, the recordings, and the snapshots — and every place
  the app persists has an entry or the pane cannot list it. Recordings,
  snapshots, and the log file are inventoried and never removed: the
  operator's work, not the app's state,
  and the record of what the app did — the removal included — that a
  first-run check wants to read. Removal is per kind and never
  stops early, so one refusal leaves the others gone and named; the
  Application Support directory goes only if it is empty afterwards (the
  daemon's socket lives there). `EngineModel.removeAllData()` builds the store
  over the engine's own project, destination, and secret stores and turns
  autosave off before the files go, so the quit's flush cannot write the show
  back.
- `LoggingSettingsView` / `LogSnapshot` — the Logging pane (2026-09-08): where
  the log file is, with Reveal in Finder as the row's control; its size (“Not
  created yet”, “Empty”, or the bytes on disk); Share Log File, a `ShareLink`
  over `LogSnapshot`, a `Transferable` whose file representation copies the log
  to a dated text file **when the share happens**; and Clear Log File behind a
  confirmation that repeats the size. Both actions are disabled while the log
  is empty. Every control reports its `tap` first — the share row's through a
  simultaneous gesture, the one control in the app that must, since a
  `ShareLink` has no action closure.
- `LogFileModel` — the `@Observable @MainActor` model behind that pane and the
  Help menu's share item, owned by `EngineModel` over the same `LogFile` the
  file sink appends to: the size as of the last refresh (read when the pane
  appears and after each action, never polled), `snapshot()` (nil and a
  `log.snapshot` error when there is nothing to copy), and `clear()`
  (`log.cleared` with `previousBytes`, or a `log.clear` error whose reason the
  pane shows). The host's `LogFile` emits nothing; the app is what knows a
  clear was the operator's.
- `LogFileCommands` — the Help menu's Share Log File… item, beneath the
  system's Tingra Help: the same dated snapshot, handed to
  `NSSharingServicePicker` over the key window (a `ShareLink` cannot sit in a
  menu), after its own `tap` (`logShare.menuItem`).
- The **Log window** (2026-09-12; ARCHITECTURE.md, "The log window"), in
  `LogWindow/`:
  - `LogWindowModel` — the `@Observable @MainActor` model, owned by
    `EngineModel` over the same `LogFile`: opening attaches a `LogWindowSink`
    and then reads the file's last 2 MB off the main actor, appending the live
    lines the read did not already contain (`liveLines(_:notIn:)`, the longest
    overlap); Load Earlier Lines prepends the chunk before; Pause detaches and
    Resume reloads; a `log.cleared` line empties the list; closing lets every
    line go. A read that cannot complete is a `log.read` error and
    `readFailure`. `LogFileModel.clearedEventName` names the event both use.
  - `LogWindowFilter` / `LogLaunchScope` — what the window shows: levels, taps,
    one domain or all, all launches or this one (matched on the log session
    ID), and a `localizedStandardContains` search. A line that did not parse
    shows under every level and hides only under a domain or This Launch.
  - `LogWindowLine` / `LogLaunchGroup` — a loaded line with a unique identity
    (lines themselves repeat), and a run of consecutive lines from one launch,
    split wherever a parsed line's log session changes.
  - `LogWindowPreferences` — the levels, taps, and launch choices, in
    machine-local `UserDefaults`; the domain and search do not persist.
  - `LogWindowSink` — the `EventSink` attached only while the window is open and
    not paused: each event as the file sink's line, every group, keeping
    nothing.
  - `LogWindowView` — the window: a lazy `ScrollView` of monospaced rows under
    pinned launch headers, ERROR red and DEBUG secondary, following the newest
    line while scrolled to the bottom; the selected line whole beneath, with
    Edit ▸ Copy; toolbar Levels menu (Info, Debug, Errors, Taps), Domain and
    Launch pickers, Pause/Resume, and search; empty states for no log, no
    match, and a read that could not complete.
  - `LogWindowCommands` — Window ▸ Log (`logWindow.menuItem`), above the window
    list; the scene's own item is removed. The Logging pane's Show Log button
    (`logShow.button`) opens the same window.
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
