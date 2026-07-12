# Tingra: Architecture and Technical Plan

Tingra is a native macOS live streaming and production application, written entirely in Swift and built on Apple's modern media stack. This document describes the technical architecture and the role each component plays, including where the HaishinKit library fits in.

## Design principles

1. **Mac first, not cross platform.** Every choice favors deep integration with macOS over portability. No Qt, no OpenGL, no ported abstractions.
2. **GPU resident pipeline.** Frames stay on the GPU as `IOSurface` backed buffers from capture through composition to compression, avoiding expensive CPU round trips.
3. **Modern Apple frameworks over reinvention.** ScreenCaptureKit, AVFoundation, Metal, VideoToolbox, and AVAudioEngine do the heavy lifting.
4. **Build the distinctive parts; adopt the thankless parts.** Capture and composition are what make Tingra native and distinctive, so we own them. RTMP/SRT networking and muxing are hard, standardized, and undifferentiated, so we adopt a proven library (HaishinKit) rather than rebuild them.
5. **Plug-in first.** All core functionality ships as first party plug-ins built on the same protocol third parties use. The host, the only code that is not a plug-in, is the smallest thing that can run plug-ins and move frames.

## Vocabulary

Tingra uses Apple Pro app and broadcast terminology. GLOSSARY.md is the canonical reference for every term. The ones this document leans on hardest: **input** (anything producing frames, including **generators** that synthesize them), the **project > preset > shot > layers** hierarchy, **program** (what viewers see and hear), **compression** and **output** (the delivery components), **destination** (a streaming target), and **plug-in** / **host** / **registry** (the extensibility model; always spelled "plug-in"). Tingra does not say source, scene, egress, ingest, or encoder; see the glossary for the full list and the protocol boundary exception.

## Pipeline overview

```
┌─────────────────────┐     ┌─────────────────────┐
│  ScreenCaptureKit   │     │    AVFoundation     │
│  (display, window,  │     │  (camera input)     │
│   app inputs)       │     │                     │
└──────────┬──────────┘     └──────────┬──────────┘
           │  IOSurface-backed          │  IOSurface-backed
           │  CVPixelBuffers            │  CVPixelBuffers
           └────────────┬───────────────┘
                        ▼
             ┌─────────────────────┐
             │   Metal compositor  │  ◄── Core Image effects,
             │  (shots, layers,    │      transitions
             │   transforms)       │
             └──────────┬──────────┘
                        │  program frame
                        │  (IOSurface/CVPixelBuffer, GPU-resident)
             ┌──────────┴───────────────┐
             ▼                          ▼
  ┌───────────────────────┐   ┌─────────────────────┐
  │      HaishinKit       │   │   Local recording   │
  │ (VideoToolbox         │   │  (AVAssetWriter,    │
  │  compression inside   │   │   hardware encode → │
  │  the stream + RTMP/   │   │   .mov / .mp4)      │
  │  SRT output)          │   └─────────────────────┘
  └───────────┬───────────┘
              ▼
     YouTube / Twitch / custom
     RTMP or SRT destinations

  Audio runs in parallel:
  AVFoundation / Core Audio inputs → AVAudioEngine mixing →
  mixed audio → compressed and muxed by each sink (recording + HaishinKit output)
```

Generators (bars, solids, test tones) enter the pipeline as inputs alongside the capture boxes above.

## Color and pixel format conventions

One canonical working format and one delivery standard, decided up front — mismatched or untagged color is the classic source of "slightly washed out" streams. Tingra uses the normal broadcast conventions:

- **Working format (capture → composition):** IOSurface backed `kCVPixelFormatType_32BGRA` (Metal `bgra8Unorm`), SDR, tagged BT.709. This is the "common GPU resident frame type" every input normalizes to. Normalization at the input seam is the one place pixel format and color conversion happen — YCbCr camera frames ('420v'/'420f') to RGB, wide gamut sources (Display P3 screens and cameras) down to BT.709. The program frame the compositor emits is this same format.
- **Delivery standard (compression sinks):** H.264/HEVC, 4:2:0 chroma subsampling, video (limited) range, BT.709 — with the color description written into the bitstream (VUI `colour_primaries`/`transfer_characteristics`/`matrix_coeffs` all BT.709) and matching format-description/track tags on recordings. Program resolutions stay even in both dimensions (4:2:0 requires it).
- **Every buffer is tagged.** Every `CVPixelBuffer` in the pipeline carries `CVImageBuffer` color attachments (primaries, transfer function, YCbCr matrix). Untagged buffers are a defect: untagged means the next stage guesses, and guessing is where color bugs live.
- **One conversion point.** Composition and the sinks never re-convert; they trust the tags set at input normalization. Core Image manages its own (linear) working space; hand written Metal shaders that blend or sample must be deliberate about sRGB vs. linear texture views rather than relying on defaults.
- **SDR only for now.** Wide gamut and HDR program output (P3, HLG/PQ) are out of scope until well after the app era; if they come, they enter at the same input normalization seam and become a program-wide setting, not a per-input one.

## Frame ownership across the `Input` seam

`CVPixelBuffer` and `CMSampleBuffer` are not `Sendable`, yet frames and audio buffers must cross isolation boundaries from an input's capture callback to the compositor and the sinks. Tingra resolves this with one deliberate, documented ownership rule instead of scattered ad hoc `@unchecked Sendable` (decided 2026-07-04; the rule CLAUDE.md's strict-concurrency note calls for). Every producer and consumer of media buffers observes it:

1. **Transfer at yield.** The producer (an `Input`) hands the buffer off when it yields to its `frames()`/`audio()` stream and never touches it again — no reuse, no late writes, no retained references.
2. **One holder at a time.** Exactly one consumer owns the buffer at any moment. The compositor's latest-wins slot releases its previous frame when a newer one replaces it; a sink that needs the buffer beyond its call must be handed ownership explicitly, never share it.
3. **Immutable after transfer.** Nothing writes to the buffer after the yield. Downstream stages read, composite, and encode from it only; any stage that needs modified pixels renders into a new buffer.

Under this rule a buffer is only ever read after the unique transfer point, which is exactly the guarantee `Sendable` encodes — so the wrapper types `CapturedFrame` and `CapturedAudio` in the plug-in protocol package carry `@unchecked Sendable` soundly. **Those two types are the only sanctioned `@unchecked Sendable` in the codebase.** They are the single choke point every media buffer crosses; any new `@unchecked Sendable` anywhere else needs its own documented rule and review, and "the frame path needed it" is not a reason — the frame path already has its rule here.

The rule is enforced by convention and review, not the compiler — which is why it lives in this document, is restated on the two wrapper types, and is deliberately short enough to hold in your head while writing an input.

## Engine model: host and plug-ins

The engine splits into two kinds of code.

**The host** owns the plug-in loader and lifecycle, the registries every plug-in registers into, frame transport (the GPU resident pipeline, its master clock, and the program tick that paces the compositor — see CLOCK.md), the session and state manager, the event bus and its logging sinks (see EVENTS.md), secure storage (Keychain backed, for stream keys), and authorization (Screen Recording, Camera, Microphone). The host has no features a viewer would ever see. The test for what belongs in the host: if removing it breaks plug-ins in general, it is host; if removing it breaks one capability, it is a plug-in.

**Feature plug-ins**, first party and third party alike: every capture input, every generator, every effect and transition, local recording, every streaming output, and every MCP tool surface beyond the host's own introspection tools. First party plug-ins ship inside the product and load through the same discovery path, protocol, and registries as anything a third party writes.

Each input is an implementation of an `Input` protocol; the compositor and everything downstream consume the protocol and never import a capture framework directly, mirroring the `StreamingService` seam on the output side.

```swift
// Sketch of the boundary — not final API.
protocol Input {
    var id: InputID { get }
    func start() async throws
    func frames() -> AsyncStream<CapturedFrame>   // GPU-resident CVPixelBuffers
    func stop() async
}

final class CameraInput: Input { /* AVFoundation, all Apple platforms */ }
final class DisplayInput: Input { /* ScreenCaptureKit, macOS only     */ }
final class BarsGenerator: Input { /* generator, runs everywhere      */ }
```

**Delivery and isolation on macOS:** plug-ins are separately compiled bundles. Third party plug-ins install into a known folder (e.g. `~/Library/Application Support/Tingra/Plug-ins`); first party plug-ins ship in `Contents/PlugIns/`. The shared plug-in protocol lives in its own framework built with Library Evolution for a stable module interface; the entry point is the bundle's principal class via `Bundle.principalClass`. Tingra carries the Disable Library Validation entitlement (decided; feasible since Tingra is not Mac App Store sandboxed) because third party plug-ins will not share Tingra's Team ID. Isolation policy: bundled first party plug-ins run in process; third party plug-ins are candidates for XPC isolation where the path tolerates it (outputs, automation), while capture plug-ins stay in process because the per frame IOSurface path and TCC attribution both favor it.

**Delivery on iPadOS (if an iPad build ever happens):** runtime loading of separately distributed binaries is not possible. All executable code must be embedded in the signed app bundle at build time; loading code from outside the bundle is blocked by code signing enforcement and App Store policy (guideline 2.5.2), and ExtensionKit's third party extension point hosting is macOS only. The same `Input` protocol still works, but implementations are statically linked and chosen at compile time. An iPad build would keep camera inputs and generators, lose display/window inputs (ReplayKit could become a limited replacement input later), and use pure SwiftUI in place of the AppKit half of the UI. The seam buys portability of the core, not feature parity.

**In the CLI era**, bundled plug-ins are compiled in but register through the same code path the external bundle loader will use; the loader itself can ship after the first release.

### Plug-in API stability and versioning

The plug-in protocol package is the one API Tingra can never break casually: a shipped third party plug-in must keep loading and working across Tingra updates. The policy, in force from the package's first tag:

- **SemVer, strictly, versioned independently of the product.** During the CLI era (roadmap steps 1–4, before the external bundle loader ships) the package stays at 0.x, where minor bumps may break per SemVer convention. It tags **1.0.0 when the external bundle loader ships** — the moment third parties can actually build against it. From 1.0.0 on, breaking changes land only in major versions.
- **What counts as breaking:** removing or renaming any public symbol; changing a signature or the documented semantics of existing API; adding a protocol requirement without a default implementation; tightening concurrency requirements (`Sendable`, actor isolation) on existing API. All of these wait for a major.
- **Additive evolution first.** New protocol requirements ship with default implementations so existing conformances keep compiling. When a capability changes shape, prefer a new protocol (or protocol inheritance) over mutating a shipped one.
- **Deprecate before removing.** Mark with `@available(*, deprecated, message:)` naming the replacement, keep the symbol for at least one minor release, and remove only in the next major.
- **Library Evolution stays on** (decided above) so the module interface is stable: a plug-in built against an older minor keeps loading against a newer one without recompilation.
- **Version negotiation at load, never a crash.** Each plug-in bundle declares the protocol major it was built against (an Info.plist key under `com.moonwink.tingra.*`); the host refuses an incompatible plug-in with an `error` event naming both versions and the fix (EVENTS.md), and the remaining plug-ins load normally — per the never-crash rule.
- **CI enforcement.** The protocol package's CI job runs `swift package diagnose-api-breaking-changes` against the latest release tag, so an accidental break fails the pull request instead of a third party's build.
- **The policy travels with the dependency surface.** The protocol package's only dependency is the zero dependency event bus package (EVENTS.md), which is re-exposed to every plug-in — so the same SemVer and evolution rules bind the event bus package too.

## Engine services

The engine is organized as services, each exposing its capabilities through plug-in registries: Capture (inputs, generators, input discovery, device connection and disconnection), Composition (presets, shots, layer tree, transitions, Metal renderer, effects, program/preview buses), Audio (mixer, channel strips, routing, audio effects), Compression (VideoToolbox compression sessions, rate control, local recording), Output (the `StreamingService` seam with HaishinKit backed RTMP/SRT implementations, later multiple destinations), Plug-in (discovery, lifecycle, isolation), MCP/Control (tool registry, session/state, authorization bridge), and Platform/Infrastructure (event bus, logging, secure storage, local storage, system info).

### Capture
- **ScreenCaptureKit (macOS 12.3+)** for display, window, and per application inputs. It delivers frames as `CMSampleBuffer` wrapping `IOSurface` backed `CVPixelBuffer`s, which stay on the GPU.
- **AVFoundation** (`AVCaptureSession`) for camera and microphone inputs.
- Every input normalizes to a common GPU resident frame type that the compositor consumes.
- **Two capture plug-ins, split by framework and permission** (`TingraCapturePlugIns`): `AVFoundationCapturePlugIn` contributes cameras and microphones (Camera / Microphone TCC), and `ScreenCaptureKitCapturePlugIn` contributes displays (`InputKind.display`, a pre-1.0 additive case; Screen Recording TCC) — a separate plug-in, decided 2026-07-06, because it is a different framework and a different permission, matching this services split. Display discovery reads CoreGraphics, which needs no Screen Recording authorization (like camera discovery, listing never prompts; only capturing does), and identifies each display by its `CGDisplayCreateUUIDFromDisplayID` UUID, which survives reconnection where the transient `CGDirectDisplayID` does not; capture then resolves that UUID to the current display and runs an `SCStream` delivering 32BGRA frames tagged BT.709 at the seam. Displays are not yet in the CLI's `devices` listing — they are an app-era surface (CLI.md non-goals); the CLI loads only the AVFoundation plug-in.

### Composition
- **Metal** renders the layer tree of the current shot: positioning, scaling, cropping, and layering inputs, plus transitions between shots.
- **Core Image** (Metal backed) supplies effects without hand writing every shader; drop to raw Metal shaders where custom work or performance demands it.
- The result is a single program frame per tick, still GPU resident. This buffer is the **clean seam** described below.

**The compositor (roadmap step 6).** Composition lives in its own package, **`TingraComposition`** — a host-side engine library, a sibling of `TingraHost` depending only on the plug-in protocol package and the event bus (decided 2026-07-06; it is not a plug-in — effects and transitions plug *into* it — but it is a large, distinct concern that would bloat the minimal host, and the protocol-only dependency keeps it testable in isolation with a synthetic clock and a mock renderer). The `Compositor` is the tick-paced engine: it holds a latest-wins slot per input (a fill task drains each input's `frames()` into it) and the current `Shot`, and on each program tick it snapshots the shot and slots, renders the layer tree, and yields the composited program frame stamped with the tick's clock time. This is the step-6 realization of the model the single-input `ProgramPacer` stood in for during the CLI era — **same tick, same latest-wins slot semantics, same timestamps, with "take the latest frame" replaced by "render the layer tree"** across every input (CLOCK.md, "The tick before composition exists"). A stalled input keeps its last frame in its slot; the program is a live canvas from the first tick, showing the shot's background before any input delivers. The CLI's single-input `StreamSession` keeps using `ProgramPacer` for now — wiring the compositor into the stream path is a step-7 concern (multi-input streaming), so step 6 leaves the shipped CLI path untouched.

- **The layer tree** is plain values: a `Shot` is an ordered array of `Layer`s (bottom to top) over a `BackgroundColor`; a `Layer` names its input by `InputID` (not the input itself, so a shot is comparable and switchable live) and carries a normalized, top-left-origin destination `frame` and an `opacity`. The compositor resolves each id to that input's latest frame at tick time.
- **The renderer sits behind an internal `ShotRenderer` seam** whose default, `CoreImageShotRenderer`, composites with a Metal-backed `CIContext` (Core Image supplies the compositing without hand-writing shaders; raw Metal shaders wait for the effects/transitions step where custom work demands them). The renderer is created and used entirely inside the compositor's tick task (like the generator plug-in's `BarsRenderer`), so it needs no `Sendable`/`@unchecked Sendable`; a software `CIContext` makes placement, the top-left→bottom-left Y-flip, opacity, and BT.709 tagging deterministically unit-testable with no GPU.

**Presets and shots (roadmap step 7).** The first slice of the production feature set lands as data model plus engine plumbing (the layer-tree editor and the audio mixer follow in later step-7 iterations). A **`Preset`** is a named, persisted collection of `Shot`s — the `project > preset > shot > layers` hierarchy from GLOSSARY.md, one level up from the shot. `Preset`, `Shot`, and `Layer` are all plain `Codable` value types: the serialized form is the **project / scripting contract** (CLAUDE.md, "Data Models"), so keys are stable camelCase, a shot carries a stable `id` (`ShotID`) and a user-facing `name`, and a `Layer`'s `frame` is flattened to explicit `x`/`y`/`width`/`height` rather than the nested arrays a raw `CGRect` would synthesize. Three decisions, recorded here (2026-07-06):
  - **The active shot is session state, not part of the persisted preset.** A `Preset` holds only its shots (audio configuration, connected inputs, and destinations join it in later iterations); *which* shot is currently on program is live session state (GLOSSARY.md, "Session") owned by the `Compositor`, not a field of the saved document. This keeps the project file a pure description and matches "the session survives across tool calls" — it is not something you save and reopen.
  - **Switching a shot is driven by `take(shotID:transition:)`, defaulting to a cut.** The compositor gains `loadPreset(_:)` (load a preset's shots, cut to the first) and `take(shotID:transition:)` (take the named shot to program starting the next tick, with the given transition — a cut by default). `setShot(_:)` remains the low-level "render exactly this shot" path (used by the pre-preset `ProgramPacer`-era callers and tests), always a hard cut, and bypasses the preset's active-shot tracking. Taking an id absent from the loaded preset is recoverable — it reports a `program.take` error event and leaves the program unchanged, never a crash. Both `preset.loaded` and `program.take` are control-plane events on the bus, never per-frame traffic.
  - **The app builds shots with fixed ids so identity survives a rebuild.** `apps/tingra`'s built-in shots (picture-in-picture, display, camera) use fixed `ShotID` tokens rather than fresh UUIDs, so re-deriving the preset when the input selection changes preserves the shot's identity — the operator stays on the shot they had taken rather than snapping back to a default. User-authored shots get fresh UUIDs.

**Transitions: cut and dissolve (roadmap step 7, second iteration).** A **`Transition`** (GLOSSARY.md: cut, dissolve, wipe, custom shader) lands as a plain `Codable` value type in `TingraComposition` — the same project-file contract as `Preset`/`Shot`/`Layer` (stable camelCase `kind`/`durationSeconds` keys), so it round-trips exactly wherever it is later persisted. This iteration implements only `cut` and `dissolve(duration:)`; `wipe` and custom shader based transitions remain unrepresented cases for a later iteration. Four decisions, recorded here (2026-07-08):
  - **A transition is passed to `take(shotID:transition:)`, not yet a field on `Shot` or `Preset`.** Nothing about *how* a shot is taken belongs to the shot itself (the same shot might be cut to in a rehearsal and dissolved to on air); a per-preset or per-shot default transition is a plausible later addition, but this iteration keeps the caller in control and the data model unchanged.
  - **A dissolve's duration is counted in ticks, not wall-clock time.** `take` converts `duration` (seconds) to a whole number of program ticks (`round(duration × frameRate)`, minimum 1) at call time, and the `Compositor` counts ticks elapsed rather than comparing clock timestamps. This keeps the transition's progress exact and deterministic under both the master clock and a synthetic test clock (CLOCK.md, "The program tick" — nothing outside the tick stream should decide how much time has passed), and guarantees a dissolve always completes (a zero or negative duration still finishes on its first tick) rather than stalling.
  - **The crossfade is a `ShotRenderer` seam, not compositor-side pixel work.** `ShotRenderer` grew `renderDissolve(from:to:progress:frames:format:time:)` alongside `render(shot:frames:format:time:)`; `CoreImageShotRenderer` renders both shots' layer trees with its existing per-shot compositing path, then alpha-blends the incoming image over the outgoing one at `progress` — the same "fade toward what's underneath" math the layer-opacity path already used, just applied to a whole shot instead of one layer. The compositor stays pixel-agnostic: it snapshots which tick of the dissolve is current and hands the renderer two shots and a progress value.
  - **The active shot updates immediately, matching the cut's contract.** `take(shotID:transition:)` sets `activeShotID` (and the switcher's highlighted shot) to the incoming shot right away, whether the transition is a cut or a dissolve in progress — a caller reads "what's *going* to program," not "what's fully visible this instant." The compositor keeps rendering the crossfade tick by tick until it completes, then settles on a plain render of the incoming shot.

**The layer-tree editor (roadmap step 7, third iteration).** The operator edits the layer tree of the shot currently selected in the switcher — add a layer bound to an input, remove a layer, reorder the bottom-to-top stack, and adjust a layer's normalized top-left-origin frame and its opacity — live on program. The engine surface is one new `Compositor` method; the editing UI (`LayerTreeEditorView`) and the pure edit operations (`LayerTreeEdit`) live in `apps/tingra`. `Layer` is unchanged — still a plain `Codable` value type, the same project/scripting contract. Per-layer effect/filter chains are a later "Effect" iteration (GLOSSARY.md, "Effect"). Five decisions, recorded here (2026-07-11):
  - **Live edits flow through `Compositor.updateShot(_:)`, which replaces the loaded preset's shot in place.** It matches the edited shot to the loaded preset by `ShotID` and swaps it in; when that shot is on program, the very next tick renders the edited layer tree — no separate "apply" step, because the program is a live canvas at the tick rate (CLOCK.md, "The program tick"). While a dissolve is in progress *toward* the edited shot, the dissolve continues toward the edited tree (the outgoing side of a dissolve is not retro-edited — it is on its way off program). `updateShot` never changes `activeShotID`: editing a shot is not taking it. An id absent from the loaded preset is recoverable — a `shot.update` error event, the preset untouched, never a crash.
  - **A successful `updateShot` reports no event.** A live editor drives it at gesture rate — a slider drag calls it many times a second — so a per-update control-plane event would flood the bus (EVENTS.md admits control-plane traffic only, and this is closer to per-frame). User-action observability comes from the app's `tap` events instead, reported once per gesture (a slider reports its final value when the drag ends). If a scripting surface (an MCP tool) later edits shots, that tool reports its own control-plane event.
  - **Edits persist in the in-memory preset — session-scoped, not yet saved.** The compositor's loaded shot pool holds the edited shot, so the edit survives `take` switches away and back within the session; the app's session preset mirrors it. Project-file save/load is a later iteration. In `apps/tingra`, changing the camera/display **selection** still re-derives the built-in shots from `ProgramLayout` and discards layer edits — the built-in preset is a pure function of the selection; user-authored presets that own their layer trees arrive with the project file. *(Superseded 2026-07-12 by the project-file iteration: edits now autosave to the project document, and a selection change rebinds rather than rebuilds — see "Project save/load".)*
  - **A new layer binds to any discovered camera or display, and lands on top of the stack, full-frame, opaque** — you add a layer to see it. The app starts an input the first time a layer references it and stops it when no shot references it and it is not the selected camera/display (the same reconfigure pass that already manages the selection; an input that cannot start is reported and its layer simply contributes nothing). Generators stay out of the add-layer choices for now: `InputKind.generator` cannot say whether a generator produces video or audio, and a video/audio capability on the `Input` seam is a deliberate later protocol addition, not something to bolt on in a UI iteration.
  - **Layers are addressed positionally; the editor lists them topmost first.** `Layer` deliberately gains no id — it stays a plain value, and per GLOSSARY.md layers stack in a defined order, so the bottom-to-top index *is* the identity. The editor displays the stack topmost-first (the design-tool convention, so "up" means "in front") while every operation addresses the underlying bottom-to-top array index; an out-of-range index (a stale editor selection) returns the shot unchanged.

**Project save/load (roadmap step 7, fourth iteration).** The preset the operator already has — including layer-tree edits — persists across launches as a **project** file (GLOSSARY.md: the saved document for a whole show). The document type, **`Project`**, lands in `TingraComposition` beside `Preset`/`Shot`/`Layer`; the file handling (`ProjectStore`) and the save/load policy live in `apps/tingra`. Shot management UI (add/duplicate/rename/remove shots) and multiple presets in the UI are later iterations, though the document format holds a preset array from the start. Five decisions, recorded here (2026-07-12):
  - **`Project` is a versioned, plain `Codable` value type; v1 of the document holds the presets only.** The same project/scripting contract as `Preset`/`Shot`/`Layer`: stable camelCase keys (`version`, `presets`), exact round-trip, forgiving decode where fields are optional (`presets` defaults to empty). `version` is **required** — a document must declare its format so future versions can migrate it — and decoding a document *newer* than the build understands throws with a developer-facing message rather than silently loading a document whose unknown fields the next save would clobber. Destination configurations and settings join the document (with a version bump) in later iterations.
  - **The app autosaves one project file; explicit Save/Open commands wait for the document UI.** The document lives at `~/Library/Application Support/Tingra/Default.tingraproject` (the established Tingra home, beside the daemon's socket) — pretty-printed, sorted-key JSON written atomically. Saves are **debounced**: each edit restarts a one-second delay, so a slider drag's per-gesture edits coalesce into a single write (the same flood reasoning that keeps successful `updateShot` calls off the event bus), with an immediate save when a fresh project is seeded and a flush on engine stop. Autosave fits the live-canvas model — edits are already live on program, so an "unsaved changes" state would be a fiction; a File menu (Save/Open/Save As, multiple projects, a user-chosen location) arrives with the document-based UI. Saves and loads are control-plane events (`project.loaded`/`project.seeded`/`project.saved`, errors as `project.load`/`project.save`); the active shot and the dissolve toggle remain session state, never part of the document.
  - **The built-in `ProgramLayout` arrangement seeds a fresh project only.** At launch the app loads the document's first preset as the session preset (preserving any further presets in the array verbatim across saves). Only when there is no file — or the file holds no presets — does `ProgramLayout` derive the picture-in-picture/display/camera shots from the initial selection, once, and save the result; from then on the project owns its shots.
  - **A selection change rebinds, never rebuilds.** With shots persisted, the camera/display pickers stop re-deriving the built-in shots (which discarded edits — the caveat recorded under "The layer-tree editor"): a picker change **recasts which device plays that role**, rebinding every layer bound to the previously cast device to the new choice across all the preset's shots, keeping each layer's frame and opacity. Picking "None" parks the role's device — the input stops, its layers keep their binding and simply contribute nothing (the existing disconnected-input semantic) — and picking a device again rebinds them to it. A layer bound to an input that is no longer discovered stays bound and dormant until the device returns; recasting it onto a different device is a layer-tree editor operation (remove the stale layer, add one bound to the new device), since an undiscovered id's kind is unknown and the pickers only cast among discovered devices.
  - **An unreadable project file is set aside, never overwritten.** A file that exists but does not decode (corrupt, or written by a newer Tingra) is reported as a `project.load` error event and renamed to a `.unreadable` sibling before a fresh project is seeded — the app never silently destroys the operator's document, and never crashes over one.

### Compression
- Compression happens at the sinks; Tingra does not own a standalone compression stage. For streaming, HaishinKit compresses internally (hardware H.264/HEVC via VideoToolbox) as part of output, with settings (bitrate, keyframe interval, profile) driven by the selected destination through the stream configuration. For recording, `AVAssetWriter` performs its own hardware encode.
- Both sinks accept GPU backed pixel buffers directly, so the program frame feeds in without a CPU copy.

### Audio
- **AVAudioEngine / Core Audio** for capturing, mixing, and processing multiple audio inputs (microphones, application audio, media). The mixing graph is host transport; audio effects and taps are plug-ins. Produces the mixed program audio fed to both recording and streaming output.

### Output
- **HaishinKit** (BSD 3-Clause) handles RTMP and SRT output: the connection handling, retry logic, and muxing that Apple provides no framework for. WHIP/WHEP ships as alpha in `RTCHaishinKit`, giving a path to WebRTC output later.
- **Local recording** uses `AVAssetWriter` to write `.mov`/`.mp4` directly, independent of streaming output — the first-party recording plug-in (`TingraRecordingPlugIns`, roadmap step 5), behind the `RecordingService` seam and registered through the same `OutputRegistering` seam as streaming (see "The output registration seam" above). It is fed the same program media, so both sinks record the identical program; the recording carries the same BT.709 delivery color tags as the stream. Unlike HaishinKit (which detects tracks from the buffers it is appended), `AVAssetWriter` must declare its tracks up front, so the program's track topology travels in `StreamConfiguration` (`includesVideo`/`includesAudio`).

## How HaishinKit is incorporated (minimal adoption approach)

HaishinKit is capable of doing capture, video mixing, and output on its own. Tingra deliberately uses **only its output layer**, for three reasons: it preserves Tingra's distinctive native capture/composition story, it avoids inheriting HaishinKit's architecture across the whole app, and it isolates the dependency to a single, well defined boundary.

**The clean seam:** Tingra's Metal compositor produces the program frame; from that point, HaishinKit's stream objects (`RTMPStream` / `SRTStream` in HaishinKit 2.x) are responsible for compression and output to RTMP/SRT. In practice this means appending Tingra's program video and mixed audio to the stream directly, rather than attaching HaishinKit's own `MediaMixer` capture to the camera or screen.

Concretely:
- Tingra owns `AVCaptureSession` / `SCStream` and the Metal compositor.
- Tingra appends program video and mixed audio buffers to HaishinKit streams; HaishinKit's `MediaMixer` and device capture are not used.
- All compression for streaming, RTMP/SRT connection setup, reconnection, and muxing is delegated to HaishinKit.
- A thin `StreamingService` protocol wraps HaishinKit so the rest of Tingra never imports it directly. This keeps the dependency swappable and the seam explicit; the HaishinKit backed implementation is itself an output plug-in.

**The output registration seam** (decided 2026-07-04, mirroring the input seam): a `StreamingService` is per-session state, so what an output plug-in registers is a **`StreamingServiceProvider`** — a factory declaring the destination URL schemes it serves (`rtmp`/`rtmps` for the HaishinKit RTMP provider) and creating a configured `StreamingService` per stream. The provider and the `OutputRegistering` seam protocol live in the plug-in protocol package; the host's `OutputRegistry` conforms and arrives through `PlugInContext.outputs`, exactly as `InputRegistry` arrives through `PlugInContext.inputs`. The engine resolves a destination to a provider by URL scheme; one provider per scheme, duplicates rejected at registration.

**Recording joins the same seam as a parallel provider kind** (decided 2026-07-05, roadmap step 5). Recording writes the program to a local file (`AVAssetWriter`), a compression sink parallel to streaming (GLOSSARY.md, "Output": to destinations *or* to a recording). It is registered through the same `OutputRegistering` seam and held by the same `OutputRegistry` — one registry, two provider kinds — but through a **narrower `RecordingService` / `RecordingServiceProvider` pair rather than reusing `StreamingService`**. The reasons the narrower protocol wins over a "file"-scheme `StreamingServiceProvider`: a recording has no `Destination` (a file carries no stream key), no `connectionLost`/reconnect (a file write is terminal, not recoverable), and is resolved by the `--record` path's **file extension** (`mov`/`mp4`), not by a URL scheme — because recording runs *alongside* streaming (either or both active), not as the single scheme-resolved destination. Forcing recording into `StreamingService` would carry a meaningless secret and drag the reconnect machinery onto a sink with no connection. So the host resolves a recording target to a `RecordingServiceProvider` by extension (one provider per extension), and `StreamSession` drives the recording sink from the same rebased program media it feeds the stream — the recording keeps writing across a reconnect gap and is always finalized on teardown, however the session ends. A mid-recording write failure is reported as a `recordingFailed` error event and stops the recording, but never ends the stream (recording is independent); a recording that cannot even open fails the run before anything streams.

```swift
// Sketch of the boundary — not final API.
protocol StreamingService {
    func start(to destination: Destination) async throws
    func send(video frame: CVPixelBuffer, at time: CMTime)
    func send(audio buffer: CMSampleBuffer)
    func stop() async
}

// HaishinKit-backed implementation lives behind this protocol,
// so no other module in Tingra depends on HaishinKit directly.
struct HaishinKitStreamingService: StreamingService { /* ... */ }
```

### Dependency notes / caveats
- **Project home:** the library lives at the HaishinKit GitHub org (`HaishinKit/HaishinKit.swift`, formerly under shogo4405). Latest release at review time: 2.2.5 (March 2026), Swift 6, strict concurrency compliant.
- **License:** HaishinKit is BSD 3-Clause (verified), permissive and compatible with Tingra's MIT license.
- **Modules (2.x):** core `HaishinKit` plus `RTMPHaishinKit`, `SRTHaishinKit`, `RTCHaishinKit` (WHIP/WHEP, alpha), and `MoQTHaishinKit`. Pull in only what Tingra ships: core + RTMP first, SRT when added.
- **Binary targets (resolved):** the only prebuilt piece is the libsrt xcframework (1.5.4) inside `SRTHaishinKit`; all Swift code is source. An RTMP only build is fully source. Adopting SRT means shipping the prebuilt libsrt, or building libsrt from source ourselves. If that ever becomes unacceptable, the `StreamingService` seam lets us swap implementations without touching the rest of the app.
- **Integration:** Swift Package Manager.
- **Platform floor:** ScreenCaptureKit needs macOS 12.3+, ScreenCaptureKit system audio capture needs 13.0+, and HaishinKit 2.x needs macOS 12.0+ and a Swift 6 toolchain. Deployment target for Tingra: **macOS 15, Apple Silicon (arm64) only** — every Apple Silicon Mac runs macOS 15, so the floor excludes no hardware. Development toolchain floor: Xcode 26.6 / Swift 6.3.3, enforced by CI on GitHub Actions (see CLAUDE.md, "Toolchain & CI").

## Repository structure

The repo is a monorepo (multi package workspace) with two top-level folders. **`apps/`** holds the runnable products: `tingra-cli` (see CLI.md), `ingest-simulator` (the local RTMP/SRT test server, see SIMULATOR.md), and the assembled `tingra` app (phase 3, scaffolded at roadmap step 6). **`packages/`** holds the engine libraries the apps build on. The package names are finalized (reviewed 2026-07-03): **`TingraHost`** (the host/core package), **`TingraPlugInKit`** (the plug-in protocol package, importable by third parties without the engine), and **`TingraEventBus`** (the event bus both build on, see EVENTS.md); first party feature plug-ins land as their own packages alongside them: **`TingraCapturePlugIns`** (camera, microphone, and display), **`TingraGeneratorPlugIns`** (bars and tone, the permanent CI test surface), **`TingraOutputPlugIns`** (the HaishinKit backed streaming output — the only package that imports HaishinKit), and **`TingraRecordingPlugIns`** (the `AVAssetWriter` backed local recording; a separate package so `TingraOutputPlugIns` keeps its defining property — the only HaishinKit importer — and recording pulls in neither HaishinKit nor Logboard). Composition lives in **`TingraComposition`** (the tick-paced Metal/Core Image compositor, the layer tree, and the program format; roadmap step 6) — a host-side engine library depending only on `TingraPlugInKit` and `TingraEventBus`, not a plug-in and not folded into the minimal `TingraHost`. The MCP/Control service lives in **`TingraMCP`** (the `serve` daemon, the hand-rolled MCP JSON-RPC layer, the `mcp` stdio↔socket proxy, and the first-party control tools); it depends on `TingraHost` because the daemon owns the engine, while the `ToolRegistering` tool seam itself lives in `TingraPlugInKit` alongside the input and output seams. UI packages arrive under `packages/` in phase 2.

## UI layer
- **SwiftUI + AppKit**, with Metal preview content hosted in an `MTKView` (or a `CAMetalLayer` bridged into the view hierarchy).
- The interface exposes presets and shots, inputs, the audio mixer, program/preview monitoring, recording controls, and destination configuration.
- **Scaffolded at roadmap step 6** (`apps/tingra`): a SwiftUI `@main` app whose one `@Observable @MainActor` engine model boots the host and activates the same capture and generator plug-ins through the same `PlugInContext` the CLI uses — the app takes shape around the proven engine, not a fork of its pipeline. The step-6 surface is camera and display pickers feeding the compositor and a Core Image `MTKView` program preview that samples the program at display rate (never driving the program tick — CLOCK.md). It is an SPM executable that builds warning-clean; bundling it into a signed, notarized `.app` with an embedded Info.plist (Camera/Microphone usage descriptions, Screen Recording) is deferred packaging, tracked alongside the CLI's distribution recipe (CLI.md, "Distribution").

## Roadmap sequencing (suggested)

1. **Monorepo scaffold + `tingra-cli devices`.** The `apps/` and `packages/` split, the host/core and plug-in protocol packages under `packages/`, and the `apps/tingra-cli` executable; argument parsing; input discovery with stable IDs (table and JSON output). First milestone: small, shippable, and the selector foundation every later step resolves against.
2. **Camera and microphone inputs + generators** (bars, test tone) as the first plug-ins, registered through the loader code path; `stream --dry-run` resolves inputs and builds the pipeline.
3. **Streaming.** Simulator harness (see SIMULATOR.md) + HaishinKit output behind the `StreamingService` seam; `stream` to the local simulator, then to real Twitch/YouTube. **`tingra-cli` v1 ships here**, the first shippable milestone and the permanent integration test surface for the engine.
4. **MCP server.** The persistent engine process (`tingra-cli serve`, launchd socket activated) with the MCP tool registry: the primary agent interface (see CLI.md and MCP.md).
5. **Local recording** via `AVAssetWriter` (`--record`), deferred until streaming is solid and the need arises. *(Code complete 2026-07-05: `TingraRecordingPlugIns` behind the `RecordingService` seam, `tingra-cli stream --record`, verified against real files with `ffprobe` in the integration tests.)*
6. **Metal composition + preview.** The app takes shape around the proven engine: a camera input + a display input composited to an on screen `MTKView`. *(Code complete 2026-07-06: `InputKind.display` + `ScreenCaptureKitCapturePlugIn`, the `TingraComposition` compositor behind the `ShotRenderer` seam, and `apps/tingra` scaffolded — an `@Observable` engine model driving the compositor into a Core Image `MTKView` preview.)*
7. **Presets, shots, layers, transitions, audio mixer**: flesh out the production feature set. *(In progress: presets and shots — the `Preset`/`Shot` data model, the compositor's `loadPreset`/`take` shot switching, and the app's shot switcher — landed 2026-07-06; transitions (cut and dissolve only — the `Transition` type, `take(shotID:transition:)`, and the tick-paced crossfade) landed 2026-07-08; the layer-tree editor (`Compositor.updateShot(_:)` live in-place shot editing plus the app's `LayerTreeEditorView`) landed 2026-07-11; project save/load (the versioned `Project` document, the app's autosaved project file, and rebind-not-rebuild selection changes) landed 2026-07-12; wipe/custom-shader transitions, shot management UI, and the audio mixer are later iterations. See "Composition", "Presets and shots", "Transitions: cut and dissolve", "The layer-tree editor", "Project save/load".)*
8. **SRT, multiple destinations, and later WHIP/WHEP** (`RTCHaishinKit`) as support matures.

## Summary

Tingra owns the parts that make it native and distinctive (capture on ScreenCaptureKit/AVFoundation, composition on Metal, audio on AVAudioEngine) and delegates the standardized, undifferentiated compress and send work to HaishinKit behind a thin `StreamingService` protocol. Everything a user would call a feature is a plug-in against a minimal host, first party and third party on the same protocol. The entire media path stays GPU resident from capture to the compression sinks, and the HaishinKit dependency is isolated to a single swappable seam, keeping the project MIT clean and future proof.

Companion documents: GLOSSARY.md is the canonical vocabulary; CLI.md defines `tingra-cli`, the headless front end over the engine; SIMULATOR.md defines the local RTMP/SRT server used for testing; CLOCK.md defines the master clock, program tick, and A/V sync model; EVENTS.md defines the event bus, sinks, and logging/redaction policy; MCP.md defines the engine daemon, its socket transport, and the agent-facing MCP server.
