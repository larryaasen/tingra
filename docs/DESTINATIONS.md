# Destinations: the named destination model

**Status: approved 2026-08-15. Steps 2 and 3 of the sequencing are built; step 4 (the app adopting the store) is outstanding.** Each decision here lands in the doc that owns its area as it is built, per the decide-then-build rule: the store and the shared access group are in [TYPES.md](TYPES.md) and [README.md](../README.md), the tool surface in [MCP.md](MCP.md), and the two new error identifiers in [CLI.md](CLI.md). [GLOSSARY.md](GLOSSARY.md)'s Destination entry is rewritten with step 4.

## The problem

An operator says "stream to my Twitch" and "check my backup ingest" — and today no headless surface can resolve either phrase. Destination names live in the app's project document (`DestinationEdit`, GLOSSARY.md "Destination"): the operator's label ("Twitch"), the URL, and an enabled flag, with the stream key in the host's Keychain-backed secure storage under the destination's stable id. The daemon (MCP.md) deliberately holds keys only for the life of a session and knows nothing about projects, so an agent driving `stream_start` must be handed a raw URL and key every time. The MCP surface — the primary agent interface (CLI.md, design principle 4) — cannot answer the natural queries because it has no name→destination lookup at all.

This is the second of the two gaps the 2026-08-11 session-addressing decision (MCP.md, "Tool surface") left open: that decision made "stop the stream" and "give me the stream status" answerable; this model makes "my Twitch" answerable.

## The decision: destinations belong to the operator, not the project

**A destination is operator-global.** A Twitch account is not per-show: the same ingest endpoints recur across every project the operator makes, and the CLI and daemon have no project concept to scope them to. The destination — its stable id, name, URL, and key — is filed once, by the operator, and every surface resolves it by name or id. What stays with the project is the *use* of a destination: which destinations a show streams to and whether each is enabled remains project state, referencing the global destination by id.

This changes the GLOSSARY.md entry ("A project can hold many destinations") to: a project *references* destinations; the destinations themselves belong to the operator. Pre-release there is no migration (the no-versioning rule: the document format stays v1 until first release) — the app simply starts reading and writing the store, and any destinations authored in a pre-change project document are re-entered once.

## The store

**`DestinationStore` is a host service** (ARCHITECTURE.md "Engine services", Platform/Infrastructure — beside secure storage, which it builds on). Not a plug-in: the boundary test says host, because removing it breaks destination resolution for every surface, not one capability.

- **Names and URLs are not secrets** and live in a JSON document at `~/Library/Application Support/Tingra/destinations.json`: an array of `{id, name, url}` with stable camelCase keys under the Data Models rules. Human-inspectable, trivially backed up, and honest about what it is — there is nothing sensitive in it.
- **Keys stay in the host's Keychain-backed secure storage**, under the same `destination:<id>` account convention the app already uses today — the store changes who can *reach* a key, not where keys live. A destination without a stored key is legal (the app already streams keyless destinations to local endpoints); listings report `hasKey` so an agent can tell the difference.
- **Change events, not polling.** The store emits `destination.added` / `destination.changed` / `destination.removed` on the event bus (the app already emits the first and last from its panel; they become the store's), so every surface stays current the event-driven way.

## Key sharing between the app and the daemon

The host's `KeychainSecureStorage` already uses the data-protection keychain (`kSecUseDataProtectionKeychain`, service `com.moonwink.tingra`). Data-protection keychain items are partitioned by keychain access group, and the app and `tingra-cli` are different signed binaries — so today an item filed by one is invisible to the other.

**The decision: a shared keychain access group, `$(TeamIdentifierPrefix)com.moonwink.tingra.shared`,** declared in the `keychain-access-groups` entitlement of both the app and `tingra-cli`, with `KeychainSecureStorage` gaining an optional access-group parameter it passes as `kSecAttrAccessGroup`. This is the mechanism Apple provides for exactly this shape — same team, several binaries, one secret store — and it needs no ACL prompts and no legacy file-based keychain.

Two constraints this respects:

- **Nothing personal in a tracked file** (CLAUDE.md, "Signing"): the entitlement carries the `$(TeamIdentifierPrefix)` build variable, never a literal Team ID. CI builds with `CODE_SIGNING_ALLOWED=NO` are unaffected — entitlements bind at signing, and unit tests use the in-memory `SecureStorage` mock as they do now.
- **Unsigned development builds** (a bare `swift build` of the CLI) cannot join an access group. The store degrades honestly: names and URLs resolve (the JSON document needs no entitlement), and a key the process cannot read reports `hasKey: false` with a structured error naming the fix (run the signed binary) if the destination is used to stream. This is a development-only seam, not a product state — the shipped CLI is Developer ID signed (CLI.md, "Distribution").

## The transient-key policy, amended by reference

The daemon's policy (MCP.md, "Sessions and concurrency") was: keys arrive as tool input, live only for the session, and are never persisted by the daemon. The reasoning was that the daemon's caller already holds the key it passes, so persisting would create a secret at rest that no one owns. **The store changes the ownership answer, not the transience answer**: a saved destination is a document with an owner — the operator — exactly the reasoning MCP.md gave for why the app persists. The daemon still never writes a key, never returns one, and still releases every key on every teardown path; what changes is that `stream_start` may now *resolve* a key by reference from the operator's store instead of receiving it inline. Raw `url`/`key` input remains supported and remains transient — an agent handed a key for a one-off destination behaves exactly as today.

## The tool surface

- **`destinations_list`** — the operator's destinations: `id`, `name`, `url`, `hasKey`. Never a key, never a key fragment. The read that turns "my Twitch" into a URL an agent can also match against `stream_status` legs.
- **`stream_start` accepts `destination`** — in place of `url`/`key`, either at the top level (one destination) or as `{destination}` items in the `destinations` array, mixable with raw `{url, key}` items (each leg resolves independently, like mixed transports). Passing `destination` *and* `url` in one place is `invalidArgument`.
- **`probe` accepts `destination`** — validate a saved destination without going live, resolving its key the same way.
- **Selector resolution mirrors input selection** (CLI.md, "Selector resolution"), so agents learn one rule: an exact id wins outright; otherwise a case-insensitive name match that must match exactly one destination. Two new error identifiers complete the mirror, `destinationNotFound` and `destinationAmbiguous` (append-only, beside `inputNotFound`/`inputAmbiguous` in the registry).
- **Read-only for agents in v1 of the store.** The app remains the editor: creating and editing destinations — and filing their keys — is the operator's act, in the UI, where the key is pasted once and never transits an agent conversation. A `destination_add` tool (or a `tingra-cli destinations` subcommand) is deliberately deferred: it would put keys back into agent input, which is exactly what the store exists to end. If demand materializes, it lands as its own decision.

## What the app changes

The sidebar's destinations section and the streaming panel read and write the store instead of the project document; the project keeps per-show state (which destinations, enabled flags) as references by id. `DestinationEdit` stays the edit model; its persistence target moves. The app's never-overwrite and confirmed-delete behaviors are unchanged — a store-backed delete removes the key from secure storage exactly as the panel does today.

## Sequencing

1. ~~**This document** — the veto gate.~~ Approved 2026-08-15.
2. ~~**`DestinationStore` in `TingraHost`** + the shared access group (entitlements in both targets, the access-group parameter on `KeychainSecureStorage`), with store unit tests over a temporary directory and the in-memory secure storage.~~ Built 2026-08-15.
3. ~~**The MCP tools** — `destinations_list`, the `destination` selector on `stream_start`/`probe`, the two identifiers, round-trip tests, and the MCP.md/CLI.md records.~~ Built 2026-08-15.
4. **The app adopts the store** — sidebar and panel move over; GLOSSARY.md's Destination entry is rewritten to the reference model.

Steps 2–3 make every query in the motivating set answerable headlessly; step 4 removes the last duplicate ownership.

### What steps 2–3 settled that step 4 should know

- **`kSecAttrAccessGroup` needs the team-prefixed group string, and the prefix is not knowable from source.** `KeychainSecureStorage.sharedAccessGroup()` reads it back out of the running binary's own `keychain-access-groups` entitlement (`SecTaskCreateFromSelf`), which the signing process has already expanded — so the value is right at runtime and no Team ID ever appears in a tracked file. It returns nil for an unsigned build, which is exactly the honest-degradation signal.
- **`codesign` does not expand `$(TeamIdentifierPrefix)`; Xcode does.** The app target gets the expansion for free; `scripts/release-cli-package.sh` now substitutes the Team ID out of `TINGRA_SIGN_ID` into a throwaway entitlements copy at signing, and deletes it after.
- **The entitlement needs the Keychain Sharing capability on the App ID.** Adding `keychain-access-groups` makes a locally signed Xcode build fail against the wildcard "Mac Team Provisioning Profile: \*" until the capability is added once (Xcode's Signing & Capabilities, or `xcodebuild -allowProvisioningUpdates`). CI is unaffected — it builds `CODE_SIGNING_ALLOWED=NO`.
- **Adding the entitlement changes which group *new* items go to.** With `keychain-access-groups` present, an item written with no explicit group lands in the first entry of that list rather than the app's application-identifier group. Keys the app filed before this change stay readable by the app and stay invisible to the CLI, so step 4 should file keys into the shared group and expect the operator to re-enter any authored earlier — the same one-time re-entry this document already accepted for pre-change project documents.
- **The store caches nothing.** Every read goes to the file, because the app and the daemon are separate processes over one document. That is a point read on demand, not a poll. The consequence for step 4: the change events reach in-process subscribers only, so the app's `@Observable` list stays current by reading after its own edits, and a cross-process observer stays current by reading rather than listening. If step 4 wants the app to react to a *daemon-side* change, that needs a file watcher and is its own decision — nothing in v1 needs it, since the agent surface is read-only.

## Open questions — both answered 2026-08-15

- ~~Whether `destinations_list` should also report each destination's last-seen leg state from the status sink~~ — **no, one tool per question.** Beyond the "one tool per question" principle, there is no id to join on: MCP leg identity is positional (`destination-1`), never the store id, so the join could only match URL strings — the fragile inference the 2026-08-15 leg-state decision deliberately moved away from, and one that collides outright for two destinations sharing an ingest URL with different keys (a case the id-keyed key storage exists to support). A store read must also answer with nothing streaming, so the field would be absent on most calls. An agent wanting the join reads both tools and matches on `url`.
- ~~Whether the ingest simulator's test destinations warrant a seeded store fixture for integration tests~~ — **no; raw URLs remain the test surface.** The store is operator state at a real path in Application Support, with keys in the real Keychain: a fixture that seeds it is a test writing the developer's own destinations. The raw `url`/`key` path stays supported permanently and everything downstream of resolution is identical, so the integration tests lose no coverage; resolution itself is covered by unit tests over a temporary directory. The store's directory *is* injectable, which is what would let a fixture be added later without touching operator state — so this defers the option rather than closing it.
