# The Tingra MCP Server

How AI agents control Tingra, and how the pieces of `tingra-cli` talk to each other. This document defines the process architecture around the persistent engine daemon (`tingra-cli serve`), the transport between it and its clients, and the requirements that make the MCP surface product grade — it is a first class interface for macOS users and their agents, not an internal tool. CLI.md defines the tool surface itself; vocabulary follows GLOSSARY.md.

## Design principles

1. **One protocol.** The daemon speaks [MCP](https://modelcontextprotocol.io) JSON-RPC natively. There is no separate internal control protocol that MCP translates into — the MCP tool schemas (a stable contract per the Data Models rules in CLAUDE.md) are the only control schema. Nothing can drift, because there is nothing to drift from.
2. **One owner.** `tingra-cli serve` is the only process that owns the engine: the session, the pipeline, and the TCC identity. Everything else is a client.
3. **Thin edges.** `tingra-cli mcp` is a transparent proxy, not a smart client. All intelligence lives in the daemon.
4. **No network listener.** v1 exposes a Unix domain socket only — never a TCP port. Remote control (MCP Streamable HTTP) is a possible later opt-in, out of scope for v1.

## Process architecture

```
Claude Desktop / Claude Code / any MCP host          scripts (python, nc, ...)
        │ spawns; MCP JSON-RPC over stdio                    │
        ▼                                                    │
  tingra-cli mcp                                             │
  (transparent proxy: stdio bytes ⇄ socket bytes)            │
        │                                                    │
        └────────────────┬───────────────────────────────────┘
                         ▼
   ~/Library/Application Support/Tingra/tingra.sock    (dir 0700, same user only)
                         │  launchd socket activation
                         ▼
                 tingra-cli serve
   (the engine daemon: session, pipeline, plug-ins, TCC identity)
```

- **The daemon** hosts the engine and its MCP tool registry (plug-in contributed, per CLI.md). It accepts multiple concurrent socket connections.
- **`tingra-cli mcp`** copies bytes between stdin/stdout and the socket, mapping lifecycles (stdin EOF → close connection; connection closed → exit). It contains no protocol logic — on the order of a hundred lines — which is what reconciles agent host process lifecycles with the persistent daemon, as CLI.md promises.
- **Direct socket clients** are supported and welcome: the wire format is documented (below), so users can script the engine from any language without the proxy.

## The transport

**A per-user Unix domain socket carrying MCP JSON-RPC with stdio framing** (newline delimited JSON-RPC messages, exactly as the MCP stdio transport defines). Using identical framing on both sides is what lets the proxy be a pure byte pipe.

- **Path:** `~/Library/Application Support/Tingra/tingra.sock`. Fixed and short — macOS caps UDS paths at 104 bytes, so the socket never lives under a deep project directory.
- **Permissions:** the containing directory is mode `0700`; only the owning user can connect. As defense in depth the daemon verifies the peer's uid via `getsockopt(LOCAL_PEERCRED)`; verifying the peer's code signature via its audit token (`LOCAL_PEERTOKEN`) is optional hardening, noted for later.
- **Sessions:** each accepted connection is an independent MCP session with its own `initialize` handshake. The `initialize` response carries the daemon's build version.

### Why not XPC

XPC is the native RPC, but it is wrong for this seam: a Mach service would couple the design to launchd naming while *also* introducing a second message format — every MCP request would be translated into XPC messages and back, doubling the schemas to maintain and test. XPC is also Apple-frameworks-only, closing the direct-socket scripting path. The one XPC advantage worth keeping — launchd lifecycle — is available to a UDS directly via socket activation (below). Codesigning peer checks, XPC's other advantage, are available via the audit token if ever needed.

### Why not localhost HTTP

A TCP listener on 127.0.0.1 is reachable by every local process **and by browser JavaScript** — DNS rebinding and CSRF against localhost servers are documented attack classes that the MCP spec itself warns about, requiring Origin validation and auth to mitigate. A Unix domain socket in a `0700` directory is immune by construction: same user only, and browsers cannot open one. If remote control ships later, it will be MCP Streamable HTTP as a deliberate, authenticated opt-in — not a default listener.

## Implementation: a hand-rolled JSON-RPC layer, not the official SDK

The daemon speaks MCP JSON-RPC through a small, first-party protocol layer in `packages/TingraMCP`, not the official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) (decided 2026-07-05; TODO.md carried the open question). The SDK is a fine piece of work — Apache-2.0/MIT (license-compatible), Swift 6 with strict concurrency, and a `Transport` seam that could in principle carry our UDS — but adopting it is the wrong trade for Tingra:

- **Dependency weight against the grain.** The SDK pulls in SwiftNIO, swift-log, swift-system, and an SSE `eventsource` client transitively. That is a server-side networking stack for a Mac-only app that CLAUDE.md says "never runs server side," and it drags **swift-log** back in — the exact dependency EVENTS.md rejected by name ("a third dependency for zero gain"). Our OSLog sink stays the system of record; nothing should smuggle swift-log underneath it.
- **The subset we need is tiny.** v1 speaks newline-delimited JSON-RPC 2.0 over a UDS — `initialize`, `tools/list`, `tools/call`, and one notification. That is a few hundred lines behind the MCP/Control seam, fully under our Swift 6 strict-concurrency and warning-clean rules, with no custom-transport impedance mismatch against a library built around its own async model.
- **We owe direct socket clients a documented wire format regardless.** MCP.md commits to letting users script the engine over the raw socket without the proxy (see "The transport"). Owning the framing and message types makes that contract explicit and unit-testable rather than an emergent property of a third-party library.

This is the flip side of ARCHITECTURE.md design principle 4: adopt the standardized *protocol* (MCP, verbatim on the wire), implement the *thin transport* ourselves rather than importing a heavy stack for it — the same reasoning that keeps HaishinKit (a genuinely large, differentiated body of work) as a dependency while the JSON-RPC framing is not. If the protocol layer ever grows past what is comfortable to maintain by hand (Streamable HTTP, resource subscriptions, sampling), revisit the SDK then, behind the same seam. The layer stays confined to `TingraMCP`; the rest of the engine sees only the tool registry and the MCP/Control service.

## Lifecycle: launchd socket activation

The daemon is a **LaunchAgent, socket activated**: the LaunchAgent plist declares the socket path, launchd owns the listening socket, and the first connection starts `tingra-cli serve` (which adopts the socket via `launch_activate_socket`).

**The deciding reason is TCC attribution.** macOS attributes a process's privacy access (Camera, Microphone, Screen Recording) to its *responsible process*. If the daemon were fork/exec'd by `tingra-cli mcp` — itself spawned by an agent app — the responsible process would be the agent app: camera prompts would say "Claude Desktop wants to access the camera," and grants would fragment across every agent host the user runs. A launchd-parented daemon is its own responsible process: prompts name Tingra, and authorization attaches to Tingra's stable signing identity (the same identity CLI.md commits to keeping stable across releases). This resolves the open question in CLI.md — the daemon is launchd managed, not manually launched, in the product path.

- **Registration:** the LaunchAgent (label `com.moonwink.tingra.serve`) is installed and bootstrapped on first use (`tingra-cli serve --install`, also run by the Homebrew formula). `serve --uninstall` removes it.
- **Idle exit:** the daemon exits after a quiet period with no connections **and** nothing streaming or recording. It never idle-exits mid-stream. launchd revives it on the next connection, so clients simply connect and the engine is there — no client ever manages daemon lifetime.
- **Manual mode:** running `tingra-cli serve` in a terminal (foreground, creating the socket itself) remains supported for development and debugging. Roadmap step 4 shipped manual mode; the launchd install path below (the `--install`/`--uninstall` flags and the plist) landed 2026-07-09 (`LaunchAgent`/`LaunchdSocket` in `TingraMCP`, over the `CTingraLaunchd` shim for `launch_activate_socket`). `serve` auto-detects its mode — it adopts a launchd-supplied socket when present and otherwise binds its own.
- **Crash recovery:** if the daemon dies, launchd restarts it on the next connection. Honest semantics: an active stream dies with the daemon, and v1 session state is rebuilt fresh — clients discover this through the `initialize` handshake and status tools, never by guessing.

**The LaunchAgent plist (as implemented).** `serve --install` writes `~/Library/LaunchAgents/com.moonwink.tingra.serve.plist` and bootstraps it (`launchctl bootstrap gui/$UID …`); `--uninstall` reverses it (`launchctl bootout` then remove the file). launchd owns the listening socket declared under `Sockets` and hands it to the daemon on first connection, which adopts it with `launch_activate_socket("Socket")` in place of `manual` mode's own `bind`/`listen`. The plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>com.moonwink.tingra.serve</string>
    <key>ProgramArguments</key>  <array><string>/opt/homebrew/bin/tingra-cli</string><string>serve</string></array>
    <key>Sockets</key>
    <dict>
        <key>Socket</key>
        <dict>
            <key>SockPathName</key> <string>/Users/USER/Library/Application Support/Tingra/tingra.sock</string>
            <key>SockPathMode</key> <integer>384</integer> <!-- 0600 -->
        </dict>
    </dict>
    <!-- No RunAtLoad: socket activation starts the daemon on first connect, not at login. -->
</dict>
</plist>
```

The key seam: `Daemon.init(listeningDescriptor:…)` takes a ready descriptor, so the launchd path constructs the daemon with the socket `LaunchdSocket.activate()` adopted while `Daemon.manual(socketPath:…)` creates its own — the accept loop, sessions, and idle-exit are identical either way. The `TCC attribution` reason above is why the launchd path matters for the product path even though manual mode is functionally complete.

## Sessions and concurrency

Many MCP sessions, one engine session (GLOSSARY.md: the session is the live running state of the engine). All connections are views onto the same engine state:

- Mutating tools operate first come; a conflicting `stream_start` while a stream is active returns a structured tool error naming the active session (one active stream, per CLI.md).
- **"One active stream" means one session with N destination legs**, not one destination (roadmap step 8). `stream_start` names its destinations either with the `url`/`key` pair (one destination, the common case) or with a `destinations` array of `{url, key}` objects — passing both is an error, since the order, and therefore each leg's identity, would be ambiguous. Either way it returns **one** session id, and `stream_stop` takes it down whole. `stream_status` reports each leg under `destinations` (`destination`, `url`, `state`, and that leg's own `elapsed`/`bytesSent`/`bitrate`/`fps`), while its flat top-level fields stay the **first** destination's — identical for a single destination, and never an average across legs that describes none of them. Legs are named `destination-1`, `destination-2`, … in the requested order. Concurrent *sessions* remain out of scope: they would break both the coordinator and the idle-exit guard below.
- A destination that refuses the connection at start does **not** fail `stream_start` while another goes live (the CLI's best-effort start, per CLI.md); the refusal is reported on the event bus and the leg reads as `state: "rejected"` in `stream_status` (see "Tool surface", leg states). `stream_start` fails only when every destination is refused.
- **A `stream_start` with `record` and no destination starts a record-only session** (decided 2026-08-06, with the `record` field — see "Tool surface"). The engine has allowed a zero-destination session with a recording since "Recording in the app" (ARCHITECTURE.md); the daemon is the first headless surface to offer it. It occupies the one engine session like any other — a conflicting `stream_start` gets the same structured error — the idle-exit guard already reads "nothing streaming **or** recording", and a recording failure ends it (`stream.stopped`, `reason: recordingFailed`) because there is nothing left to keep running. A `stream_start` with neither a destination nor `record` is an `invalidArgument`, the tool-surface analog of the engine's "nothing to feed at all" guard. The CLI still requires `--url` — its contract is stream-shaped and its exit codes carry a stream's fate — so record-only remains deliberately unoffered there.
- Status changes broadcast to connected sessions as MCP notifications, fed by the event bus **status sink** (EVENTS.md). Agents never poll — consistent with the project-wide no-polling rule.
- **Stream keys are transient in the daemon** (decided 2026-08-05). A key arrives as `stream_start` tool input and is held only for the life of the session it starts — the coordinator keeps the requested legs so `stream_status` can report each one — then released on **every** teardown path: an explicit `stream_stop`, a duration elapse, a lost connection, and a start that never went live. The daemon never writes a key to secure storage, so nothing outlives the session and nothing outlives the daemon; a later `stream_start` supplies the key again. Keys are never returned by any tool or event, only referenced redacted (`live_xx…`), per the redaction policy in EVENTS.md.
- **Why the app persists keys and the daemon does not.** The app files each stream key in the host's Keychain backed secure storage, keyed by destination id, because an operator authors a destination once and returns to it — the key belongs to a document with an owner. The daemon's caller is an agent that already holds the key it is calling with, so persisting would create a secret at rest that no one owns and nothing expires. Durable keys arrive with the destination model, and they arrive as *the destination's* property, not the daemon's. **That model landed 2026-08-15** (DESTINATIONS.md): `stream_start` may now *resolve* a key by reference from the operator's store, and the resolved key is transient in the daemon on exactly the same terms as an inline one — the daemon still never writes a key, never returns one, and releases every key on every teardown path.

## Product grade requirements

The MCP surface is a shipping feature for end users, so it carries product obligations:

- **Stable contract.** Tool names, input schemas, and result shapes follow the Data Models rules in CLAUDE.md: camelCase, stable across releases, round-trip tested. Renames are breaking changes.
- **Version skew.** After an upgrade a stale daemon may still be running. Clients compare the `initialize` build version with their own and surface a clear advisory; the stable contract keeps mismatched-but-compatible versions working meanwhile.
- **Errors that teach.** Tool errors are structured and actionable — what failed, why, and what to do (e.g. authorization denied → which permission and how to grant it in System Settings). Exit-code semantics from CLI.md map to error identifiers, not message wording.
- **TCC never bypassed.** Authorization prompts appear on the Mac's screen for the user; an agent cannot self-approve. Tools report authorization state (`GLOSSARY.md: authorization`) so agents can explain to the user what to do rather than failing opaquely.
- **Diagnosable.** The daemon reports health through a tool and through `tingra-cli version` (daemon reachable, version, uptime); everything it does is observable through the event bus sinks (EVENTS.md).

## Tool surface

Defined in CLI.md ("`tingra-cli serve` and `tingra-cli mcp`"): the initial host and first party tool set (`devices_list`, `probe`, `stream_start`, `stream_status`, `stream_stop`) mirrors the CLI flags, and plug-ins contribute tools to the host's tool registry, aggregated and namespaced by the MCP/Control service — the agent facing API and the plug-in API stay the same shape.

**The session id is optional on `stream_status` and `stream_stop` — decided 2026-08-11.** With one active stream in v1 there is never ambiguity to resolve, and requiring the id made the natural queries ("give me the current stream status", "stop the stream") unanswerable for an agent that reconnected to a daemon already mid-show — the id is a random mint (`stream-xxxxxxxx`) it never held. An omitted (or JSON null) `sessionId` addresses the active stream; an explicit id must still match it (`invalidArgument` otherwise, unchanged); a present-but-non-string value is `invalidArgument`, never a silent omission. The two tools diverge deliberately when nothing is active: `stream_status` returns `{"state": "idle"}` — "nothing is streaming" is a truthful status, not a failure — while `stream_stop` returns a structured `noActiveStream` error, because there is nothing truthful to have stopped. The schema change is append-only (`required` dropped), so a caller passing the id behaves exactly as before.

**Leg state is derived, not inferred from counters — decided 2026-08-11.** Each destination leg in `stream_status` reports a `state` derived from the status sink's retained per-leg events (the same events CLI.md defines): `pending` (no per-leg event yet — start still settling), `live` (the leg's connection opening — `stream.destination.started` — a `stream.reconnected` recovery, or a stats sample is the newest word), `reconnecting` (a `stream.reconnecting` newer than the last recovery and the last stats — the leg dropped and its budget is being spent), `lost` (`stream.destination.lost` — budget exhausted, terminal for the run), and `rejected` (`stream.destination.rejected` — refused at start, terminal for the run). Previously a leg read `live` from the mere presence of a stats sample, so a dropped leg wore stale counters as current. A degraded leg keeps its last counters — they are the last truth, and `state` says whether they are current. Because leg ids are positional (`destination-1` in every session) and the sink retains across sessions, every per-leg read is floored at the session's start time — without the floor, a fresh session's leg would inherit the previous session's counters and verdicts. The flat top-level fields remain the first destination's. The connection opening counts as delivery because `stream_start` only returns once a leg is connected — waiting for its first stats sample would report a delivering leg as `pending` for a whole stats interval.

**The top-level `state` is derived from the legs — decided 2026-08-15.** The session state was previously hardcoded `live` for any active session, on the reasoning that the session *is* running while its legs carry their own condition. A live run showed what that costs: with the session's only healthy leg reconnecting, the report read `"state": "live"` above a leg reading `"reconnecting"` — the headline contradicting the detail, and an agent that reads only `state` (the obvious field to read) getting the wrong answer. The session's `state` now answers *is this stream delivering?*, since the session's mere existence is already told by there being a report at all:

- `live` — every leg that has reported is delivering, or the session has no destinations at all (a record-only session is doing exactly what it was asked to).
- `degraded` — some legs delivering and some not, or none delivering while a reconnect budget is still being spent. Something is wrong; recovery is still possible.
- `lost` — every leg ended terminally (`lost` or `rejected`); nothing recovers without a new session.
- `pending` — legs exist and none has reported yet.
- `idle` — no session at all (unchanged).

A leg that has not reported yet is not evidence either way, so `pending` legs are set aside unless *every* leg is pending — without that, a two-leg session would read `degraded` on the way up, before its second leg had been heard from. They are **not** set aside when judging terminality: one pending leg among ended ones leaves the session `degraded`, because it may still come good. Pre-release this is an addition to the value set, not a version bump (the no-versioning rule).

**Recording joins the tool surface as the `record` field on `stream_start` — decided 2026-08-06** (it had been deliberately left out on 2026-07-05, roadmap step 5; this lands the additive path that deferral planned for). `record` is an optional file path for a simultaneous local recording of the program, reusing the same `RecordingService` the CLI's `--record` drives: the extension selects the container (`mov`/`mp4`) through `OutputRegistry.recordingProvider(forFileExtension:)` — the same resolution the CLI and the app use, no second path — and any other extension is a structured `invalidArgument` (the analog of the CLI's exit 64). There is still no `record_start`/`record_stop` pair, and that is a decision, not an omission: the coordinator owns one engine session whose sinks are configured at start, so a recording is a property of the session, not an independent lifecycle — mid-show record control is the app's surface, where a human sits (ARCHITECTURE.md, "Recording in the app"). If an agent ever needs the pair, it reuses the app's second-session shape and the coordinator generalizes then, not now.

**The identity consideration the deferral named resolves rather than lingers.** The daemon runs as a LaunchAgent in the operator's GUI session (see "Lifecycle"), so a file it writes is created under the operator's own uid and home exactly as an app-written file is — there is no other identity for it to write under. What the deferral was actually protecting is **location**: Desktop, Documents, and Downloads are TCC-protected, and a files-and-folders prompt raised by a headless tool call can appear with nobody at the screen. The answer is guidance, not an enforced allowlist — the documented recommendation for agents is `~/Movies` (unprotected, where macOS already puts video, and the app's default for the same reasons), and a TCC-refused location surfaces as the same `recordingFailed` any unwritable path does — because the operator's agent carries the operator's own authority, just as their shell running `tingra-cli stream --record ~/Desktop/take.mp4` does, and a folder allowlist would be a policy the CLI does not have and no one owns. The path must be absolute, with a leading `~/` expanded against the daemon's home as the one convenience (anything else is `invalidArgument` — the daemon's working directory is meaningless). The daemon adds no filename policy, no date stamp, and no overwrite protection beyond the service's own — the path is the caller's, verbatim; the app's never-overwrite rule stays the app's. A recording path is not a secret and appears as-is in events and results (EVENTS.md redaction governs keys, not paths).

**Semantics are the CLI's, inherited through the seam.** A recording that cannot open fails `stream_start` (`recordingFailed`) before anything connects, including the five-minute free-space floor that lives in the service's `start(to:)`; a write failure once rolling is reported on the bus and the stream carries on; `stream_stop` already promised to "finalize any recording," and now does, as do the other teardown paths. `stream_status` gains an optional `recording` object (`path`, `container`), present while the recording is open and absent once it has finalized or failed — the same absence contract a rejected destination leg has. `recording.started`/`recording.stopped` already broadcast through the status-sink notification path like every other session event; nothing new is emitted, and the session `label` stays nil for the daemon.

**Named destinations landed as `destinations_list` and a `destination` selector — approved and built 2026-08-15** ([DESTINATIONS.md](DESTINATIONS.md) is the decision record; this is what the tool surface now says). An agent can resolve "my Twitch" without ever holding a key:

- **`destinations_list`** returns the operator's saved destinations: `id`, `name`, `url`, and `hasKey`. **Never a key and never a fragment of one** — `hasKey` is the whole of what an agent needs to know about the secret. It takes no arguments.
- **`stream_start` and `probe` accept `destination`**, a selector naming a saved destination by id or by name, in place of `url`/`key`. On `stream_start` it appears either at the top level (one destination) or as `{"destination": …}` items in the `destinations` array, **mixable with raw `{url, key}` items** — each leg resolves independently, exactly as mixed transports do, and leg ids stay positional (`destination-1`, …) whichever form named them. Passing more than one form at once is `invalidArgument`, as is a `key` beside a `destination`: a saved destination carries its own key, and silently choosing between two would make the result unreadable.
- **Selector resolution mirrors input selection**, so an agent learns one rule: an exact id wins outright; otherwise a case-insensitive name match that must match exactly one. There is deliberately **no index form** — a store index is not stable across an edit and never appears in an agent's context, where the name it was given is the point. The failures are the two new append-only identifiers `destinationNotFound` and `destinationAmbiguous` (CLI.md, "Error identifiers"), beside `inputNotFound`/`inputAmbiguous`.
- **The agent surface is read-only, and that is the decision.** There is no `destination_add`: putting keys back into agent input is exactly what the store exists to end. The app remains the editor, where the operator pastes the key once.
- **The transient-key policy is unchanged in substance.** A key resolved from the store is held for the life of the session and released on every teardown path, exactly as an inline one is; the daemon still never writes a key and no tool ever returns one. What changed is only where a key may be *read* from — the store amends the ownership answer (the operator owns a saved destination), not the transience answer.
- **`destinations_list` deliberately carries no live leg state** (the first of DESTINATIONS.md's two open questions, answered 2026-08-15: no). One tool per question. There is also no id to join on — MCP leg identity is positional, never the store id, so a join could only match URL strings, which is the fragile inference the 2026-08-15 leg-state decision moved away from — and a store read must answer with nothing streaming, where the field would be absent on most calls. An agent that wants both reads both and matches on `url`.
- **An unsigned development build degrades honestly.** Names and URLs resolve from the JSON document, which needs no entitlement; a key the process cannot read reports `hasKey: false` in the listing, with the reason on the event bus, and a `pipelineError` naming the fix (run a signed binary) if that destination is actually used to stream. The shipped CLI is Developer ID signed, so this is a development seam, not a product state.

## Open questions

- Whether one-shot CLI subcommands (`stream`, `devices`, `probe`) should route through a running daemon when present, or stay fully in-process as v1 assumes (current answer: in-process — simple, reliable, no daemon dependency for scripting; revisit when the app arrives and daemon-first becomes the norm).
- Version-skew policy beyond the advisory: auto-restart an idle stale daemon after upgrade?
- Signed-peer verification (`LOCAL_PEERTOKEN` + `SecCode`) — worth the complexity, or is same-uid enough given the `0700` directory?
- Remote control via MCP Streamable HTTP — demand, auth model, and whether it lives in the daemon or a separate front end.
