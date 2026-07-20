# Tingra Glossary

The canonical vocabulary for Tingra, for both users and developers. These terms are used consistently everywhere: the engine, `tingra-cli`, MCP tool names, documentation, and the app UI. Tingra draws its language from Apple Pro apps (Final Cut Pro, Logic Pro, Motion) and broadcast production. If a word here conflicts with a word you know from another tool, the word here wins in anything Tingra ships.

## The hierarchy

**Project > preset > shot > layers.**

A project is the saved file for an entire show. A project contains presets. A preset is a long term collection of settings you switch between while live. A shot is a short term composition within a preset. Layers stack inside a shot.

## Media and composition

**Input** — anything that produces video or audio frames for the pipeline: a display, a window, an application, a camera, a microphone, a media file, a network feed, or a generator. Inputs are discovered, connect and disconnect at any time, and normalize to a common GPU resident frame type.

**Generator** — an input that synthesizes its content rather than capturing it: test patterns, color bars, solids, counters, placeholder frames.

**Layer** — one positioned element inside a shot: an input, a title, or an overlay, with its own transform (position, scale, crop) and effects. Layers stack in a defined order.

**Layer tree** — the data structure holding a shot's layers and their ordering, transforms, and effect chains. The compositor renders the layer tree to a single frame.

**Shot** — a short term composition: a specific arrangement of layers designed to be taken to program, cut away from, and returned to. Shots are quick to create, switch, and discard.

**Preset** — a long term, persisted collection of settings you switch between during a live session and keep across sessions: its shots, layer arrangements, audio configuration, and connected inputs. Switching presets is seamless and does not interrupt what is already playing out.

**Project** — the saved document for a whole show: every preset, destination configuration, and setting needed to reopen the show exactly as it was. Tingra saves a project as a `.tingraproject` file (JSON inside).

**Effect** — a video processing step applied to a layer, a shot, or the program: color adjustment, blur, keying, stylization. **Filter** is the interchangeable term for a single video processing unit; an effect may chain several filters.

**Title** — a text graphic rendered by the engine: lower thirds, headings, tickers, credits.

**Overlay** — a graphic or input displayed on top of the program, independent of the current shot: a logo, a frame, an alert, a persistent title.

**Transition** — the move from one shot or preset to the next. Types: **cut** (instant), **dissolve** (crossfade), **wipe** (directional reveal), and **shader** (a custom Metal-shader reveal, chosen from the built-in menu: **iris**, **diagonal**, **blinds**). A shot may carry a **default transition** — the transition it is taken with unless the operator overrides it with an explicit choice; a shot with no default is taken with a cut.

## Buses and monitoring

**Program** — what viewers see and hear: the composited, mixed result that feeds compression, recording, and every destination.

**Preview** — the staging bus: where the next shot or preset is composed and checked before being taken to program. Nothing on preview is visible to viewers.

**Multiview** — a single view that tiles program, preview, and all inputs at once for monitoring.

## Audio

**Mixer** — the audio surface of the engine: combines every audio input into the program mix.

**Channel strip** — one input's slot in the mixer: its level, mute, pan, meter, routing, and audio effect chain.

**Meter** — a channel strip's level display: the strip's signal measured at each mix tick — the block's peak and RMS — shown beside the strip's controls. Metering is pre-fader: the meter reads what the input delivers, before the strip's level, pan, and mute.

**Routing** — where a channel strip's signal goes: the bus its audio feeds. V1 has exactly one bus — the program mix — so a strip's routing is its membership in the preset's audio configuration: the authored channels, persisted with their level, pan, and mute, that the mixer rebuilds its strips from. Sends and additional buses are later.

## Timing

**Master clock** — the single time reference every timestamp in the engine is expressed against: the host time clock. Owned by the host as part of frame transport; no component compares times from two different clocks. See CLOCK.md.

**Timebase** — a timeline positioned on the master clock, such as a session's timeline starting at its `T0`. Every sink shares the session timebase so video and audio interleave correctly.

**Program tick** — the host's pacing heartbeat, firing at the program frame rate on absolute master clock deadlines. Each tick, the compositor pulls the latest frame from every input, renders the current shot, and stamps the program frame with the tick's time. Inputs feed the tick; nothing but the tick drives the program.

**Sync offset** — a signed millisecond adjustment applied to timestamps to correct unequal capture chain latency: a global A/V offset, plus per input offsets. A persisted, first class setting.

## Delivery

**Compression** — turning composited frames and mixed audio into an encoded bitstream (hardware H.264/HEVC). A compression session is configured per destination or recording.

**Recording** — writing the program to a local file, independent of streaming.

**Output** — the engine component that sends compressed program media out of Tingra, to destinations or to a recording.

**Destination** — a configured target the program streams to: a streaming service ingest point, a custom server, or a local endpoint. A project can hold many destinations.

**Multiple destinations** — sending the program to several destinations simultaneously, each with its own compression settings where needed.

## Control and automation

**MCP tools** — the engine's controls exposed to AI agents through the built in MCP server (`tingra-cli serve` / `tingra-cli mcp`, see CLI.md and MCP.md). Every capability of the engine is reachable as a tool.

**Daemon** — the persistent engine process run by `tingra-cli serve`: the one owner of the session, the pipeline, and the TCC identity. launchd managed and socket activated in the product path; every other process (the `mcp` proxy, scripts) is a client of its Unix domain socket. See MCP.md.

**Macro** — a saved, replayable sequence of engine actions: switch preset, start recording, enable an overlay, begin streaming. Macros can be triggered manually, by an agent, or by an event.

**Session** — the live running state of the engine in the persistent process: which inputs are active, what is on program and preview, what is streaming and recording. The session survives across individual tool calls.

## Events and observability

**Event bus** — the host's structured event spine: every part of the engine and every plug-in reports what happens (errors, stream state, device changes, stats) as events on the bus, and sinks turn them into logs, CLI output, and status. Always called the "event bus" in full — an unqualified "bus" means program or preview. Carries the control plane only, never per frame traffic. See EVENTS.md.

**Sink** — a subscriber to the event bus that delivers events somewhere: the system log, the CLI console (human or `--json`), a log file, or MCP status. Code emits events; only sinks produce log output.

**Event group** — the routing axis of an event: what kind it is (`app`, `error`, `event`, `network`, `tap`, `trace`). Generic across any application, closed, and stable; sinks route and level events by group.

**Event domain** — the attribution axis of an event: which part of the system emitted it. Well known domains mirror the engine services (`capture`, `output`, …); third party plug-ins use their plug-in identifier. Open ended by design.

**Log session** — the four-digit identifier every human log line carries in square brackets (`[0042]`), incrementing exactly once per cold start, so it anchors which process wrote which lines in an interleaved log file (see EVENTS.md, "The human log line format"). Not to be confused with the engine **session** above — a log session is purely a logging anchor.

**Error identifier** — the stable, machine-readable code every `error` event carries in its `identifier` param (`inputNotFound`, `authorizationDenied`, …), alongside a human `message` whose wording may change. Exit codes and MCP tool errors key off identifiers, never message text. The registry lives in CLI.md ("Error identifiers"); identifiers are append-only and never renamed.

## Extensibility

**Engine** — the whole media and control core: the host plus every loaded plug-in, organized as services (capture, composition, audio, compression, output, plug-in, MCP/control, platform — see ARCHITECTURE.md, "Engine services"). The engine has no UI; every front end — `tingra-cli`, AI agents over MCP, and eventually the app — is a client driving it through host-exposed protocols, never a fork of its pipeline. In the product path one engine runs per user, owned by the daemon; the **session** is its live running state.

**Plug-in** — a separately built bundle that adds capability to the engine: inputs, generators, effects, transitions, outputs, automation. Note the spelling: always "plug-in," the one sanctioned hyphenated word in Tingra writing. All of Tingra's own features are built as plug-ins that ship with the product; third party plug-ins use the identical protocol and registries.

**Host** — the minimal core that is not a plug-in: the plug-in loader and lifecycle, the registries, frame transport, the session, the event bus, logging, secure storage, and authorization.

**Registry** — the seam where plug-ins attach: each capability type (inputs, effects, transitions, outputs, tools) has a registry that plug-ins register implementations into and the engine resolves from.

**Seam** — a deliberate protocol boundary where one implementation can be swapped for another without the code on the other side changing. `Input` is the seam for capture frameworks, `StreamingService` for streaming output (HaishinKit lives behind it), `EngineClock` for time, and a registry is the seam where plug-ins attach. A seam is both an isolation point (only the code behind it imports the underlying framework or library) and a test point (tests substitute generators, mocks, or a synthetic clock there). Borrowed from software engineering, where a seam is "a place where you can alter behavior without editing code in that place."

## System

**Authorization** — the state of the system permissions Tingra needs: Screen Recording, Camera, and Microphone. The engine reports authorization status and requests access; it never assumes it.

**Device connection and disconnection** — inputs appearing and disappearing while running (a camera unplugged mid show, a display added). The engine treats this as a normal event, not an error.

## Coming from OBS?

A rough translation for the concepts you already know:

| OBS says | Tingra says |
| :------- | :---------- |
| Source | Input |
| Scene | Shot |
| Scene collection | Preset (roughly; a Tingra project can hold several presets) |
| Filter | Effect / filter |
| Studio mode preview/program | Preview / program (same idea) |
| Encoder | Compression |
| Stream (service settings) | Destination |
| Plugin | Plug-in |

## Words Tingra does not use

Source, scene, egress, ingest, fanout, encoder (as a component name), hot plug, permissions (for device access), and extension (for plug-ins). Each has a replacement above. One boundary exception: external protocols and services keep their own vocabulary at the boundary (a streaming service's "ingest endpoint" stays an ingest endpoint, an RTSP "source" stays a source in that protocol's terms), but everything becomes an input on Tingra's side.
