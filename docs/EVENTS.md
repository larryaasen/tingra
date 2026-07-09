# Events and Logging

How Tingra observes itself. This document defines the event bus — the structured event spine every part of the engine reports through — and the sink model that turns those events into logs, CLI output, files, and MCP status. Vocabulary follows GLOSSARY.md; the terms defined there (**event bus**, **sink**, **event group**, **event domain**) originate here.

The event bus is **host infrastructure**, not a feature service or a plug-in (ARCHITECTURE.md already lists it in the host). Apply the host test: remove the bus and every plug-in loses its voice — no errors surface, no stats flow, nothing reaches a log. It sits beside the clock (CLOCK.md) and secure storage as a cross cutting host component.

The design adopts the `EventBusBasics` pattern (a proven personal package of Larry's): a single `EventBus` publishes structured events, and independent subscribers — the sinks — fan them out. Logging is not something code does; it is something a sink does with events that code emits.

## Design principles

1. **Code emits events; sinks decide what becomes a log line.** No engine or plug-in code ever formats a log message, opens a log file, or imports a logging framework. It calls the bus. Every destination for that information — OSLog, the CLI console, a file, an MCP tool result — is a subscriber.
2. **Two orthogonal axes: group and domain.** The **group** says what kind of event it is (error, trace, tap, …) and drives routing and severity in every sink. The **domain** says which part of the system emitted it (capture, output, a plug-in) and drives filtering and attribution. Neither axis leaks into the other: groups stay generic across any app; domains stay Tingra specific.
3. **Control plane only.** The bus carries session, stream, device, and error events plus periodic stats — never per frame traffic. At 30 fps across several inputs, frame events would flood every sink; frames belong to the host's frame transport, full stop.
4. **Secrets never ride the bus.** See Redaction below.

## The event

An event has five parts (sketch follows `EventBusBasics`, adapted to Tingra's rules):

| Field | Type | Meaning |
| :---- | :--- | :------ |
| `group` | closed enum | What kind of event: `app`, `error`, `event`, `network`, `tap`, `trace`. |
| `domain` | open, string backed | Which part of the system: an engine service or a plug-in identifier. |
| `name` | `String` | Dotted lowercase identifier, e.g. `stream.started`, `device.disconnected` (letters, digits, `_`, `.`). |
| `params` | `[String: EventValue]?` | Structured payload; `EventValue` is a small `Sendable`, `Codable` enum (string, int, double, bool). |
| `from` | `String` | Call site, captured via `#fileID`/`#function` default arguments. |

### Groups (the routing axis — generic, closed, stable)

The six groups come from `EventBusBasics` unchanged; they are deliberately application agnostic, so every sink can route any event without knowing the domain that produced it:

| Group | Meaning | Default sink level |
| :---- | :------ | :----------------- |
| `app` | Process lifecycle: launch, version, shutdown. | info |
| `error` | Any error. | error |
| `event` | A notable occurrence: stream started, recording finalized. | info |
| `network` | Network requests, connections, reconnects. | debug |
| `tap` | User tapped/clicked something. | info |
| `trace` | Engine activity tracing for debugging. | debug |

The group enum is closed: sinks must handle every case, so new groups are a deliberate, rare design change.

**The `tap` convention (decided 2026-07-06, once the app had its first button):** every direct user action in `apps/tingra` — a `Button`'s action closure, a `Picker`'s `onChange` — calls `eventBus.tap(_:domain:params:)` before doing anything else, recording the user's action as its own event. **No control is exempt**: close/back/cancel/OK buttons and any future alert, sheet, or toolbar dismissal get the same call as a content-producing button like the shot switcher — "just navigation" or "just dismissal" is not a reason to skip it. This call is made **in the view code itself, at the exact point the action executes** (`ContentView`, not `EngineModel`) — `EngineModel.eventBus` is deliberately not `private` so the view can reach it directly, keeping the tap a record of what the *view* did rather than something the model infers on the view's behalf. It is distinct from whatever `event`-group record the resulting action produces (e.g. the shot switcher's `composition/camera.button` tap precedes the compositor's own `composition/program.take`; the camera/display pickers' `capture/camera.picker` and `capture/display.picker` taps precede the resulting `capture/input.started`/`input.stopped`). **Tap names are per-control, not per-screen or per-app** (Larry, 2026-07-06): the shot switcher's three buttons each get their own name (`camera.button`, `display.button`, `pip.button` — see `ProgramLayout.tapName(forShotID:)`) rather than one generic `shot.switcher` name told apart only by params; a name only needs to be clear and unique on the screen it's on, not across the whole app. Two events for one action is deliberate: the tap is the input, the `event` is the effect, and keeping them separate is what makes the bus a faithful record for later macro capture/replay (GLOSSARY.md, "Macro") rather than a single blended log line.

The CLI's console sink filters `tap` out by default (surfaced only under `--verbose`), since it has no UI to tap. The app's own dev console (`ConsoleEventSink`) does **not** copy that filter — it has no `--verbose` equivalent, and `tap` is exactly what a developer watching it wants to see now that there's a button to click — so its default groups are `app`/`error`/`event`/`tap`, one wider than the CLI's.

### Domains (the attribution axis — Tingra specific, open)

The domain answers "who said it." Well known domains mirror the engine services in ARCHITECTURE.md — `capture`, `composition`, `audio`, `compression`, `output`, `plugin`, `control`, `platform` — plus `session`. Third party plug-ins use their plug-in identifier as the domain. The set is open (string backed with static constants, not a closed enum) because plug-ins must be able to add their own without touching the host.

The two axes compose without ambiguity: a stream connection failure is `group: .error, domain: .output, name: "stream.connect.timeout"` — it routes as an error in every sink, and filters as output activity.

`error` events additionally carry a stable `identifier` param (plus a human `message`): the machine-readable failure code scripts and exit-code mapping key off, drawn from the append-only registry in CLI.md ("Error identifiers").

## Sinks

```
engine services & plug-ins
        │  eventBus.send(...)
        ▼
    EventBus (host)
        ├──►  OSLog sink        Console.app, `log stream`, sysdiagnose (skipped when stderr is a terminal)
        ├──►  Console sink      tingra-cli human output, or NDJSON under --json
        ├──►  File sink         attached by --log-file
        └──►  Status sink       feeds MCP stream_status and --stats-interval
```

- **OSLog sink** — the system of record. Uses `os.Logger` with `subsystem` = `com.moonwink.tingra` and `category` = the event's **domain** (a 1:1 mapping). Group maps to level per the table above. Event names and groups interpolate as public; **params interpolate as `privacy: .private` by default**.

  `tingra-cli` attaches it unless standard error is a terminal (decided 2026-07-04): when stderr is a TTY, macOS's own unified-logging terminal mirror already echoes the process's `os_log` traffic there, so attaching the sink too would print every event a second time, interleaved with the console sink's formatted lines. Interactive runs lose nothing — the console sink already told the human everything — while every non-interactive context (scripts, launchd, redirected or piped output, `--json` consumers) still gets OSLog as the system of record, since the terminal mirror never runs there. This is a `tingra-cli` policy, not a change to the sink itself; a future host that always runs non-interactively (the `serve` daemon) attaches it unconditionally.
- **Console sink** — owned by `tingra-cli`. In human mode it prints formatted lines (the shared format below); under `--json` it serializes the same events as newline delimited JSON (`{"ts": …, "group": …, "domain": …, "name": …, "params": …}`). The `--json` status events in CLI.md (started, stats, reconnecting, stopped, error) *are* bus events — one source of truth for humans, scripts, and agents. `--verbose`/`--quiet` are group/level filters on this sink; timestamps use `Date.FormatStyle`, never legacy formatters.
- **File sink** — attached when `--log-file` is passed; same formatted lines as the console's human mode, byte for byte.

### The human log line format

One line format is shared by every text sink — the CLI's console (human mode) and file sinks and the app's console sink:

```
LEVEL MM-DD-YYYY HH:MM:SS.mmm TZ [SSSS] @ domain name key=value …
```

It is produced by a single `LogLineFormatter` that lives in the host package (`TingraHost`), not any one front end, so every app renders events identically; `LogLineFormatter` and its `LogSession` cold-start anchor moved there (from `tingra-cli`) the moment a second front end — `apps/tingra` — needed the same format.

— a fixed-width, **right-justified** level (`" INFO"`, `"DEBUG"`, `"ERROR"`: the group's default sink level from the table above, leading-space padded so every level ends in the same column), a local-time timestamp with milliseconds and time zone, the four-digit **log session ID** in square brackets, `@`, then the body. For every group but `tap`, the body is the event's domain, name, and sorted `key=value` params. Example:

```
 INFO 07-04-2026 15:50:02.250 EDT [0042] @ capture device.connected id=BuiltInMicrophoneDevice kind=microphone name=MacBook Pro Microphone
```

**A `tap` event's body renders differently** (decided 2026-07-06, matching the style of Larry's Dart `EventBusBasics` tap line): `tap=>name - {key: value, key2: value2}` — the domain is dropped from view entirely (a tap's params already carry whatever attribution matters), params use a colon-space, comma-separated map literal rather than `key=value`, sorted by key like every other group. Example, for the app's shot switcher:

```
 INFO 07-06-2026 15:50:02.250 EDT [0086] @ tap=>pip.button - {name: Picture in Picture, shot: pip}
```

The log session ID increments exactly once per cold start (persisted in Application Support; for `tingra-cli` today every launch is a cold start, and the `serve` daemon's warm starts will keep the same ID). That makes it a reliable cold-start anchor: a change from `[0042]` to `[0043]` marks a new process, and grouping lines by session ID separates the sessions interleaved in one file. It is a log anchor only — distinct from the engine **session** in GLOSSARY.md.
- **Status sink** — retains recent stats/state events so MCP's `stream_status` and the CLI's `--stats-interval` report from live data without polling the pipeline.

Sinks subscribe over `AsyncStream` and each applies its own filtering; attaching or detaching a sink never affects emitters or other sinks.

### Why OSLog and not swift-log

The bus is the API code actually calls, so the logging framework is invisible outside the OSLog sink — which makes this choice low stakes and swappable. OSLog wins on Tingra's own rules: it is the native framework (swift-log would be a third dependency for zero gain; Tingra never runs server side), it has built in privacy redaction, and its output lands in Console.app and sysdiagnoses where Mac users and bug reporters can retrieve it.

## Redaction

Two layers, strongest first:

1. **Secrets never become event params.** Stream keys and secure storage contents are referenced by identifier or fingerprint (`live_xx…` at most), never by value. This is the policy; the bus does not inspect or alter params — a heuristic key-name matcher (`key`, `streamKey`, `token`, `password`, …) was tried and dropped: it cannot be made bullet proof (it both over-matches innocuous keys and under-matches spellings it doesn't anticipate), so it added false confidence without a real guarantee. Emitters are the only correct place to keep a secret off the bus.
2. **OSLog privacy.** Params interpolate `.private` by default in the OSLog sink, so anything that shouldn't have been a param in the first place still stays out of retrievable logs on release builds.

This implements the "never log secrets" rule in CLAUDE.md end to end.

## Package and porting notes

The bus ships as a **zero dependency leaf package** under `packages/` (as `EventBusBasics` is today in AutoCareCloud). The plug-in protocol package depends on it so third party plug-ins can emit events — which works precisely because the bus depends on nothing. Whether it lands as an evolution of the shared personal `EventBusBasics` package or a Tingra named port is open; the changes below are generic enough to be upstreamed.

Deltas from today's `EventBusBasics`, driven by Tingra's rules in CLAUDE.md:

| Today | Tingra port |
| :---- | :---------- |
| Combine (`PassthroughSubject` / `AnyPublisher`) | `AsyncStream<EventBusEvent>` with multi subscriber support |
| `params: [String: Any]?` (not `Sendable`) | `[String: EventValue]?` with `EventValue: Sendable, Codable` — also what makes NDJSON serialization trivial |
| `class EventBus` (unisolated) | `Sendable` (lock protected `final class`, or an actor) |
| `Thread.callStackSymbols` for `from` | `#fileID`/`#function` default arguments — free and strict concurrency safe |
| `DateFormatter` in the logger | `Date.FormatStyle` in the sinks |
| No domain axis | `domain` parameter added alongside `group` |
| `EventBusLogger` (one class, three flags) | Separate sink implementations behind one subscriber protocol |
| Platforms: iOS 18 / macOS 15 / Catalyst | macOS 15 |

## Open questions

- Package identity: evolve `EventBusBasics` upstream (shared across Larry's projects) vs. a Tingra named fork under `packages/`.
- Buffering policy per sink when a subscriber is slow (drop oldest vs. suspend emitter — a slow sink must never back pressure the engine).
- Whether the status sink's retained state is the same store the session manager uses, or a read model derived from it.
