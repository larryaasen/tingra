# Tingra Plug-ins: the next phase

*Draft plan, 2026-09-13, revised the same day for the ExtensionKit process model and the field comparison. Decisions are recommendations awaiting Larry's veto; once settled, the vocabulary moves into GLOSSARY.md, the enforcement bullets into CLAUDE.md, and the seam rows into the "Seams and plug-ins at a glance" tables in ARCHITECTURE.md.*

## Why this phase exists

The plug-in architecture is the feature that will ultimately drive adoption — the way VS Code's extension system, not its editor, is what made VS Code. That only happens if there are **many capable seams** a third party can tap, and if a plug-in author can build something the engine has never heard of (a notes pane, a rundown, a chat overlay, a tally-light bridge) without asking us to add a hook first.

Today every seam is a **host** seam: inputs, outputs, effects, media, and MCP tools, all defined in `TingraPlugInKit` and all headless — the CLI, the `serve` daemon, and the app activate the same plug-ins through the same `PlugInContext`. That is the right foundation and it does not change. What is missing is the other half: seams that only exist when there is a window. A notes plug-in needs a pane, a menu item, and somewhere to save its text; the host needs to know nothing about it, but the app does.

This document plans that second half, the process model it runs under, and the seams that follow it. The goal for the code is VS Code's *shape* — a small stable kernel, everything else a plug-in against named registries — applied to a broadcasting, recording, and livestreaming tool rather than an IDE.

## What the field teaches

Four plug-in systems bracket the design space Tingra sits in. OBS Studio is the closest product; VS Code is the model for breadth and composability; VST3 and Audio Units are the model for a real-time engine that hosts third-party code without dying.

| Dimension | OBS Studio | VS Code | VST3 / Audio Units | Tingra today (+ planned) |
|---|---|---|---|---|
| **Boundary** | C ABI (`libobs`), function-pointer tables in `obs_source_info` structs | JavaScript API over RPC; `package.json` declares everything static | COM-style C++ interfaces (VST3) or Objective-C/Swift protocols (AU) | Swift protocols in a Library Evolution module; Swift's stable ABI is the contract |
| **Process model** | In process. A plug-in crash is the most common OBS crash | Out of process by design. The extension host restarts; the window survives | VST3 in process by tradition; hosts increasingly bridge. AUv3 is always out of process as an app extension with a remote view | Host tier in process (the frame path). App tier out of process via ExtensionKit (this plan) |
| **Engine seams** | Sources, filters, transitions, encoders, outputs, services | None. VS Code has no engine; everything is UI and language tooling | Exactly one: an audio processor. Deep, not broad | Inputs, generators, media, effects, streaming, recording, tools. Planned: transitions, sinks, destination kinds |
| **UI model** | Data-driven property panes the host renders, plus raw Qt for docks and menus | Data-driven first (tree views, status bar, quick pick, settings); one escape hatch (webview in an isolated iframe) | The plug-in draws its own editor in a host-provided window; parameters are declared so a host can show a generic editor | Effects already declare parameters the app renders. Panes planned as remote SwiftUI views behind declared descriptors |
| **The universal verb** | obs-websocket requests and hotkeys | Commands: every action is a named command any extension, keybinding, or menu can invoke | Parameters and automation | MCP tools — and Decision 10 makes them the plug-in verb too |
| **Persistence** | `obs_data_t` JSON stored in the scene collection | `globalState`, `workspaceState`, settings | A state stream the host saves inside the project | Planned: project-scoped JSON in the document, app-scoped folder. The same split as all three |
| **Activation** | Everything loads at startup | Lazy, on declared activation events | Instantiated on demand | Everything activates at boot. Planned: activation on demand for the app tier |
| **Versioning** | `libobs` API version; rebuilds across majors are common | Additive API with an `engines.vscode` floor; proposed APIs gated | VST3 ABI stable for over a decade; VST2 to VST3 was the one break | SemVer, Library Evolution, CI diff against the last tag; the app tier adds a wire protocol, which is easier to keep compatible than an ABI |
| **Distribution and trust** | Signed and notarized bundles in a folder since OBS 28; no isolation | Marketplace; the extension host has full Node access, a known weakness | Folders the host scans; `auval` validates AUs; AUv3 ships in a container app, sandboxed | Host tier: signed bundles in a folder. App tier: ExtensionKit, sandboxed, enabled by the system |

**From VS Code** the parts worth copying are structural. Declarative descriptors mean the host renders menus and lists uniformly and can show them before the plug-in has even loaded. Commands as the universal verb are what make extensions composable, and Tingra's tools already play that role. Activation events let a host stop launching every plug-in at boot. Data-driven UI first, with an escape hatch second, is why VS Code stays coherent across thousands of extensions.

**From VST and AU** the strict split between the real-time processor and the editor is the same split as Tingra's host tier and app tier, and it is the reason the host tier stays in process. The host owning plug-in state inside the project file is what Tingra's project-scoped storage does. Declared parameters that the host can render generically already exist for effects (`EffectParameter`) and should extend to inputs and outputs. AUv3 is the precedent that matters most for the process model, and it gets its own section below.

**From OBS** breadth. Sources, filters, transitions, encoders, outputs, and services are the seams a broadcasting tool needs, and they map directly onto phase 4. Two things not to copy: everything in process is why plug-in crashes dominate its crash reports, and handing plug-ins the raw UI framework for docks leaked Qt into the plug-in API, so OBS cannot change its UI toolkit without breaking every dock.

**Where Tingra already stands apart:** it is the only one of the four with a typed, structured event bus as the observability contract, and the only one whose control surface was designed for agents first. Both carry over to plug-ins unchanged.

### The AUv3 precedent

Audio Units version 3 (iOS 9 and macOS 10.11, 2015) is the closest thing to a controlled experiment on the question this plan has to answer: can a real-time media host run UI-bearing third-party plug-ins out of process on Apple platforms, and what does it cost?

**What Apple did.** An AUv3 is an app extension (`.appex`) that ships inside a container app. The system launches it in its own sandboxed process — on macOS the hosting process is visible in Activity Monitor as `AUHostingServiceXPC` — and the host (Logic, GarageBand, AUM, Cubasis) never links the plug-in's code. Three things cross the process boundary:

- **Audio.** The host's real-time render thread calls the extension's render block through a shared-memory audio buffer and a real-time-safe signalling path Apple engineered for the purpose. It works, but it costs: per-render-cycle scheduling overhead and a higher CPU floor, and early AUv3 hosts glitched at small buffer sizes where in-process AUv2 did not. Apple's answer on macOS was an escape hatch, `AudioComponentInstantiationOptions.loadInProcess`, honoured only when the extension's Info.plist names an `AudioComponentBundle` framework the host may load directly. iOS never got the hatch; every AUv3 on iOS is out of process.
- **The UI.** The extension vends an `AUViewController`; the host embeds it as a remote view — the extension's process renders the pixels, the window server composites them into the host's window. Remote views had a rough first few years: sizing (`preferredContentSize`, later `supportedViewConfigurations`), keyboard focus, drag and drop, and hosts showing a blank until the extension activated were all real complaints, and all were fixed at the platform level over successive releases rather than by each host.
- **Parameters and state.** The extension declares an `AUParameterTree`; the host observes and automates parameters across the boundary, and saves the extension's `fullState` inside its own project file. The plug-in never touches the disk on its own behalf.

**What happened.** On iOS, AUv3 is the only Audio Unit form there is, and it carries a large commercial ecosystem — hundreds of instrument and effect apps hosted by GarageBand, AUM, Cubasis, and Logic Pro for iPad, which is AUv3-only. On macOS, AUv3 coexists with AUv2 and VST3; many developers still ship v2 or VST3 first, for two reasons that matter here: the audio-path performance tax and the container-app distribution requirement. The crash-isolation benefit is real and visible in daily use — a crashing AUv3 shows up as a failed plug-in slot Logic can reload, not a lost session.

**What it says for Tingra.** Four lessons, each mapped to a decision below.

1. **Keep the real-time path in process.** Apple's audio-over-XPC is the best-engineered version of the alternative, and it still needed an in-process escape hatch on macOS. Tingra's frame path is GPU-resident and tick-paced (CLOCK.md); the host tier stays in process, exactly as ARCHITECTURE.md already says for capture. *(Decision 1, unchanged.)*
2. **Out-of-process UI works at scale.** The remote-view mechanism AUv3 relies on is the same one ExtensionKit exposes to any host through `EXHostViewController`, a decade more mature than when AUv3 launched. A notes pane, a rundown, or a source list has none of the audio path's timing pressure. *(Decision 12.)*
3. **The host owns state; the plug-in declares parameters.** `fullState` in the project and `AUParameterTree` for the generic editor are, respectively, Tingra's project-scoped storage and its `EffectParameter` — the second generalised to every host-tier registration. *(Decisions 7 and 15.)*
4. **Distribution friction is real and accepted.** A container app the user installs and an extension the system enables is heavier than dropping a bundle in a folder. The AUv3 ecosystem shows developers accept it when the host is worth targeting, and `EXAppExtensionBrowserViewController` lets Tingra present the enablement step itself. *(Decision 13.)*

One more lesson is in what Apple *had* to add: the in-process hatch. Tingra's app-tier seam is therefore designed so that the descriptors and the wire protocol do not depend on the process boundary — if a first-party pane ever proves it needs in-process hosting, the seam allows it without a rewrite, and the spike below is what decides whether that day ever comes.

## The model: two tiers, one plug-in

**A plug-in has up to two halves, one per tier.** *(Decision 1)*

| Tier | Who hosts it | Process | Protocol package | What a plug-in registers | Examples |
|---|---|---|---|---|---|
| **Host tier** | the engine — CLI, `serve` daemon, app alike | in process (the frame path) | `TingraPlugInKit` (UI-free, unchanged) | inputs, generators, media providers, effects, streaming/recording services, MCP tools; later transitions, event sinks | camera capture, bars, HaishinKit output, `stream_start` |
| **App tier** | the app only — `apps/tingra-app` | out of process: an ExtensionKit extension the system launches and sandboxes | `TingraAppPlugInKit` (**new**; ExtensionKit + SwiftUI on the extension side) | panes, commands, settings panes, storage; later windows, status bar items | a notes pane, a rundown, a stream-deck bridge's settings |

A plug-in is **host-only**, **app-only**, or **both**:

- **Host-only** — a `PlugIn` bundle, as every first-party plug-in is today. Loads everywhere; the external bundle loader of roadmap step 10 is its delivery path.
- **App-only** — an ExtensionKit extension against Tingra's extension point. The engine never sees it. A headless front end never loads it, because the host tier and the app tier are different artifacts, not different halves of one binary.
- **Both** — a host-tier bundle and an app-tier extension shipped together in one container app, under **one `PlugInID`** *(Decision 3)*: the same reverse-DNS identifier is the bundle's plug-in id, the extension's declared plug-in id, and the event domain of both. The NDI plug-in is the model case: an `Input` and a `StreamingService` in the host half, and a pane listing discovered NDI sources in the app half.

**Two protocol packages, not one.** *(Decision 2)* `TingraPlugInKit` must stay importable by the CLI and the daemon, and the CLAUDE.md rule that engine packages are UI-free is what keeps it honest. The app-tier kit imports ExtensionKit and SwiftUI and is linked only by extensions and by the app.

**Vocabulary: registries, not "contribution points" or "extension points".** *(Decision 4)* GLOSSARY.md already says a registry is the seam where plug-ins attach, and that rule scales: the app tier adds a **pane registry**, a **command registry**, a **settings registry** beside the host's input, output, effect, media, and tool registries. Rejected: VS Code's "contribution point" (a second noun for the thing a registry already is, and "contribution" reads as community language Tingra avoids) and ExtensionKit's "extension point" ("extension" beside "plug-in" is two words for one thing). ExtensionKit's own term is unavoidable in the one place it is Apple's API — Tingra *declares an extension point* to the system — and nowhere else; in Tingra prose an app-tier plug-in is still a plug-in. New GLOSSARY terms are **tier** (host tier, app tier), **pane** (a plug-in-contributed view hosted in a sidebar), **command** (a plug-in-contributed menu action), and **descriptor** (the static declaration of a pane, command, or settings pane the app reads before the plug-in runs). **"Tool" stays reserved for MCP tools** — the request that started this plan said "tools", but the word is taken by an agent-facing contract, and reusing it would blur exactly the boundary this phase draws.

### The app tier's process model

**App-tier plug-ins run out of process, always, as ExtensionKit extensions.** *(Decision 12)* The reasons, in order of weight:

- **A crashed notes pane must not take down a live stream.** That is a worse outcome than a crashed linter taking down an editor, and it is the outcome OBS lives with. Third-party UI code never runs in the process that owns the compositor, the mixer, or the stream keys.
- **The system does the hard parts.** Discovery (`AppExtensionIdentity.matching(appExtensionPointIDs:)`), launch, sandboxing, crash recovery, and the remote view (`EXHostViewController`) are macOS 13 API, under the macOS 15 floor. No Disable Library Validation is needed for the app tier; the extension's own signature and notarization cover it.
- **The seam becomes a wire protocol, which is the easiest kind of contract to keep compatible.** An extension built against an older kit keeps working as long as the protocol only gains methods — no ABI, no module interface, no recompilation.
- **Version isolation is free.** Each extension links its own kit version; two extensions built years apart coexist.

The costs, stated plainly: remote views have limits (the SwiftUI environment does not cross, focus and drag and drop need care, sizing inside a resizable sidebar is the item most likely to bite); distribution is heavier (a container app, enabled in System Settings > General > Login Items & Extensions, which the app can present in place through `EXAppExtensionBrowserViewController`); and first-party plug-ins pay the same tax — which is deliberate, see Decision 13.

**One hosting mode, first party included.** *(Decision 13)* VS Code runs its built-in extensions in the extension host; AUv3 hosts treat Apple's own units no differently. Tingra does the same: Notes is Tingra's first extension, embedded in `Tingra.app/Contents/Extensions/`. One mode means one API, one test surface, and first-party pain felt before third parties feel it. The spike checks that an embedded extension is discovered and enabled without a trip to System Settings.

**The link speaks MCP.** *(Decision 14)* CLAUDE.md forbids a second internal RPC protocol, and the rule applies here as written: the connection ExtensionKit hands each side (`makeXPCConnection()`) carries the existing hand-rolled JSON-RPC layer from `TingraMCP` over a new `XPCMessageTransport` — the third `MessageTransport` beside the socket and in-memory ones. Control is `tools/call`, observation is MCP resources with subscriptions, and the handful of app-tier-only methods (`tingra/storage.get`, `tingra/storage.set`, `tingra/event`) are namespaced additions to the same protocol. Consequences worth stating: the app links `TingraMCP` and becomes an MCP server to its extensions (and could later expose the same server on the Unix socket, making the app and `serve` interchangeable to an agent — out of scope, but the door is open); the JSON-RPC message types and `MessageTransport` move out of `TingraMCP` into a zero-dependency `TingraJSONRPC` package so an extension can link them without `TingraHost`; and the app registers `ControlToolsPlugIn` against a real `ToolRegistry` instead of today's `UnusedToolRegistering` stub, which means the stream coordinator behind those tools becomes a host-side type the app and the daemon share.

## Phase 0 — the ExtensionKit spike

Nothing in phases 1–3 is built until a throwaway extension target inside `tingra-app.xcodeproj` answers five questions. Each has a pass condition and a recorded fallback; the spike is deleted afterwards (CLAUDE.md, no leftover scripts) and its findings go into this document.

| # | Question | Pass condition | If it does not pass |
|---|---|---|---|
| 1 | **Declaration and enablement.** The app declares its extension point (`com.moonwink.tingra.app-plug-in`; the host entitlement `com.apple.developer.extensionkit.extension-point-identifiers` and the extension's `EXAppExtensionAttributes` / `EXExtensionPointIdentifier` are the macOS 13 declaration path — verified here, since the macOS 26 code-declared `AppExtensionPoint` API is above the floor). | An extension embedded in the app bundle is discovered and enabled with no System Settings visit; a third-party one is enabled through `EXAppExtensionBrowserViewController` presented by the app | Embedded extensions needing a settings visit: acceptable for third parties, not for Notes — first-party panes then run in process behind the same descriptors (the hatch AUv3 needed) |
| 2 | **A remote view in the trailing sidebar.** `EXHostViewController` wrapped in `NSViewControllerRepresentable` under the Library, in the disclosure chrome. | Correct sizing on sidebar resize, dark mode, scrolling, keyboard focus into a text editor, no visible blank on first show; a hidden pane costs no CPU | Fix what the platform allows; if sizing or focus cannot be made native-feeling, the fallback of row 1 applies to every pane, and the process boundary is kept only for non-UI work |
| 3 | **MCP over the connection.** `XPCMessageTransport` under the existing JSON-RPC layer, both directions. | A `tools/call` round trip well under a frame; a killed extension reconnects on the next activation with the app's registries intact | None expected; XPC is the platform's IPC. A surprise here is a design defect, not a platform limit |
| 4 | **Frames across the boundary.** An `IOSurface`-backed program frame handed over XPC at the app's monitor rate; meters at meter rate. | The extension draws program video with no copy and no backlog (the tee's `bufferingNewest` rule holds across the boundary) | A pane needing program pixels becomes a documented in-process exception, or a downscaled preview surface is offered instead of the program surface |
| 5 | **Menus before launch.** Command and pane descriptors read from the extension's Info.plist at discovery; the menu renders before any extension runs; invoking a command launches the extension through `AppExtensionProcess` and forwards the call; the app emits the tap first. | Cold-start command invocation feels immediate; a pane's expansion launches its scene | Descriptors move from Info.plist to a first-launch handshake — losing lazy menus, keeping everything else |

Exit criterion: rows 1–3 and 5 pass. Row 4 may fail without changing the design; it only decides whether a pane can draw program video.

## Phase 1 — the app tier and its first plug-in

This is the "first step": a plug-in the host never sees adds a sidebar pane, a menu item, and log lines, and saves what it makes — from its own process.

### The `TingraAppPlugInKit` package

`packages/TingraAppPlugInKit` → `TingraPlugInKit` + `TingraEventBus` + `TingraJSONRPC`; imports ExtensionKit and SwiftUI; sets `defaultIsolation(MainActor.self)` in its manifest, matching the app target (a type that must run off the main actor says `nonisolated`, as in the app). It is the **extension side** of the seam — what a plug-in author links. Its public surface, all documented in TYPES.md when built:

- **Descriptors** *(Decision 5)* — `PaneDescriptor` (`id: PaneID` as `<plugInID>.<name>`, `title`, `systemImage`, `preferredSidebar: SidebarPosition` of `.leading`, `.trailing`, `.bottom`, `sceneID`), `CommandDescriptor` (`id`, `title`, `shortcut: ShortcutDescriptor?` — Codable, since `KeyboardShortcut` is not, `placement: CommandPlacement` with v1's single case `.plugInMenu`), `SettingsPaneDescriptor`. All `Codable`, all read by the app from the extension's Info.plist under `EXAppExtensionAttributes` at discovery, the way VS Code reads `contributes`. The kit provides a `PlugInManifest` type and a build-phase check that the Info.plist decodes, so a typo is a build error, not a silently missing menu.
- **`TingraAppExtension`** — the protocol an extension's `@main` type adopts: ExtensionKit's `AppExtension` with one `AppExtensionScene` per pane and settings pane (each named by the descriptor's `sceneID`), plus the non-UI scene the app connects to for commands and events. The kit owns the boilerplate; an author writes `var panes: [PaneID: some View]` and `func perform(_ command: CommandID) async throws`.
- **`PlugInConnection`** — the extension's client for the app's MCP endpoint over the scene connection: `call(_ tool: String, arguments: JSONValue) async throws -> JSONValue` (Decision 10), `subscribe(_ resource: String)` for observation (phase 2), `event(_ name:params:)` for logging, and `storage` below. One object, handed to the extension when its connection activates.
- **Storage** *(Decision 7)* — two scopes, no secrets, both served by the app because the extension is sandboxed away from the project file:
  - **Project-scoped**: `projectData: JSONValue?` read and `setProjectData(_:)` write, over `tingra/storage.*`. Stored in the project document under a new optional top-level key, `plugInData: [String: JSONValue]?` keyed by `PlugInID` (an optional key, never a version bump — the pre-release rule). A write dirties the document like a layer edit, so notes save with the project and travel with it. Unknown plug-in data round-trips untouched, so a project opened without the plug-in loses nothing.
  - **App-scoped**: `applicationData` read and write, a JSON blob the app keeps at `~/Library/Application Support/Tingra/Plug-ins/<PlugInID>/`, plus the extension's own sandbox container for anything bulky.
  - **Not in scope**: secrets. A plug-in that needs a key (a chat service token) gets a narrowed `SecureStorage` method in phase 2, never a plaintext file.
- **Logging needs no new seam.** `PlugInConnection.event(...)` lands the event on the app's bus with the plug-in's `PlugInID` as its domain; `EventDomain` is already an open, string-backed set for exactly this reason (EVENTS.md). Lines reach `~/Library/Logs/Tingra/Tingra.log` through the existing `FileSink`, OSLog, and the log window — whose domain menu is derived from the lines it has loaded, so a plug-in domain appears the moment the plug-in emits. Plug-ins never format a log line, per the same rule as everything else.

### The app side

The app is the host of the app tier: **its registries, its extension host model, and its MCP endpoint live in the app target for now** *(Decision 8)*, mirroring `TingraHost` owning the registries for `TingraPlugInKit`. If a second front end ever needs them they extract into a package; until then a package would be speculation.

- `AppPlugInHost` — an `@Observable @MainActor` model that discovers identities for the extension point at launch and on the system's change notification (never polling), decodes each manifest, and fills the three registries: `PaneRegistry`, `CommandRegistry`, `SettingsRegistry`. Registration is by descriptor, before any process runs. A malformed manifest is an `error` event naming the extension and the key, and the next extension registers normally.
- **Launch on demand** *(Decision 6)* — an extension's process starts when its pane is first expanded (`EXHostViewController` does this itself), when one of its commands is invoked, or when a phase-2 activation condition it declared is met. `plugin.activated` carries `"tier": "app"` (the host-tier event gains `"tier": "host"`); a process exit is `plugin.deactivated` with the reason, and the pane shows the placeholder view until the next activation — a device disconnect, not an error.
- **The trailing sidebar hosts registered panes.** Today its two panes (layer inspector, Library) are literal children of a `VStack` behind a draggable splitter. Phase 1 makes it a stack of panes: the two existing ones stay first, unchanged in look, and registered panes follow as collapsible sections below the Library, each in shared chrome (a disclosure header carrying the title and symbol, expansion persisted per pane id under `sidebar.<paneID>.expanded`, the `SidebarPreferences` pattern). Uniformity comes from the container, not from asking each author to match it. The leading sidebar's ten `SidebarSection`s are the engine's input list, not panes in this sense; a plug-in asking for `.leading` gets a section appended after Destinations, in phase 2, once `SidebarSection` is identifier-backed. `.bottom` is accepted and treated as `.trailing` until a `BottomSidebar` exists — the position is a *preference* the app may override, and the operator's layout always wins.
- `PlugInCommands` — one `CommandMenu("Plug-ins")` whose body is a `ForEach` over the command registry grouped by plug-in, the dynamic-items pattern `ShotCommands` already uses; hidden while no plug-in has registered a command. **Every plug-in command appears under that menu, in a submenu named for its plug-in** *(Decision 6)*, the way every host in the Apple ecosystem groups third-party additions; placing commands into the Program, Shots, or Layer menus is a later `CommandPlacement` case once a real plug-in needs it. The app emits the `tap` (`"<plugInID>.<commandID>.menuItem"`, domain = the plug-in id) *before* forwarding, so the tap convention from EVENTS.md holds for authors who have never read EVENTS.md; the command's own effect is the plug-in's `event`.
- Settings: `SettingsPane` becomes an identifier-backed struct so the source list can append registered settings panes, each a remote view like any pane.
- The MCP endpoint: `XPCMessageTransport` in `TingraMCP`, the app's `ToolRegistry` fed by `ControlToolsPlugIn`, and the `tingra/*` methods. Per-connection identity: the app knows which `PlugInID` is on each connection from the identity it launched, so a storage call cannot reach another plug-in's data.
- The project document: `Project.plugInData` (`TingraComposition`), with `ProjectStore` and the dirty-tracking path carrying it.
- Localization: an extension carries its own catalog; a third-party plug-in's strings are its own business. First-party extension targets follow the CLAUDE.md `de`/`es` rule.

### The first-party proof: Notes

**Notes is an extension target in `tingra-app.xcodeproj`, embedded in Tingra.app** *(Decision 9)* — Larry's own example, and small enough to prove every seam at once. Its testable logic (debounce, storage codec) lives in the target and is tested through the kit's mock connection; it links only `TingraAppPlugInKit`, so it cannot cheat by reaching into the engine — it is not even in the engine's process.

- A **pane** (`com.moonwink.tingra.notes.pane`, trailing): a `TextEditor` over the project-scoped storage, so notes are part of the project.
- A **command** ("Show Notes", ⌥⌘N) that expands the pane; the tap arrives free, the plug-in emits `notes.shown`.
- A **settings pane** with one control (font size), app-scoped storage.
- **Events**: `notes.edited` (debounced), `notes.cleared` — visible in the log window under the `com.moonwink.tingra.notes` domain.
- **Tests** (Swift Testing, no UI): manifest decoding, storage round trip through a mock `PlugInConnection`, the debounce. App tests: the registries reject duplicate ids, `PlugInCommands` taps before forwarding, pane expansion persists, `Project.plugInData` round-trips and survives an unknown plug-in id, `XPCMessageTransport` against the in-memory peer.

Generators dogfooded the input seam; Notes dogfoods the app tier the same way — and stays useful afterwards.

### Phase 1 work list

1. `packages/TingraJSONRPC` — the message types and `MessageTransport` lifted out of `TingraMCP`, no dependencies; `TingraMCP` re-exports them so nothing else moves.
2. `packages/TingraAppPlugInKit` — descriptors, manifest, `TingraAppExtension`, `PlugInConnection`, mock connection, tests.
3. `packages/TingraComposition` — `Project.plugInData`, Codable tests (missing key, round trip, unknown id preserved).
4. `packages/TingraMCP` — `XPCMessageTransport`, the `tingra/*` methods, the host-side stream coordinator the app and `serve` share.
5. `apps/tingra-app` — extension point declaration and entitlement, `AppPlugInHost`, the three registries, remote-view hosting in the trailing sidebar with `PanePreferences`, `PlugInCommands`, identifier-backed `SettingsPane`, the MCP endpoint with a real `ToolRegistry`, the enablement sheet, tier params on `plugin.activated`.
6. The Notes extension target, its catalog, its tests.
7. Docs: GLOSSARY (tier, pane, command, descriptor), CLAUDE.md (dependency graph rows for the two new packages; a rule bullet: app-tier plug-ins are ExtensionKit extensions speaking MCP over XPC, engine packages stay UI-free), ARCHITECTURE.md (app-tier rows in the seams tables; the two-tier model and process model under "Engine model: host and plug-ins"), MCP.md (the XPC transport and the `tingra/*` methods), TYPES.md and README.md entries for both packages, TODO.md.
8. Verification: `swift build`/`swift test` per package, `xcodebuild test` for the app and the extension, `scripts/check-format.sh`.

Nothing in phase 1 touches the streamed path or the CLI's behaviour, and `TingraPlugInKit` changes only additively.

## Phase 2 — seams into the engine: observe, then act

A pane that can only show its own data is a widget. The seams that make the app tier *capable* let a plug-in see what the engine is doing and, with care, drive it. Over the MCP link these are **resources** a plug-in subscribes to, each backed by `EngineModel` state that already exists, so the work is deciding the public shape and pinning it with the SemVer policy.

| Resource | What a plug-in sees | Backed by today |
|---|---|---|
| `tingra://session` | stream and recording status, per-destination state and statistics | `EngineModel.streamStatus`, `destinationStates`, `recordingStatus` |
| `tingra://program` | active preset, program and preview shot, tally per input, fade-to-black | `activeShotID`, `previewShotID`, `programInputIDs`, `isFadedToBlack` |
| `tingra://inputs` | the inputs the engine knows, by kind, with connect/disconnect | `cameras`, `displays`, `audioInputs`, `media` |
| `tingra://meters` | per-strip and master levels at meter rate | `MeterRelay` |
| program and preview frames | `IOSurface` objects over the connection, newest wins, for a pane drawing its own monitor | `ProgramFrameRelay` (only if spike row 4 passed) |

The rule: **observation exposes value types and identifiers, never `Compositor`, `AudioMixer`, or a registry** — those stay private to the app, as they are now. Agents get every resource for free, since the daemon serves the same protocol.

**Control: plug-ins act on the engine through tools, not a second API.** *(Decision 10)* The MCP tools are already the engine's stable, identifier-keyed control contract (`stream_start`, `stream_stop`, `devices_list`, …). Rather than inventing a parallel surface with its own errors and its own stability policy, a plug-in that wants to take a shot calls the same `shot_take` tool an agent would. One contract, one set of `ErrorIdentifier`s, one place to add authorization later. The tool surface grows the program controls (`shot_take`, `preview_set`, `fade_to_black`) that MCP.md already anticipates.

**Activation conditions** *(Decision 6, continued)* — a descriptor may declare `activation: ["session.started", "input.connected:ndi"]`, VS Code's activation events. The app launches the extension on the first matching event, so a tally-light bridge with no pane still comes alive when the stream starts.

**Declared parameters for every host-tier registration** *(Decision 15)* — `EffectParameter` today gives an effect a settings UI the app renders without the effect knowing SwiftUI exists. The same declaration extends to inputs, outputs, and destination kinds (`ParameterDescribing` on the registered provider), so a host-only plug-in gets a native settings pane with no app half at all — the OBS property pane and the AUv3 generic editor, done once in the app. Most third-party plug-ins will need nothing more than this, which is the point.

**Secrets:** `tingra/secrets.*` narrowed to the plug-in's own keys (`<PlugInID>.<name>`), Keychain-backed like everything else.

**More app-tier registries:** windows (a plug-in-owned window, for a rundown or a multiview-style surface, one scene each), status bar items, and the leading-sidebar section hosting deferred from phase 1.

## Phase 3 — bundles, extensions, and versions

The external bundle loader is the last item of roadmap step 10 and the moment `TingraPlugInKit` tags 1.0.0. It is now a **host-tier-only** artifact: the app tier needs no loader, because ExtensionKit discovers, launches, and isolates extensions. This plan adds:

- **One container app carries both halves.** A plug-in with both tiers ships a container app holding the host-tier bundle (which the installer, or the container app on first run, copies into the plug-in folder the loader scans) and the app-tier extension (which the system registers on install). Host-only plug-ins remain a bare bundle in the folder; app-only ones are just the extension. The plug-in id in the bundle's Info.plist and in the extension's manifest must match; the app reports a mismatch as an `error` naming both.
- **Both kits tag 1.0.0 together** *(Decision 11)*. The app-tier contract is descriptors plus a wire protocol, which is why it can be pinned at the same time as the ABI-bound host kit without fear. The JSON-RPC method set is versioned by the MCP protocol-version handshake already in the layer; `swift package diagnose-api-breaking-changes` runs against both kit tags in CI, and a method or resource, once shipped, is append-only like a tool name.
- **Isolation is a tier property, and now a clean one.** App-tier code is out of process by construction. The XPC candidacy ARCHITECTURE.md records for host-tier outputs and automation stays a future option — `AppExtensionProcess` shows the platform can launch a non-UI extension and hand back a connection, which is one way to do it when the day comes.
- **Version negotiation per tier, never a crash**: a bundle whose host-tier major is incompatible is refused with an `error` naming both versions and the fix; an extension whose manifest declares an app-tier major the app does not speak is listed in the enablement sheet as needing an update, and never launched.

NDI follows as the first out-of-repo plug-in with both halves.

## Phase 4 — breadth: the host seams still missing

The host tier's registries cover capture, generation, media, effects, output, recording, and tools. GLOSSARY.md promises more than the code delivers, and VS Code-level capability is a matter of how many of these exist — OBS's list is the yardstick. In rough order of demand:

| Seam | Registers | Why a plug-in wants it |
|---|---|---|
| `TransitionRegistering` | a `Transition` implementation (GLOSSARY says plug-ins add transitions; today cut, dissolve, and the shader transitions are built in) | wipes, stingers, a branded transition |
| `SinkRegistering` | an `EventSink` | ship events elsewhere: a Discord/Slack notifier, a tally-light bridge listening to `program.take`, a metrics exporter — the same seam the log file uses |
| MCP resources and prompts from plug-ins | beyond tools, the other two MCP primitives | an agent reading the rundown a plug-in maintains |
| `DestinationKindRegistering` | a destination preset kind (URL template, key rules, probe) | a service Tingra has never heard of, with its own probe |
| `SnapshotExporting` | a snapshot destination | post a snapshot to a service |
| `AudioMonitorRegistering` | an `AudioMonitor` | a plug-in-provided monitor path (network audio) |

Each follows the established pattern exactly: capability protocol plus registering protocol in `TingraPlugInKit`, registry in `TingraHost`, declared parameters per Decision 15, a first-party plug-in that dogfoods it, rows in the ARCHITECTURE.md tables.

## What does not change

- The host/plug-in boundary test (ARCHITECTURE.md): if removing it breaks plug-ins in general it is host; the app-tier registries and the extension host model are host in that sense, and the panes are plug-ins.
- The event bus is the only logging path; the clock is injected; secrets stay in the Keychain.
- One `PlugInID`, one event domain per plug-in, whatever its tiers.
- `TingraPlugInKit` never imports SwiftUI, AppKit, or ExtensionKit.
- One internal RPC protocol. The app tier is served by the MCP layer, not beside it.

## Decisions to veto

1. A plug-in has up to two halves, host tier and app tier; the host tier stays in process.
2. Two protocol packages: `TingraPlugInKit` (headless, unchanged) and `TingraAppPlugInKit` (ExtensionKit + SwiftUI, the extension side).
3. One `PlugInID` across tiers, one event domain, one container app for a plug-in with both halves.
4. Vocabulary: registries, tiers, panes, commands, descriptors. No "contribution point"; "extension point" only where it names Apple's API. "Tool" stays MCP.
5. Panes, commands, and settings panes are declared as Codable descriptors in the extension's manifest; the app supplies uniform chrome; placement is a preference, the operator's layout wins.
6. Plug-in commands live under a "Plug-ins" menu in per-plug-in submenus; the app emits the tap; extensions launch on demand (pane shown, command invoked, declared activation condition).
7. Storage is project-scoped JSON in the document plus an app-scoped blob, both served by the app; secrets wait for a narrowed Keychain method.
8. App-tier registries, the extension host model, and the MCP endpoint live in the app target until a second front end needs them.
9. Notes, an extension target embedded in Tingra.app, is the first-party proof.
10. Plug-ins control the engine through the MCP tools (`tools/call`), never a parallel API.
11. Both kits tag 1.0.0 with the bundle loader; the app-tier wire protocol is append-only from then on.
12. App-tier plug-ins run out of process, always, as ExtensionKit extensions.
13. One hosting mode: first-party app-tier plug-ins are extensions too, embedded in the app bundle.
14. The app-to-extension link speaks the existing MCP JSON-RPC layer over an `XPCMessageTransport`; the message types move to a zero-dependency `TingraJSONRPC` package.
15. Declared parameters extend from effects to every host-tier registration, so a host-only plug-in gets a native settings pane without an app half.
16. Phase 0, the ExtensionKit spike, gates phases 1–3; its five rows carry their fallbacks.
