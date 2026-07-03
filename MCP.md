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

## Lifecycle: launchd socket activation

The daemon is a **LaunchAgent, socket activated**: the LaunchAgent plist declares the socket path, launchd owns the listening socket, and the first connection starts `tingra-cli serve` (which adopts the socket via `launch_activate_socket`).

**The deciding reason is TCC attribution.** macOS attributes a process's privacy access (Camera, Microphone, Screen Recording) to its *responsible process*. If the daemon were fork/exec'd by `tingra-cli mcp` — itself spawned by an agent app — the responsible process would be the agent app: camera prompts would say "Claude Desktop wants to access the camera," and grants would fragment across every agent host the user runs. A launchd-parented daemon is its own responsible process: prompts name Tingra, and authorization attaches to Tingra's stable signing identity (the same identity CLI.md commits to keeping stable across releases). This resolves the open question in CLI.md — the daemon is launchd managed, not manually launched, in the product path.

- **Registration:** the LaunchAgent (label `com.moonwink.tingra.serve`) is installed and bootstrapped on first use (`tingra-cli serve --install`, also run by the Homebrew formula). `serve --uninstall` removes it.
- **Idle exit:** the daemon exits after a quiet period with no connections **and** nothing streaming or recording. It never idle-exits mid-stream. launchd revives it on the next connection, so clients simply connect and the engine is there — no client ever manages daemon lifetime.
- **Manual mode:** running `tingra-cli serve` in a terminal (foreground, creating the socket itself) remains supported for development and debugging.
- **Crash recovery:** if the daemon dies, launchd restarts it on the next connection. Honest semantics: an active stream dies with the daemon, and v1 session state is rebuilt fresh — clients discover this through the `initialize` handshake and status tools, never by guessing.

## Sessions and concurrency

Many MCP sessions, one engine session (GLOSSARY.md: the session is the live running state of the engine). All connections are views onto the same engine state:

- Mutating tools operate first come; a conflicting `stream_start` while a stream is active returns a structured tool error naming the active session (one active stream in v1, per CLI.md).
- Status changes broadcast to connected sessions as MCP notifications, fed by the event bus **status sink** (EVENTS.md). Agents never poll — consistent with the project-wide no-polling rule.
- Stream keys pass through tool input into the host's Keychain backed secure storage and are never returned by any tool or event, only referenced redacted (`live_xx…`), per the redaction policy in EVENTS.md.

## Product grade requirements

The MCP surface is a shipping feature for end users, so it carries product obligations:

- **Stable contract.** Tool names, input schemas, and result shapes follow the Data Models rules in CLAUDE.md: camelCase, stable across releases, round-trip tested. Renames are breaking changes.
- **Version skew.** After an upgrade a stale daemon may still be running. Clients compare the `initialize` build version with their own and surface a clear advisory; the stable contract keeps mismatched-but-compatible versions working meanwhile.
- **Errors that teach.** Tool errors are structured and actionable — what failed, why, and what to do (e.g. authorization denied → which permission and how to grant it in System Settings). Exit-code semantics from CLI.md map to error identifiers, not message wording.
- **TCC never bypassed.** Authorization prompts appear on the Mac's screen for the user; an agent cannot self-approve. Tools report authorization state (`GLOSSARY.md: authorization`) so agents can explain to the user what to do rather than failing opaquely.
- **Diagnosable.** The daemon reports health through a tool and through `tingra-cli version` (daemon reachable, version, uptime); everything it does is observable through the event bus sinks (EVENTS.md).

## Tool surface

Defined in CLI.md ("`tingra-cli serve` and `tingra-cli mcp`"): the initial host and first party tool set (`devices_list`, `probe`, `stream_start`, `stream_status`, `stream_stop`) mirrors the CLI flags, and plug-ins contribute tools to the host's tool registry, aggregated and namespaced by the MCP/Control service — the agent facing API and the plug-in API stay the same shape.

## Open questions

- Whether one-shot CLI subcommands (`stream`, `devices`, `probe`) should route through a running daemon when present, or stay fully in-process as v1 assumes (current answer: in-process — simple, reliable, no daemon dependency for scripting; revisit when the app arrives and daemon-first becomes the norm).
- Version-skew policy beyond the advisory: auto-restart an idle stale daemon after upgrade?
- Signed-peer verification (`LOCAL_PEERTOKEN` + `SecCode`) — worth the complexity, or is same-uid enough given the `0700` directory?
- Remote control via MCP Streamable HTTP — demand, auth model, and whether it lives in the daemon or a separate front end.
